const std = @import("std");
const sf = @import("soundfondue");
const testing = std.testing;

const sample_name = sf.name("Recording") catch unreachable;
const inst_name = sf.name("Instrument") catch unreachable;
const preset_name = sf.name("Preset") catch unreachable;
const pcm: [110]i16 = @splat(0);

const samples = [_]sf.Sample{
    .{
        .name = sample_name,
        .start = 0,
        .end = 64,
        .loop_start = 8,
        .loop_end = 56,
        .sample_rate = 22050,
        .original_key = 69,
        .pitch_correction = -4,
    },
};

const instrument_zones = [_]sf.InstrumentZone{
    .{ .generators = &.{sf.Generator.signed(.attack_vol_env, -6000)} },
    .{
        .target = @enumFromInt(0),
        .generators = &.{
            sf.Generator.range(.key_range, .{ .low = 24, .high = 96 }),
            sf.Generator.range(.vel_range, .{ .low = 1, .high = 100 }),
            .{ .operator = .sample_modes, .amount = 3 },
            sf.Generator.signed(.fine_tune, -17),
        },
        .modulators = &.{
            .{
                .source = 0x0502,
                .destination = .initial_attenuation,
                .amount = 960,
                .amount_source = 0,
                .transform = 0,
            },
        },
    },
};

const instruments = [_]sf.Instrument{.{ .name = inst_name, .zones = &instrument_zones }};

const presets = [_]sf.Preset{
    .{
        .name = preset_name,
        .program = 12,
        .bank = 128,
        .library = 42,
        .genre = 7,
        .morphology = 9,
        .zones = &.{
            .{
                .target = @enumFromInt(0),
                .generators = &.{sf.Generator.signed(.coarse_tune, 2)},
            },
        },
    },
};

fn fixture() sf.Bank {
    return .{
        .sample_data = &pcm,
        .samples = &samples,
        .instruments = &instruments,
        .presets = &presets,
    };
}

test "round trip retains sample metadata, zones, native amounts and reserved fields" {
    var data = pcm;
    data[0] = -32768;
    data[1] = 32767;

    var bank = fixture();
    bank.sample_data = &data;

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);

    var document = try sf.decode(testing.allocator, bytes);
    defer document.deinit();

    try testing.expectEqualDeep(bank, document.bank);
    try testing.expectEqualSlices(i16, data[0..64], document.bank.frames(@enumFromInt(0)).?);
    try testing.expectEqual(
        @as(i16, -17),
        document.bank.instruments[0].zones[1].generator(.fine_tune).?.signedAmount(),
    );

    const again = try sf.encode(testing.allocator, document.bank);
    defer testing.allocator.free(again);

    try testing.expectEqualSlices(u8, bytes, again);
}

test "decoded document owns bytes independently of caller storage" {
    const bytes = try sf.encode(testing.allocator, fixture());
    var document = try sf.decode(testing.allocator, bytes);
    defer document.deinit();

    @memset(bytes, 0xff);
    testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "Untitled\x00\x00", document.bank.metadata("INAM".*).?);
    try testing.expectEqualDeep(samples[0], document.bank.samples[0]);
}

test "24 bit PCM, stereo links, unknown operators and chunks survive" {
    var bank = fixture();
    var stereo = [_]sf.Sample{ samples[0], samples[0] };
    stereo[0].sample_type = .left;
    stereo[0].link = 1;
    stereo[1].sample_type = .right;
    stereo[1].link = 0;
    bank.samples = &stereo;

    var low: [pcm.len]u8 = @splat(0);
    @memset(low[0..64], 0xab);
    bank.sample_data_low = &low;

    var zones = instrument_zones;
    zones[1].generators = &.{.{ .operator = @enumFromInt(60000), .amount = 0xabcd }};
    bank.instruments = &.{.{ .name = inst_name, .zones = &zones }};
    bank.extra_chunks = &.{
        .{ .parent = .top, .tag = "LIST".*, .data = "abcdpayload" },
        .{ .parent = .sdta, .tag = "xtra".*, .data = "odd" },
        .{ .parent = .pdta, .tag = "more".*, .data = "opaque" },
    };

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);

    var document = try sf.decode(testing.allocator, bytes);
    defer document.deinit();

    try testing.expectEqualDeep(bank, document.bank);
}

test "odd frame counts retain 24 bit data without exposing alignment byte" {
    var bank = fixture();
    const odd_pcm: [111]i16 = @splat(0);
    var low: [111]u8 = @splat(0);
    @memset(low[0..64], 0x7f);
    bank.sample_data = &odd_pcm;
    bank.sample_data_low = &low;

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);

    var document = try sf.decode(testing.allocator, bytes);
    defer document.deinit();

    try testing.expectEqualDeep(bank, document.bank);
}

fn allocationRoundTrip(allocator: std.mem.Allocator) !void {
    const bytes = try sf.encode(allocator, fixture());
    defer allocator.free(bytes);

    var document = try sf.decode(allocator, bytes);
    defer document.deinit();
}

test "every allocation failure frees intermediate reader and writer storage" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationRoundTrip, .{});
}

test "all truncated prefixes and trailing input are rejected" {
    const bytes = try sf.encode(testing.allocator, fixture());
    defer testing.allocator.free(bytes);

    for (0..bytes.len) |length| {
        if (sf.decode(testing.allocator, bytes[0..length])) |result| {
            var document = result;
            document.deinit();

            return error.TestUnexpectedResult;
        } else |_| {}
    }

    const trailing = try testing.allocator.alloc(u8, bytes.len + 1);
    defer testing.allocator.free(trailing);

    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;

    try testing.expectError(error.InvalidRiff, sf.decode(testing.allocator, trailing));
}

fn tableOffset(bytes: []const u8, tag: []const u8) !usize {
    var position: usize = 12;
    while (position < bytes.len) {
        if (bytes.len - position < 8)
            return error.Truncated;

        const size: usize = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .little);
        if (size > bytes.len - position - 8)
            return error.Truncated;

        const payload = bytes[position + 8 ..][0..size];
        if (std.mem.eql(u8, bytes[position..][0..4], "LIST") and
            payload.len >= 4 and
            std.mem.eql(u8, payload[0..4], "pdta"))
        {
            var table_position: usize = 4;
            while (table_position < payload.len) {
                if (payload.len - table_position < 8)
                    return error.Truncated;

                const table_size: usize = std.mem.readInt(u32, payload[table_position + 4 ..][0..4], .little);
                if (table_size > payload.len - table_position - 8)
                    return error.Truncated;
                if (std.mem.eql(u8, payload[table_position..][0..4], tag))
                    return position + 8 + table_position + 8;

                table_position += 8 + table_size + table_size % 2;
            }
        }
        position += 8 + size + size % 2;
    }

    return error.MissingChunk;
}

test "hostile table indices and sample bounds return errors" {
    const original = try sf.encode(testing.allocator, fixture());
    defer testing.allocator.free(original);

    const bytes = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(bytes);

    const mutations = [_]struct { tag: []const u8, offset: usize }{
        .{ .tag = "phdr", .offset = 24 },
        .{ .tag = "phdr", .offset = 38 + 24 },
        .{ .tag = "pbag", .offset = 0 },
        .{ .tag = "pbag", .offset = 2 },
        .{ .tag = "inst", .offset = 20 },
        .{ .tag = "inst", .offset = 22 + 20 },
        .{ .tag = "ibag", .offset = 0 },
        .{ .tag = "shdr", .offset = 24 },
    };
    for (mutations) |mutation| {
        @memcpy(bytes, original);
        const offset = try tableOffset(bytes, mutation.tag) + mutation.offset;
        @memset(bytes[offset..][0..2], 0xff);
        if (sf.decode(testing.allocator, bytes)) |result| {
            var document = result;
            document.deinit();

            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "invalid editable models fail before serialization" {
    var bank = fixture();
    var changed_samples = samples;
    bank.samples = &changed_samples;
    changed_samples[0].loop_end = 111;
    try testing.expectError(error.InvalidSample, sf.encode(testing.allocator, bank));

    changed_samples = samples;
    changed_samples[0].sample_type = .rom_mono;
    try testing.expectError(error.UnsupportedRomSamples, sf.encode(testing.allocator, bank));

    bank = fixture();
    bank.instruments = &.{
        .{ .name = inst_name, .zones = &.{.{ .target = @enumFromInt(1) }} },
    };
    try testing.expectError(error.InvalidIndex, sf.encode(testing.allocator, bank));

    bank = fixture();
    bank.extra_chunks = &.{.{ .parent = .pdta, .tag = "pgen".*, .data = "" }};
    try testing.expectError(error.DuplicateChunk, sf.encode(testing.allocator, bank));
}

test "unit conversion helpers keep time and attenuation meanings distinct" {
    try testing.expectEqual(@as(f64, 0), sf.timecentsToSeconds(-32768));
    try testing.expectApproxEqAbs(@as(f64, 1), sf.timecentsToSeconds(0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), sf.timecentsToSeconds(-1200), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.1), sf.centibelsToGain(200), 1e-12);
}

test "independent SF2 2.01 fixture matches documented record layouts" {
    const hex = std.mem.trim(u8, @embedFile("fixtures/minimal.hex"), "\n\r ");
    var bytes: [668]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var document = try sf.decode(testing.allocator, &bytes);
    defer document.deinit();

    const bank = document.bank;
    try testing.expectEqual(@as(usize, 1), bank.presets.len);
    try testing.expectEqual(@as(u16, 5), bank.presets[0].program);
    try testing.expectEqual(@as(u16, 2), bank.presets[0].bank);
    try testing.expectEqual(@as(u32, 13), bank.presets[0].morphology);
    try testing.expectEqual(@as(u32, 32000), bank.samples[0].sample_rate);
    try testing.expectEqual(@as(i8, -7), bank.samples[0].pitch_correction);
    try testing.expectEqual(@as(u32, 2), bank.samples[0].start);
    try testing.expectEqual(@as(u32, 66), bank.samples[0].end);

    const frames = bank.frames(@enumFromInt(0)).?;
    for (frames, 0..) |frame, index| {
        try testing.expectEqual(@as(i16, @intCast(index)) - 32, frame);
    }
    const encoded = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(encoded);

    try testing.expectEqualSlices(u8, &bytes, encoded);
}

test "single byte mutations never panic and accepted models can be reserialized" {
    const original = try sf.encode(testing.allocator, fixture());
    defer testing.allocator.free(original);

    const mutated = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(mutated);

    for (0..original.len) |offset| {
        for ([_]u8{ 0, 0xff }) |value| {
            @memcpy(mutated, original);
            mutated[offset] = value;
            if (sf.decode(testing.allocator, mutated)) |result| {
                var document = result;
                defer document.deinit();

                const encoded = try sf.encode(testing.allocator, document.bank);
                defer testing.allocator.free(encoded);

                var reread = try sf.decode(testing.allocator, encoded);
                defer reread.deinit();

                try testing.expectEqualDeep(document.bank, reread.bank);
            } else |_| {}
        }
    }
}

test "multiple presets and instruments partition bag tables correctly" {
    var bank = fixture();
    var multi_presets = [_]sf.Preset{ presets[0], presets[0] };
    multi_presets[1].program = 127;
    multi_presets[1].zones = &.{
        .{
            .modulators = &.{
                .{ .source = 0, .destination = .pan, .amount = -100, .amount_source = 0, .transform = 0 },
            },
        },
        .{ .target = @enumFromInt(1) },
        .{ .target = @enumFromInt(0) },
    };
    bank.presets = &multi_presets;
    bank.instruments = &.{
        instruments[0],
        .{ .name = inst_name, .zones = &.{.{ .target = @enumFromInt(0) }} },
    };

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);

    var document = try sf.decode(testing.allocator, bytes);
    defer document.deinit();

    try testing.expectEqualDeep(bank, document.bank);
}

test "writer rejects overflowing 16 bit generator table indices" {
    var bank = fixture();
    const generators = try testing.allocator.alloc(sf.Generator, 65535);
    defer testing.allocator.free(generators);

    @memset(generators, sf.Generator.signed(.fine_tune, 1));
    bank.instruments = &.{
        .{
            .name = inst_name,
            .zones = &.{.{ .target = @enumFromInt(0), .generators = generators }},
        },
    };
    try testing.expectError(error.TooLarge, sf.encode(testing.allocator, bank));
}

test "writer requires sample guard points and supports unlooped zero loop positions" {
    var bank = fixture();
    bank.sample_data = pcm[0..64];
    try testing.expectError(error.InvalidSample, sf.encode(testing.allocator, bank));

    var changed_pcm = pcm;
    changed_pcm[64] = 1;
    bank.sample_data = &changed_pcm;
    try testing.expectError(error.InvalidSample, sf.encode(testing.allocator, bank));

    var changed_samples = samples;
    changed_samples[0].start = 2;
    changed_samples[0].loop_start = 0;
    changed_samples[0].loop_end = 0;
    bank.sample_data = &pcm;
    bank.samples = &changed_samples;
    try sf.validate(bank);
}

fn referenceBytes() [668]u8 {
    const hex = std.mem.trim(u8, @embedFile("fixtures/minimal.hex"), "\n\r ");
    var bytes: [668]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;

    return bytes;
}

test "borrowed file decodes unaligned little endian records and frame blocks" {
    const original = referenceBytes();
    var storage: [669]u8 align(2) = undefined;
    @memcpy(storage[1..], &original);
    try testing.expect(@intFromPtr(storage[1..].ptr) % 2 == 1);

    const file = try sf.File.parse(storage[1..]);
    try file.validate();
    try testing.expectEqual(storage[1..].ptr, file.bytes.ptr);
    try testing.expectEqual(@as(usize, 1), file.samples.count());
    try testing.expectEqual(
        @as(i8, -7),
        (try file.samples.get(@as(sf.SampleId, @enumFromInt(0)))).pitch_correction,
    );
    try testing.expectError(error.InvalidIndex, file.samples.get(1));
    try testing.expectError(error.InvalidIndex, file.samples.get(-1));

    var headers = file.samples.openCursor();
    try testing.expectEqualDeep(try file.samples.get(0), (try headers.next()).?);
    try testing.expectEqual(null, try headers.next());

    var frames = try file.frames(@enumFromInt(0));
    var block: [7]i16 = undefined;
    var frame_index: i16 = -32;
    while (try frames.next()) |frame| {
        try testing.expectEqual(frame_index, frame);
        frame_index += 1;
    }
    try testing.expectEqual(@as(i16, 32), frame_index);

    frames = try file.frames(@enumFromInt(0));
    try testing.expectEqual(@as(usize, 7), try frames.read(&block));
    try testing.expectEqualSlices(i16, &.{ -32, -31, -30, -29, -28, -27, -26 }, &block);
    try testing.expectEqual(@as(i16, -25), (try frames.next()).?);
}

test "parsing checks table structure while full validation checks references" {
    var bytes = referenceBytes();
    const target = try tableOffset(&bytes, "pgen") + 2;
    std.mem.writeInt(u16, bytes[target..][0..2], 42, .little);

    const file = try sf.File.parse(&bytes);
    try testing.expectError(error.InvalidIndex, file.validate());

    const bag = try tableOffset(&bytes, "pbag");
    std.mem.writeInt(u16, bytes[bag..][0..2], 1, .little);
    try testing.expectError(error.InvalidIndex, sf.File.parse(&bytes));
}

test "owning document detaches all metadata, zones, both PCM planes and opaque chunks" {
    var bank = fixture();
    var low: [pcm.len]u8 = @splat(0);
    low[0] = 0x81;
    bank.sample_data_low = &low;
    bank.extra_chunks = &.{.{ .parent = .top, .tag = "test".*, .data = "borrowed bytes" }};
    const bytes = try sf.encode(testing.allocator, bank);
    const file = try sf.File.parse(bytes);

    var document = try file.toDocument(testing.allocator);
    defer document.deinit();

    @memset(bytes, 0xff);
    testing.allocator.free(bytes);
    try testing.expectEqualDeep(bank, document.bank);

    const rewritten = try sf.encode(testing.allocator, document.bank);
    defer testing.allocator.free(rewritten);
    const reread = try sf.File.parse(rewritten);
    try reread.validate();
}

test "borrowed files and banks write byte equivalent output without allocating" {
    var bank = fixture();
    const odd_pcm: [111]i16 = @splat(0);
    var low: [111]u8 = @splat(0);
    low[3] = 0xef;
    bank.sample_data = &odd_pcm;
    bank.sample_data_low = &low;
    bank.extra_chunks = &.{
        .{ .parent = .top, .tag = "LIST".*, .data = "abcdopaque" },
        .{ .parent = .sdta, .tag = "test".*, .data = "odd" },
        .{ .parent = .pdta, .tag = "xtra".*, .data = "bytes" },
    };

    const encoded = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(encoded);
    const file = try sf.File.parse(encoded);
    try file.validate();

    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try sf.write(&writer, bank);
    try testing.expectEqualSlices(u8, encoded, writer.buffered());

    writer = .fixed(&storage);
    try sf.writeSource(&writer, file.source());
    try testing.expectEqualSlices(u8, encoded, writer.buffered());
    try testing.expectEqual(@as(u64, encoded.len), (try sf.Layout.calculate(file.source())).byteCount());
}

fn ListCursor(comptime Entry: type) type {
    return struct {
        inner: sf.source.SliceCursor(Entry),
        steps: ?*usize,
        fail: bool,

        pub fn next(self: *@This()) !?Entry {
            if (self.steps) |steps|
                steps.* += 1;
            if (self.fail)
                return error.ListSourceFailed;

            return self.inner.next();
        }
    };
}

const ProbeSource = struct {
    bank: sf.Bank,
    reads: *usize,
    frame_count: ?usize = null,
    max_read: usize = 512,
    fail_audio: bool = false,
    fail_guard: bool = false,
    fail_low: bool = false,
    zero_audio: bool = false,
    oversized_audio: bool = false,
    largest_request: ?*usize = null,
    list_steps: ?*usize = null,
    fail_metadata: bool = false,
    fail_extras: bool = false,

    pub fn metadata(self: ProbeSource) ListCursor(sf.Info) {
        return .{
            .inner = self.bank.source().metadata(),
            .steps = self.list_steps,
            .fail = self.fail_metadata,
        };
    }

    pub fn sampleCount(self: ProbeSource) usize {
        return self.bank.samples.len;
    }

    pub fn sampleAt(self: ProbeSource, index: usize) !sf.Sample {
        return self.bank.source().sampleAt(index);
    }

    pub fn presetCount(self: ProbeSource) usize {
        return self.bank.presets.len;
    }

    pub fn presetAt(self: ProbeSource, index: usize) !sf.source.PresetHeader {
        return self.bank.source().presetAt(index);
    }

    pub fn presetZone(self: ProbeSource, object: usize, index: usize) !sf.source.BankZone(sf.InstrumentId) {
        return self.bank.source().presetZone(object, index);
    }

    pub fn instrumentCount(self: ProbeSource) usize {
        return self.bank.instruments.len;
    }

    pub fn instrumentAt(self: ProbeSource, index: usize) !sf.source.InstrumentHeader {
        return self.bank.source().instrumentAt(index);
    }

    pub fn instrumentZone(self: ProbeSource, object: usize, index: usize) !sf.source.BankZone(sf.SampleId) {
        return self.bank.source().instrumentZone(object, index);
    }

    pub fn frameCount(self: ProbeSource) usize {
        return self.frame_count orelse self.bank.sample_data.len;
    }

    pub fn hasLowFrames(self: ProbeSource) bool {
        return self.bank.sample_data_low != null;
    }

    pub fn lowFrameCount(self: ProbeSource) usize {
        return self.bank.source().lowFrameCount();
    }

    pub fn readFrames(self: ProbeSource, offset: usize, buffer: []i16) !usize {
        self.reads.* += 1;
        if (self.largest_request) |largest|
            largest.* = @max(largest.*, buffer.len);

        if (self.fail_guard and offset >= 64)
            return error.SampleSourceFailed;

        if (offset < 64) {
            if (self.fail_audio)
                return error.SampleSourceFailed;
            if (self.zero_audio)
                return 0;
            if (self.oversized_audio)
                return buffer.len + 1;
        }

        return self.bank.source().readFrames(offset, buffer[0..@min(buffer.len, self.max_read)]);
    }

    pub fn readLowFrames(self: ProbeSource, offset: usize, buffer: []u8) !usize {
        self.reads.* += 1;
        if (self.largest_request) |largest|
            largest.* = @max(largest.*, buffer.len);

        if (self.fail_low and offset < 64)
            return error.SampleSourceFailed;

        return self.bank.source().readLowFrames(offset, buffer[0..@min(buffer.len, self.max_read)]);
    }

    pub fn extraChunks(self: ProbeSource) ListCursor(sf.Chunk) {
        return .{
            .inner = self.bank.source().extraChunks(),
            .steps = self.list_steps,
            .fail = self.fail_extras,
        };
    }
};

test "layout calculation reads no PCM and checks sample and RIFF size overflow" {
    var reads: usize = 0;
    var source: ProbeSource = .{ .bank = fixture(), .reads = &reads };
    const layout = try sf.Layout.calculate(source);
    try testing.expectEqual(@as(usize, 0), reads);

    const bytes = try sf.encode(testing.allocator, source.bank);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u64, bytes.len), layout.byteCount());

    source.frame_count = std.math.maxInt(u32);
    try testing.expectError(error.TooLarge, sf.Layout.calculate(source));

    source.frame_count = std.math.maxInt(u32) / 2;
    try testing.expectError(error.TooLarge, sf.Layout.calculate(source));

    source.frame_count = std.math.maxInt(usize);
    try testing.expectError(error.TooLarge, sf.Layout.calculate(source));
    try testing.expectEqual(@as(usize, 0), reads);
}

test "structural and sizing errors leave the writer untouched" {
    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var bank = fixture();
    var changed_samples = samples;
    changed_samples[0].link = 42;
    changed_samples[0].sample_type = .left;
    bank.samples = &changed_samples;
    try testing.expectError(error.InvalidIndex, sf.write(&writer, bank));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var reads: usize = 0;
    const failed_guard: ProbeSource = .{ .bank = fixture(), .reads = &reads, .fail_guard = true };
    try testing.expectError(error.SampleSourceFailed, sf.writeSource(&writer, failed_guard));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    const source: ProbeSource = .{
        .bank = fixture(),
        .reads = &reads,
        .frame_count = std.math.maxInt(u32) / 2,
    };
    try testing.expectError(error.TooLarge, sf.writeSource(&writer, source));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sample-source and output errors can leave partial output" {
    var reads: usize = 0;
    var source: ProbeSource = .{ .bank = fixture(), .reads = &reads, .fail_audio = true };
    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try testing.expectError(error.SampleSourceFailed, sf.writeSource(&writer, source));
    try testing.expect(writer.buffered().len > 0);

    source.fail_audio = false;
    source.zero_audio = true;
    writer = .fixed(&storage);
    try testing.expectError(error.InvalidSample, sf.writeSource(&writer, source));
    try testing.expect(writer.buffered().len > 0);

    source.zero_audio = false;
    source.oversized_audio = true;
    writer = .fixed(&storage);
    try testing.expectError(error.InvalidSample, sf.writeSource(&writer, source));
    try testing.expect(writer.buffered().len > 0);

    var tiny: [32]u8 = undefined;
    writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, sf.write(&writer, fixture()));
    try testing.expect(writer.buffered().len > 0);
}

test "short block reads make progress in both PCM planes and low-plane failures propagate" {
    var bank = fixture();
    var low: [pcm.len]u8 = @splat(0);
    low[0] = 0x82;
    bank.sample_data_low = &low;
    var reads: usize = 0;
    var source: ProbeSource = .{ .bank = bank, .reads = &reads, .max_read = 7 };
    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try sf.writeSource(&writer, source);

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, bytes, writer.buffered());

    source.fail_low = true;
    writer = .fixed(&storage);
    try testing.expectError(error.SampleSourceFailed, sf.writeSource(&writer, source));
    try testing.expect(writer.buffered().len > 0);
}

test "streaming preserves multi-block PCM pools with bounded read requests" {
    var data: [2048]i16 = undefined;
    var low: [2048]u8 = undefined;
    for (&data, &low, 0..) |*frame, *low_byte, index| {
        frame.* = @as(i16, @intCast(index)) - 1024;
        low_byte.* = @truncate(index);
    }
    @memset(data[1500..1546], 0);
    @memset(low[1500..1546], 0);

    var changed_samples = samples;
    changed_samples[0].end = 1500;
    var bank = fixture();
    bank.samples = &changed_samples;
    bank.sample_data = &data;
    bank.sample_data_low = &low;

    var reads: usize = 0;
    var largest_request: usize = 0;
    const source: ProbeSource = .{
        .bank = bank,
        .reads = &reads,
        .max_read = 7,
        .largest_request = &largest_request,
    };
    var storage: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try sf.writeSource(&writer, source);
    try testing.expectEqual(@as(usize, 512), largest_request);

    const bytes = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, bytes, writer.buffered());

    const file = try sf.File.parse(writer.buffered());
    var decoded: [2048]i16 = undefined;
    try testing.expectEqual(data.len, try file.readFrames(0, &decoded));
    try testing.expectEqualSlices(i16, &data, &decoded);
}

test "variable length lists take a bounded number of sequential passes" {
    var metadata: [131]sf.Info = undefined;
    var extras: [128]sf.Chunk = undefined;
    var storage: [8192]u8 = undefined;

    for ([_]usize{ 64, 128 }) |count| {
        var bank = fixture();
        @memcpy(metadata[0..3], bank.info);
        @memset(metadata[3..], .{ .tag = "test".*, .data = "payload" });
        @memset(&extras, .{ .parent = .top, .tag = "test".*, .data = "payload" });
        bank.info = metadata[0 .. count + 3];
        bank.extra_chunks = extras[0..count];

        var reads: usize = 0;
        var steps: usize = 0;
        const source: ProbeSource = .{ .bank = bank, .reads = &reads, .list_steps = &steps };
        var writer: std.Io.Writer = .fixed(&storage);
        try sf.writeSource(&writer, source);
        try testing.expect(steps <= 8 * (bank.info.len + bank.extra_chunks.len + 2));

        const expected = try sf.encode(testing.allocator, bank);
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(u8, expected, writer.buffered());
    }
}

test "metadata and extra cursor failures propagate before output" {
    var reads: usize = 0;
    var source: ProbeSource = .{ .bank = fixture(), .reads = &reads, .fail_metadata = true };
    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try testing.expectError(error.ListSourceFailed, sf.writeSource(&writer, source));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    source.fail_metadata = false;
    source.fail_extras = true;
    try testing.expectError(error.ListSourceFailed, sf.Layout.calculate(source));
    try testing.expectError(error.ListSourceFailed, sf.writeSource(&writer, source));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "large borrowed metadata and opaque lists round trip and materialize" {
    var bank = fixture();
    const metadata = try testing.allocator.alloc(sf.Info, 4099);
    defer testing.allocator.free(metadata);
    @memcpy(metadata[0..3], bank.info);
    @memset(metadata[3..], .{ .tag = "test".*, .data = "payload" });
    bank.info = metadata;

    const extras = try testing.allocator.alloc(sf.Chunk, 4096);
    defer testing.allocator.free(extras);
    for (extras, 0..) |*entry, index| {
        entry.* = .{
            .parent = switch (index % 3) {
                0 => .top,
                1 => .sdta,
                else => .pdta,
            },
            .tag = "test".*,
            .data = "payload",
        };
    }
    bank.extra_chunks = extras;

    const expected = try sf.encode(testing.allocator, bank);
    defer testing.allocator.free(expected);
    const file = try sf.File.parse(expected);
    try file.validate();

    const storage = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    try sf.writeSource(&writer, file);
    try testing.expectEqualSlices(u8, expected, writer.buffered());

    var document = try file.toDocument(testing.allocator);
    defer document.deinit();
    try testing.expectEqual(metadata.len, document.bank.info.len);
    try testing.expectEqual(extras.len, document.bank.extra_chunks.len);

    writer = .fixed(storage);
    try sf.write(&writer, document.bank);
    try testing.expectEqualSlices(u8, expected, writer.buffered());
}
