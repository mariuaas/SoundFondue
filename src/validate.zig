const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const source_helpers = @import("source.zig");

pub fn validate(bank: model.Bank) binary.Error!void {
    try validateSource(bank.source());
}

pub fn validateSource(source: anytype) !void {
    if (source.presetCount() == 0 or source.instrumentCount() == 0)
        return error.InvalidTable;

    _ = try binary.index(source.presetCount());
    _ = try binary.index(source.instrumentCount());
    _ = try binary.index(source.sampleCount());

    var required: [3]?[]const u8 = @splat(null);
    var metadata = source.metadata();
    while (try metadata.next()) |entry| {
        for ([_][]const u8{ "ifil", "isng", "INAM" }, 0..) |tag, field| {
            if (binary.equal(&entry.tag, tag)) {
                if (required[field] != null)
                    return error.DuplicateChunk;

                required[field] = entry.data;
            }
        }
    }

    const version = required[0] orelse return error.MissingChunk;
    if (version.len != 4)
        return error.InvalidMetadata;

    const major = std.mem.readInt(u16, version[0..2], .little);
    const minor = std.mem.readInt(u16, version[2..4], .little);
    if (major != 2 or minor > 4)
        return error.UnsupportedVersion;

    for (required[1..]) |optional| {
        const value = optional orelse return error.MissingChunk;
        if (value.len == 0 or value.len > 256 or value.len % 2 != 0 or value[value.len - 1] != 0)
            return error.InvalidMetadata;
    }

    const frame_count = source.frameCount();
    if (frame_count > std.math.maxInt(u32))
        return error.TooLarge;
    if (source.hasLowFrames()) {
        if (minor < 4 or source.lowFrameCount() != frame_count)
            return error.InvalidSample;
    }

    for (0..source.sampleCount()) |index| {
        const sample = try source.sampleAt(index);
        const sample_type = @intFromEnum(sample.sample_type);
        if (sample_type & 0x8000 != 0)
            return error.UnsupportedRomSamples;
        if (sample_type != 1 and sample_type != 2 and sample_type != 4 and sample_type != 8)
            return error.InvalidSample;
        if (sample.start >= sample.end or sample.end > frame_count or sample.sample_rate == 0)
            return error.InvalidSample;
        if (sample.loop_start > sample.loop_end or sample.loop_end > frame_count)
            return error.InvalidSample;
        if (frame_count - sample.end < 46)
            return error.InvalidSample;
        if (sample.original_key > 127 and sample.original_key != 255)
            return error.InvalidSample;
        if (sample_type != 1 and sample.link >= source.sampleCount())
            return error.InvalidIndex;

        var guards: [46]i16 = undefined;
        try source_helpers.readFrames(source, sample.end, &guards);
        for (guards) |guard|
            if (guard != 0)
                return error.InvalidSample;

        if (source.hasLowFrames()) {
            var low_guards: [46]u8 = undefined;
            try source_helpers.readLowFrames(source, sample.end, &low_guards);
            for (low_guards) |guard|
                if (guard != 0)
                    return error.InvalidSample;
        }
    }

    try zones(source, true);
    try zones(source, false);

    var extras = source.extraChunks();
    while (try extras.next()) |chunk| {
        const reserved: []const []const u8 = switch (chunk.parent) {
            .top => &.{"RIFF"},
            .sdta => &.{ "smpl", "sm24" },
            .pdta => &.{ "phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr" },
        };
        for (reserved) |tag|
            if (binary.equal(&chunk.tag, tag))
                return error.DuplicateChunk;

        if (chunk.parent == .top and binary.equal(&chunk.tag, "LIST")) {
            if (chunk.data.len < 4)
                return error.InvalidChunk;

            for ([_][]const u8{ "INFO", "sdta", "pdta" }) |tag|
                if (binary.equal(chunk.data[0..4], tag))
                    return error.DuplicateChunk;
        }
    }
}

fn zones(source: anytype, comptime preset: bool) !void {
    var bag_count: usize = 0;
    var gen_count: usize = 0;
    var mod_count: usize = 0;
    const object_count = if (preset) source.presetCount() else source.instrumentCount();
    const target_count = if (preset) source.instrumentCount() else source.sampleCount();

    for (0..object_count) |object_index| {
        const object = if (preset)
            try source.presetAt(object_index)
        else
            try source.instrumentAt(object_index);

        if (object.zone_start > object.zone_end)
            return error.InvalidIndex;

        const zone_count = object.zone_end - object.zone_start;
        if (zone_count == 0)
            return error.InvalidZone;

        bag_count = std.math.add(usize, bag_count, zone_count) catch return error.TooLarge;
        _ = try binary.index(bag_count);

        var local_count: usize = 0;
        for (0..zone_count) |zone_index| {
            const zone = if (preset)
                try source.presetZone(object_index, zone_index)
            else
                try source.instrumentZone(object_index, zone_index);

            gen_count = std.math.add(usize, gen_count, zone.generatorCount()) catch return error.TooLarge;
            mod_count = std.math.add(usize, mod_count, zone.modulatorCount()) catch return error.TooLarge;

            if (zone.target) |target| {
                if (@intFromEnum(target) >= target_count)
                    return error.InvalidIndex;

                local_count += 1;
                gen_count = std.math.add(usize, gen_count, 1) catch return error.TooLarge;
            } else if (zone_index != 0 or (zone.generatorCount() == 0 and zone.modulatorCount() == 0)) {
                return error.InvalidZone;
            }

            _ = try binary.index(gen_count);
            _ = try binary.index(mod_count);

            for (0..zone.generatorCount()) |generator_index| {
                const generator = try zone.generatorAt(generator_index);
                if (generator.operator == .instrument or generator.operator == .sample_id)
                    return error.InvalidZone;

                if (generator.operator == .key_range or generator.operator == .vel_range) {
                    const range = generator.rangeAmount();
                    if (range.low > range.high or range.high > 127)
                        return error.InvalidZone;
                    if (generator.operator == .key_range and generator_index != 0)
                        return error.InvalidZone;
                    if (generator.operator == .vel_range and generator_index != 0 and
                        (generator_index != 1 or (try zone.generatorAt(0)).operator != .key_range))
                        return error.InvalidZone;
                }
            }

            for (0..zone.modulatorCount()) |modulator_index|
                _ = try zone.modulatorAt(modulator_index);
        }

        if (local_count == 0)
            return error.InvalidZone;
    }
}
