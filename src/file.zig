const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const sources = @import("source.zig");
const Error = binary.Error;

const Kind = enum { preset, instrument, sample, generator, modulator };
const table_tags = [_][]const u8{ "phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr" };
const table_widths = [_]usize{ 38, 4, 10, 4, 22, 4, 10, 4, 46 };

fn Record(comptime kind: Kind) type {
    return switch (kind) {
        .preset => sources.PresetHeader,
        .instrument => sources.InstrumentHeader,
        .sample => model.Sample,
        .generator => model.Generator,
        .modulator => model.Modulator,
    };
}

fn width(comptime kind: Kind) usize {
    return switch (kind) {
        .preset => 38,
        .instrument => 22,
        .sample => 46,
        .generator => 4,
        .modulator => 10,
    };
}

fn Table(comptime kind: Kind, comptime terminal: bool) type {
    return struct {
        bytes: []const u8,

        pub fn count(self: @This()) usize {
            return self.bytes.len / width(kind) - @intFromBool(terminal);
        }

        pub fn get(self: @This(), id: anytype) Error!Record(kind) {
            const index = switch (@typeInfo(@TypeOf(id))) {
                .@"enum" => @as(usize, @intFromEnum(id)),
                else => std.math.cast(usize, id) orelse return error.InvalidIndex,
            };
            if (index >= self.count())
                return error.InvalidIndex;

            var cursor: binary.Cursor = .{ .data = self.bytes[index * width(kind) ..] };
            return switch (kind) {
                .preset => .{
                    .name = (try cursor.take(20))[0..20].*,
                    .program = try cursor.int(u16),
                    .bank = try cursor.int(u16),
                    .zone_start = try cursor.int(u16),
                    .library = try cursor.int(u32),
                    .genre = try cursor.int(u32),
                    .morphology = try cursor.int(u32),
                    .zone_end = std.mem.readInt(u16, cursor.data[38 + 24 ..][0..2], .little),
                },
                .instrument => .{
                    .name = (try cursor.take(20))[0..20].*,
                    .zone_start = try cursor.int(u16),
                    .zone_end = std.mem.readInt(u16, cursor.data[22 + 20 ..][0..2], .little),
                },
                .sample => .{
                    .name = (try cursor.take(20))[0..20].*,
                    .start = try cursor.int(u32),
                    .end = try cursor.int(u32),
                    .loop_start = try cursor.int(u32),
                    .loop_end = try cursor.int(u32),
                    .sample_rate = try cursor.int(u32),
                    .original_key = try cursor.int(u8),
                    .pitch_correction = try cursor.int(i8),
                    .link = try cursor.int(u16),
                    .sample_type = @enumFromInt(try cursor.int(u16)),
                },
                .generator => .{
                    .operator = @enumFromInt(try cursor.int(u16)),
                    .amount = try cursor.int(u16),
                },
                .modulator => .{
                    .source = try cursor.int(u16),
                    .destination = @enumFromInt(try cursor.int(u16)),
                    .amount = try cursor.int(i16),
                    .amount_source = try cursor.int(u16),
                    .transform = try cursor.int(u16),
                },
            };
        }

        pub fn openCursor(self: @This()) Cursor {
            return .{ .table = self };
        }

        pub const Cursor = struct {
            table: Table(kind, terminal),
            index: usize = 0,

            pub fn next(self: *Cursor) Error!?Record(kind) {
                if (self.index == self.table.count())
                    return null;

                const record = try self.table.get(self.index);
                self.index += 1;

                return record;
            }
        };
    };
}

pub const Frames = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *Frames) Error!?i16 {
        if (self.position == self.bytes.len)
            return null;
        if (self.bytes.len - self.position < 2)
            return error.Truncated;

        const value = std.mem.readInt(i16, self.bytes[self.position..][0..2], .little);
        self.position += 2;

        return value;
    }

    pub fn read(self: *Frames, buffer: []i16) Error!usize {
        const count = @min(buffer.len, (self.bytes.len - self.position) / 2);
        for (buffer[0..count]) |*frame|
            frame.* = (try self.next()).?;

        return count;
    }
};

fn Zone(comptime Target: type) type {
    return struct {
        target: ?Target,
        generators: Table(.generator, false),
        modulators: Table(.modulator, false),

        pub fn generatorCount(self: @This()) usize {
            return self.generators.count();
        }

        pub fn generatorAt(self: @This(), index: usize) Error!model.Generator {
            return self.generators.get(index);
        }

        pub fn modulatorCount(self: @This()) usize {
            return self.modulators.count();
        }

        pub fn modulatorAt(self: @This(), index: usize) Error!model.Modulator {
            return self.modulators.get(index);
        }
    };
}

pub const File = struct {
    bytes: []const u8,
    lists: [3][]const u8,
    tables: [9][]const u8,
    sample_bytes: []const u8,
    sample_low_bytes: ?[]const u8,
    presets: Table(.preset, true),
    instruments: Table(.instrument, true),
    samples: Table(.sample, true),

    pub fn parse(bytes: []const u8) Error!File {
        var root: binary.Cursor = .{ .data = bytes };
        if (!binary.equal(try root.take(4), "RIFF"))
            return error.InvalidRiff;

        const size = try root.int(u32);
        if (size < 4 or size != bytes.len - 8)
            return error.InvalidRiff;
        if (!binary.equal(try root.take(4), "sfbk"))
            return error.InvalidRiff;

        var lists: [3]?[]const u8 = @splat(null);
        while (try root.next()) |chunk| {
            if (!binary.equal(&chunk.tag, "LIST"))
                continue;
            if (chunk.data.len < 4)
                return error.InvalidChunk;

            for ([_][]const u8{ "INFO", "sdta", "pdta" }, 0..) |tag, index| {
                if (binary.equal(chunk.data[0..4], tag)) {
                    if (lists[index] != null)
                        return error.DuplicateChunk;

                    lists[index] = chunk.data[4..];
                }
            }
        }

        var info: binary.Cursor = .{ .data = lists[0] orelse return error.MissingChunk };
        while (try info.next()) |_| {}

        var sdta: binary.Cursor = .{ .data = lists[1] orelse return error.MissingChunk };
        var pcm: ?[]const u8 = null;
        var low: ?[]const u8 = null;

        while (try sdta.next()) |chunk| {
            if (binary.equal(&chunk.tag, "smpl")) {
                if (pcm != null)
                    return error.DuplicateChunk;
                pcm = chunk.data;
            } else if (binary.equal(&chunk.tag, "sm24")) {
                if (low != null)
                    return error.DuplicateChunk;
                low = chunk.data;
            }
        }

        const sample_bytes = pcm orelse &.{};
        if (sample_bytes.len % 2 != 0)
            return error.InvalidSample;
        if (low) |data| {
            const count = sample_bytes.len / 2;
            if (data.len != count and data.len != count + count % 2)
                return error.InvalidSample;

            low = data[0..count];
        }

        var pdta: binary.Cursor = .{ .data = lists[2] orelse return error.MissingChunk };
        var tables: [9]?[]const u8 = @splat(null);
        while (try pdta.next()) |chunk| {
            for (table_tags, 0..) |tag, index| {
                if (binary.equal(&chunk.tag, tag)) {
                    if (tables[index] != null)
                        return error.DuplicateChunk;

                    tables[index] = chunk.data;
                }
            }
        }

        var required: [9][]const u8 = undefined;
        for (tables, table_widths, 0..) |optional, record_width, index| {
            const table = optional orelse return error.MissingChunk;
            if (table.len == 0 or table.len % record_width != 0)
                return error.InvalidTable;

            _ = try binary.index(table.len / record_width - 1);
            required[index] = table;
        }
        if (required[0].len < 76 or required[4].len < 44)
            return error.InvalidTable;

        try checkChain(required[0], 38, 24, required[1].len / 4 - 1);
        try checkChain(required[4], 22, 20, required[5].len / 4 - 1);
        try checkChain(required[1], 4, 0, required[3].len / 4 - 1);
        try checkChain(required[1], 4, 2, required[2].len / 10 - 1);
        try checkChain(required[5], 4, 0, required[7].len / 4 - 1);
        try checkChain(required[5], 4, 2, required[6].len / 10 - 1);

        return .{
            .bytes = bytes,
            .lists = .{ lists[0].?, lists[1].?, lists[2].? },
            .tables = required,
            .sample_bytes = sample_bytes,
            .sample_low_bytes = low,
            .presets = .{ .bytes = required[0] },
            .instruments = .{ .bytes = required[4] },
            .samples = .{ .bytes = required[8] },
        };
    }

    pub fn validate(self: File) Error!void {
        try @import("validate.zig").validateSource(self);
    }

    pub fn toDocument(self: File, allocator: std.mem.Allocator) Error!@import("reader.zig").Document {
        return @import("reader.zig").materialize(allocator, self);
    }

    pub fn source(self: File) File {
        return self;
    }

    pub fn frames(self: File, id: model.SampleId) Error!Frames {
        const sample = try self.samples.get(id);
        if (@intFromEnum(sample.sample_type) & 0x8000 != 0)
            return error.UnsupportedRomSamples;
        if (sample.start > sample.end or sample.end > self.frameCount())
            return error.InvalidSample;

        return .{ .bytes = self.sample_bytes[@as(usize, sample.start) * 2 .. @as(usize, sample.end) * 2] };
    }

    pub fn metadata(self: File) MetadataCursor {
        return .{ .cursor = .{ .data = self.lists[0] } };
    }

    pub const MetadataCursor = struct {
        cursor: binary.Cursor,

        pub fn next(self: *MetadataCursor) Error!?model.Info {
            const chunk = try self.cursor.next() orelse return null;
            return .{ .tag = chunk.tag, .data = chunk.data };
        }
    };

    pub fn metadataCount(self: File) usize {
        var cursor = self.metadata();
        var count: usize = 0;
        while (cursor.next() catch unreachable) |_|
            count += 1;

        return count;
    }

    pub fn metadataAt(self: File, index: usize) Error!model.Info {
        var cursor = self.metadata();
        var current: usize = 0;
        while (try cursor.next()) |chunk| {
            if (current == index)
                return chunk;

            current += 1;
        }

        return error.InvalidIndex;
    }

    pub fn sampleCount(self: File) usize {
        return self.samples.count();
    }

    pub fn sampleAt(self: File, index: usize) Error!model.Sample {
        return self.samples.get(index);
    }

    pub fn presetCount(self: File) usize {
        return self.presets.count();
    }

    pub fn presetAt(self: File, index: usize) Error!sources.PresetHeader {
        return self.presets.get(index);
    }

    pub fn presetZone(self: File, object: usize, index: usize) Error!Zone(model.InstrumentId) {
        const preset = try self.presets.get(object);
        if (index >= preset.zone_end - preset.zone_start)
            return error.InvalidIndex;

        return readZone(
            model.InstrumentId,
            self.tables[1],
            self.tables[3],
            self.tables[2],
            preset.zone_start + index,
            .instrument,
        );
    }

    pub fn instrumentCount(self: File) usize {
        return self.instruments.count();
    }

    pub fn instrumentAt(self: File, index: usize) Error!sources.InstrumentHeader {
        return self.instruments.get(index);
    }

    pub fn instrumentZone(self: File, object: usize, index: usize) Error!Zone(model.SampleId) {
        const instrument = try self.instruments.get(object);
        if (index >= instrument.zone_end - instrument.zone_start)
            return error.InvalidIndex;

        return readZone(
            model.SampleId,
            self.tables[5],
            self.tables[7],
            self.tables[6],
            instrument.zone_start + index,
            .sample_id,
        );
    }

    pub fn frameCount(self: File) usize {
        return self.sample_bytes.len / 2;
    }

    pub fn hasLowFrames(self: File) bool {
        return self.sample_low_bytes != null;
    }

    pub fn lowFrameCount(self: File) usize {
        return if (self.sample_low_bytes) |low| low.len else 0;
    }

    pub fn readFrames(self: File, offset: usize, buffer: []i16) Error!usize {
        if (offset > self.frameCount())
            return error.InvalidIndex;

        var cursor: Frames = .{ .bytes = self.sample_bytes[offset * 2 ..] };
        return cursor.read(buffer);
    }

    pub fn readLowFrames(self: File, offset: usize, buffer: []u8) Error!usize {
        const low = self.sample_low_bytes orelse return error.InvalidSample;
        if (offset > low.len)
            return error.InvalidIndex;

        const count = @min(buffer.len, low.len - offset);
        @memcpy(buffer[0..count], low[offset..][0..count]);

        return count;
    }

    pub fn extraChunks(self: File) ExtraCursor {
        return .{ .file = self, .cursor = .{ .data = self.bytes, .position = 12 } };
    }

    pub fn extraCount(self: File) usize {
        var cursor = self.extraChunks();
        var count: usize = 0;
        while (cursor.next() catch unreachable) |_|
            count += 1;

        return count;
    }

    pub fn extraAt(self: File, index: usize) Error!model.Chunk {
        var cursor = self.extraChunks();
        var current: usize = 0;
        while (try cursor.next()) |chunk| {
            if (current == index)
                return chunk;

            current += 1;
        }

        return error.InvalidIndex;
    }

    pub const ExtraCursor = struct {
        file: File,
        cursor: binary.Cursor,
        phase: usize = 0,

        pub fn next(self: *ExtraCursor) Error!?model.Chunk {
            while (self.phase < 3) {
                while (try self.cursor.next()) |chunk| {
                    if (self.phase == 0 and binary.equal(&chunk.tag, "LIST")) {
                        var known = false;
                        for ([_][]const u8{ "INFO", "sdta", "pdta" }) |tag|
                            known = known or binary.equal(chunk.data[0..4], tag);

                        if (known)
                            continue;
                    } else if (self.phase == 1) {
                        if (binary.equal(&chunk.tag, "smpl") or binary.equal(&chunk.tag, "sm24"))
                            continue;
                    } else if (self.phase == 2) {
                        var known = false;
                        for (table_tags) |tag|
                            known = known or binary.equal(&chunk.tag, tag);

                        if (known)
                            continue;
                    }

                    return .{
                        .parent = switch (self.phase) {
                            0 => .top,
                            1 => .sdta,
                            else => .pdta,
                        },
                        .tag = chunk.tag,
                        .data = chunk.data,
                    };
                }

                self.phase += 1;
                if (self.phase < 3)
                    self.cursor = .{ .data = self.file.lists[self.phase] };
            }

            return null;
        }
    };
};

fn checkChain(bytes: []const u8, record_width: usize, field: usize, limit: usize) Error!void {
    var previous: usize = 0;
    var position: usize = 0;
    while (position < bytes.len) : (position += record_width) {
        const index = std.mem.readInt(u16, bytes[position + field ..][0..2], .little);
        if ((position == 0 and index != 0) or index < previous or index > limit)
            return error.InvalidIndex;

        previous = index;
    }
    if (previous != limit)
        return error.InvalidIndex;
}

fn readZone(
    comptime Target: type,
    bags: []const u8,
    gens: []const u8,
    mods: []const u8,
    index: usize,
    target_operator: model.Operator,
) Error!Zone(Target) {
    var cursor: binary.Cursor = .{ .data = bags[index * 4 ..][0..8] };
    const gen_start: usize = try cursor.int(u16);
    const mod_start: usize = try cursor.int(u16);
    const gen_end: usize = try cursor.int(u16);
    const mod_end: usize = try cursor.int(u16);
    var zone: Zone(Target) = .{
        .target = null,
        .generators = .{ .bytes = gens[gen_start * 4 .. gen_end * 4] },
        .modulators = .{ .bytes = mods[mod_start * 10 .. mod_end * 10] },
    };

    if (zone.generators.count() != 0) {
        const last = try zone.generators.get(zone.generators.count() - 1);
        if (last.operator == target_operator) {
            zone.target = @enumFromInt(last.amount);
            zone.generators.bytes = zone.generators.bytes[0 .. zone.generators.bytes.len - 4];
        }
    }

    return zone;
}
