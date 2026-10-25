const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const source_helpers = @import("source.zig");
const validation = @import("validate.zig");

pub const WriteError = binary.Error || std.Io.Writer.Error;

const ZoneCounts = struct {
    bags: u32 = 0,
    generators: u32 = 0,
    modulators: u32 = 0,
};

pub const Layout = struct {
    riff_size: u32,
    info_size: u32,
    sdta_size: u32,
    pdta_size: u32,
    sample_size: u32,
    low_size: ?u32,
    tables: [9]u32,

    pub fn calculate(source: anytype) !Layout {
        _ = try binary.index(source.presetCount());
        _ = try binary.index(source.instrumentCount());
        _ = try binary.index(source.sampleCount());

        const preset_counts = try countZones(source, true);
        const instrument_counts = try countZones(source, false);
        const tables = [9]u32{
            try tableSize(source.presetCount(), 38),
            try tableSize(preset_counts.bags, 4),
            try tableSize(preset_counts.modulators, 10),
            try tableSize(preset_counts.generators, 4),
            try tableSize(source.instrumentCount(), 22),
            try tableSize(instrument_counts.bags, 4),
            try tableSize(instrument_counts.modulators, 10),
            try tableSize(instrument_counts.generators, 4),
            try tableSize(source.sampleCount(), 46),
        };

        var info_size: u64 = 4;
        var metadata = source.metadata();
        while (try metadata.next()) |entry| {
            info_size = try add(info_size, try chunkSize(entry.data.len));
        }

        const sample_size = try size32(try multiply(source.frameCount(), 2));
        const low_size = if (source.hasLowFrames())
            try size32(try add(source.frameCount(), source.frameCount() % 2))
        else
            null;

        var sdta_size = try add(4, try chunkSize(sample_size));
        if (low_size) |size|
            sdta_size = try add(sdta_size, try chunkSize(size));

        var pdta_size: u64 = 4;
        for (tables) |size|
            pdta_size = try add(pdta_size, try chunkSize(size));

        var top_size: u64 = 0;
        var extras = source.extraChunks();
        while (try extras.next()) |chunk| {
            const size = try chunkSize(chunk.data.len);
            switch (chunk.parent) {
                .top => top_size = try add(top_size, size),
                .sdta => sdta_size = try add(sdta_size, size),
                .pdta => pdta_size = try add(pdta_size, size),
            }
        }

        var riff_size: u64 = 4;
        for ([_]u64{ info_size, sdta_size, pdta_size }) |size|
            riff_size = try add(riff_size, try chunkSize(size));
        riff_size = try add(riff_size, top_size);

        return .{
            .riff_size = try size32(riff_size),
            .info_size = try size32(info_size),
            .sdta_size = try size32(sdta_size),
            .pdta_size = try size32(pdta_size),
            .sample_size = sample_size,
            .low_size = low_size,
            .tables = tables,
        };
    }

    pub fn byteCount(self: Layout) u64 {
        return @as(u64, self.riff_size) + 8;
    }
};

pub fn encode(allocator: std.mem.Allocator, bank: model.Bank) binary.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    write(&output.writer, bank) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };

    return output.toOwnedSlice();
}

pub fn write(writer: *std.Io.Writer, bank: model.Bank) WriteError!void {
    try writeSource(writer, bank.source());
}

pub fn writeSource(writer: *std.Io.Writer, source: anytype) !void {
    try validation.validateSource(source);
    const layout = try Layout.calculate(source);
    const output: Output = .{ .writer = writer };

    try output.header("RIFF", layout.riff_size);
    try writer.writeAll("sfbk");

    try output.header("LIST", layout.info_size);
    try writer.writeAll("INFO");
    var metadata = source.metadata();
    while (try metadata.next()) |entry| {
        try output.chunk(&entry.tag, entry.data);
    }

    try output.header("LIST", layout.sdta_size);
    try writer.writeAll("sdta");
    try output.header("smpl", layout.sample_size);
    try writeFrames(writer, source);

    if (layout.low_size) |size| {
        try output.header("sm24", size);
        try writeLowFrames(writer, source);
        if (source.frameCount() % 2 != 0)
            try writer.writeByte(0);
    }
    try extra(output, source, .sdta);

    try output.header("LIST", layout.pdta_size);
    try writer.writeAll("pdta");
    try output.header("phdr", layout.tables[0]);

    var bag_index: usize = 0;
    for (0..source.presetCount()) |index| {
        const preset = try source.presetAt(index);
        try writer.writeAll(&preset.name);
        try output.int(u16, preset.program);
        try output.int(u16, preset.bank);
        try output.int(u16, try binary.index(bag_index));
        try output.int(u32, preset.library);
        try output.int(u32, preset.genre);
        try output.int(u32, preset.morphology);
        bag_index += preset.zone_end - preset.zone_start;
    }

    try writer.writeAll(&(model.name("EOP") catch unreachable));
    try output.int(u16, 0);
    try output.int(u16, 0);
    try output.int(u16, try binary.index(bag_index));
    try writer.splatByteAll(0, 12);
    try zoneTables(output, source, true, layout.tables[1..4].*);

    try output.header("inst", layout.tables[4]);
    bag_index = 0;
    for (0..source.instrumentCount()) |index| {
        const instrument = try source.instrumentAt(index);
        try writer.writeAll(&instrument.name);
        try output.int(u16, try binary.index(bag_index));
        bag_index += instrument.zone_end - instrument.zone_start;
    }

    try writer.writeAll(&(model.name("EOI") catch unreachable));
    try output.int(u16, try binary.index(bag_index));
    try zoneTables(output, source, false, layout.tables[5..8].*);

    try output.header("shdr", layout.tables[8]);
    for (0..source.sampleCount()) |index| {
        const sample = try source.sampleAt(index);
        try writer.writeAll(&sample.name);
        try output.int(u32, sample.start);
        try output.int(u32, sample.end);
        try output.int(u32, sample.loop_start);
        try output.int(u32, sample.loop_end);
        try output.int(u32, sample.sample_rate);
        try output.int(u8, sample.original_key);
        try output.int(i8, sample.pitch_correction);
        try output.int(u16, sample.link);
        try output.int(u16, @intFromEnum(sample.sample_type));
    }

    try writer.writeAll(&(model.name("EOS") catch unreachable));
    try writer.splatByteAll(0, 26);
    try extra(output, source, .pdta);
    try extra(output, source, .top);
}

const Output = struct {
    writer: *std.Io.Writer,

    fn int(self: Output, comptime Integer: type, value: Integer) std.Io.Writer.Error!void {
        try self.writer.writeInt(Integer, value, .little);
    }

    fn header(self: Output, tag: []const u8, size: u32) std.Io.Writer.Error!void {
        try self.writer.writeAll(tag);
        try self.int(u32, size);
    }

    fn chunk(self: Output, tag: []const u8, bytes: []const u8) WriteError!void {
        try self.header(tag, try size32(bytes.len));
        try self.writer.writeAll(bytes);
        if (bytes.len % 2 != 0)
            try self.writer.writeByte(0);
    }
};

fn writeFrames(writer: *std.Io.Writer, source: anytype) !void {
    var frames: [512]i16 = undefined;
    var bytes: [1024]u8 = undefined;
    var offset: usize = 0;

    while (offset < source.frameCount()) {
        const count: usize = @min(frames.len, source.frameCount() - offset);
        try source_helpers.readFrames(source, offset, frames[0..count]);
        for (frames[0..count], 0..) |frame, index|
            std.mem.writeInt(i16, bytes[index * 2 ..][0..2], frame, .little);

        try writer.writeAll(bytes[0 .. count * 2]);
        offset += count;
    }
}

fn writeLowFrames(writer: *std.Io.Writer, source: anytype) !void {
    var bytes: [512]u8 = undefined;
    var offset: usize = 0;

    while (offset < source.frameCount()) {
        const count: usize = @min(bytes.len, source.frameCount() - offset);
        try source_helpers.readLowFrames(source, offset, bytes[0..count]);
        try writer.writeAll(bytes[0..count]);
        offset += count;
    }
}

fn extra(output: Output, source: anytype, parent: @FieldType(model.Chunk, "parent")) !void {
    var extras = source.extraChunks();
    while (try extras.next()) |chunk| {
        if (chunk.parent == parent)
            try output.chunk(&chunk.tag, chunk.data);
    }
}

fn countZones(source: anytype, comptime preset: bool) !ZoneCounts {
    var counts: ZoneCounts = .{};
    const object_count = if (preset) source.presetCount() else source.instrumentCount();

    for (0..object_count) |object_index| {
        const header = if (preset)
            try source.presetAt(object_index)
        else
            try source.instrumentAt(object_index);

        if (header.zone_start > header.zone_end)
            return error.InvalidIndex;

        const zone_count = header.zone_end - header.zone_start;
        counts.bags = try size32(try add(counts.bags, zone_count));
        _ = try binary.index(counts.bags);

        for (0..zone_count) |zone_index| {
            const zone = if (preset)
                try source.presetZone(object_index, zone_index)
            else
                try source.instrumentZone(object_index, zone_index);

            counts.generators = try size32(try add(counts.generators, zone.generatorCount()));
            counts.generators = try size32(try add(counts.generators, @intFromBool(zone.target != null)));
            counts.modulators = try size32(try add(counts.modulators, zone.modulatorCount()));
            _ = try binary.index(counts.generators);
            _ = try binary.index(counts.modulators);
        }
    }

    return counts;
}

fn zoneTables(output: Output, source: anytype, comptime preset: bool, sizes: [3]u32) !void {
    const tags = if (preset)
        [3][]const u8{ "pbag", "pmod", "pgen" }
    else
        [3][]const u8{ "ibag", "imod", "igen" };
    const target_operator: model.Operator = if (preset) .instrument else .sample_id;
    const object_count = if (preset) source.presetCount() else source.instrumentCount();

    try output.header(tags[0], sizes[0]);
    var gen_index: usize = 0;
    var mod_index: usize = 0;

    for (0..object_count) |object_index| {
        const header = if (preset)
            try source.presetAt(object_index)
        else
            try source.instrumentAt(object_index);

        for (0..header.zone_end - header.zone_start) |zone_index| {
            const zone = if (preset)
                try source.presetZone(object_index, zone_index)
            else
                try source.instrumentZone(object_index, zone_index);

            try output.int(u16, try binary.index(gen_index));
            try output.int(u16, try binary.index(mod_index));
            gen_index += zone.generatorCount() + @intFromBool(zone.target != null);
            mod_index += zone.modulatorCount();
        }
    }

    try output.int(u16, try binary.index(gen_index));
    try output.int(u16, try binary.index(mod_index));

    inline for ([_]bool{ true, false }, 1..) |modulators, table_index| {
        try output.header(tags[table_index], sizes[table_index]);
        for (0..object_count) |object_index| {
            const header = if (preset)
                try source.presetAt(object_index)
            else
                try source.instrumentAt(object_index);

            for (0..header.zone_end - header.zone_start) |zone_index| {
                const zone = if (preset)
                    try source.presetZone(object_index, zone_index)
                else
                    try source.instrumentZone(object_index, zone_index);

                if (modulators) {
                    for (0..zone.modulatorCount()) |index| {
                        const modulator = try zone.modulatorAt(index);
                        try output.int(u16, modulator.source);
                        try output.int(u16, @intFromEnum(modulator.destination));
                        try output.int(i16, modulator.amount);
                        try output.int(u16, modulator.amount_source);
                        try output.int(u16, modulator.transform);
                    }
                } else {
                    for (0..zone.generatorCount()) |index| {
                        const generator = try zone.generatorAt(index);
                        try output.int(u16, @intFromEnum(generator.operator));
                        try output.int(u16, generator.amount);
                    }

                    if (zone.target) |target| {
                        try output.int(u16, @intFromEnum(target_operator));
                        try output.int(u16, @intFromEnum(target));
                    }
                }
            }
        }

        try output.writer.splatByteAll(0, if (modulators) 10 else 4);
    }
}

fn add(first: u64, second: u64) binary.Error!u64 {
    return std.math.add(u64, first, second) catch error.TooLarge;
}

fn multiply(first: u64, second: u64) binary.Error!u64 {
    return std.math.mul(u64, first, second) catch error.TooLarge;
}

fn size32(size: u64) binary.Error!u32 {
    return std.math.cast(u32, size) orelse error.TooLarge;
}

fn chunkSize(size: u64) binary.Error!u64 {
    _ = try size32(size);
    return add(8, try add(size, size % 2));
}

fn tableSize(count: u64, record_width: u64) binary.Error!u32 {
    return size32(try multiply(try add(count, 1), record_width));
}
