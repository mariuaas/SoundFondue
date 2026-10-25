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
