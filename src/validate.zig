const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");

pub fn validate(bank: model.Bank) binary.Error!void {
    const version = bank.metadata("ifil".*) orelse return error.MissingChunk;
    if (version.len != 4)
        return error.InvalidMetadata;

    const major = std.mem.readInt(u16, version[0..2], .little);
    const minor = std.mem.readInt(u16, version[2..4], .little);
    if (major != 2 or minor > 4)
        return error.UnsupportedVersion;

    for ([_][4]u8{ "isng".*, "INAM".* }) |tag| {
        const value = bank.metadata(tag) orelse return error.MissingChunk;
        if (value.len == 0 or value.len > 256 or value.len % 2 != 0 or value[value.len - 1] != 0)
            return error.InvalidMetadata;
    }
    for (bank.info, 0..) |entry, entry_index| {
        for (bank.info[0..entry_index]) |previous| {
            if ((binary.equal(&entry.tag, "ifil") or
                binary.equal(&entry.tag, "isng") or
                binary.equal(&entry.tag, "INAM")) and
                binary.equal(&entry.tag, &previous.tag))
                return error.DuplicateChunk;
        }
    }

    if (bank.sample_data.len > std.math.maxInt(u32))
        return error.TooLarge;
    if (bank.sample_data_low) |low| {
        if (minor < 4 or low.len != bank.sample_data.len)
            return error.InvalidSample;
    }

    if (bank.presets.len == 0 or bank.instruments.len == 0)
        return error.InvalidTable;

    _ = try binary.index(bank.presets.len);
    _ = try binary.index(bank.instruments.len);
    _ = try binary.index(bank.samples.len);

    for (bank.samples) |sample| {
        const sample_type = @intFromEnum(sample.sample_type);
        if (sample_type & 0x8000 != 0)
            return error.UnsupportedRomSamples;
        if (sample_type != 1 and sample_type != 2 and sample_type != 4 and sample_type != 8)
            return error.InvalidSample;
        if (sample.start >= sample.end or sample.end > bank.sample_data.len or sample.sample_rate == 0)
            return error.InvalidSample;
        if (sample.loop_start > sample.loop_end or sample.loop_end > bank.sample_data.len)
            return error.InvalidSample;
        if (bank.sample_data.len - sample.end < 46)
            return error.InvalidSample;

        for (bank.sample_data[sample.end..][0..46]) |guard|
            if (guard != 0)
                return error.InvalidSample;
        if (bank.sample_data_low) |low| {
            for (low[sample.end..][0..46]) |guard|
                if (guard != 0)
                    return error.InvalidSample;
        }

        if (sample.original_key > 127 and sample.original_key != 255)
            return error.InvalidSample;
        if (sample_type != 1 and sample.link >= bank.samples.len)
            return error.InvalidIndex;
    }

    try zones(bank.presets, bank.instruments.len);
    try zones(bank.instruments, bank.samples.len);

    for (bank.extra_chunks) |chunk| {
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
            for ([_][]const u8{ "INFO", "sdta", "pdta" }) |tag| {
                if (binary.equal(chunk.data[0..4], tag))
                    return error.DuplicateChunk;
            }
        }
    }
}

fn zones(objects: anytype, target_count: usize) binary.Error!void {
    var bag_count: usize = 0;
    var gen_count: usize = 0;
    var mod_count: usize = 0;

    for (objects) |object| {
        if (object.zones.len == 0)
            return error.InvalidZone;

        var local_count: usize = 0;
        for (object.zones, 0..) |zone, zone_index| {
            bag_count = std.math.add(usize, bag_count, 1) catch return error.TooLarge;
            gen_count = std.math.add(usize, gen_count, zone.generators.len) catch return error.TooLarge;
            mod_count = std.math.add(usize, mod_count, zone.modulators.len) catch return error.TooLarge;

            if (zone.target) |target| {
                if (@intFromEnum(target) >= target_count)
                    return error.InvalidIndex;

                local_count += 1;
                gen_count = std.math.add(usize, gen_count, 1) catch return error.TooLarge;
            } else if (zone_index != 0 or zone.generators.len + zone.modulators.len == 0) {
                return error.InvalidZone;
            }

            for (zone.generators, 0..) |generator, generator_index| {
                if (generator.operator == .instrument or generator.operator == .sample_id)
                    return error.InvalidZone;

                if (generator.operator == .key_range or generator.operator == .vel_range) {
                    const range = generator.rangeAmount();
                    if (range.low > range.high or range.high > 127)
                        return error.InvalidZone;
                    if (generator.operator == .key_range and generator_index != 0)
                        return error.InvalidZone;
                    if (generator.operator == .vel_range and generator_index != 0 and
                        (generator_index != 1 or zone.generators[0].operator != .key_range))
                        return error.InvalidZone;
                }
            }
        }

        if (local_count == 0)
            return error.InvalidZone;
    }

    _ = try binary.index(bag_count);
    _ = try binary.index(gen_count);
    _ = try binary.index(mod_count);
}
