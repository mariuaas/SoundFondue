const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const Output = binary.Output;
const Error = binary.Error;

pub fn encode(allocator: std.mem.Allocator, bank: model.Bank) Error![]u8 {
    try @import("validate.zig").validate(bank);

    var output: Output = .{ .allocator = allocator };
    defer output.deinit();

    const riff = try output.begin("RIFF");
    try output.append("sfbk");

    const info = try output.begin("LIST");
    try output.append("INFO");
    for (bank.info) |entry|
        try output.chunk(&entry.tag, entry.data);
    try output.end(info);

    const sdta = try output.begin("LIST");
    try output.append("sdta");
    const smpl = try output.begin("smpl");
    for (bank.sample_data) |frame|
        try output.int(i16, frame);
    try output.end(smpl);
    if (bank.sample_data_low) |low| {
        const sm24 = try output.begin("sm24");
        try output.append(low);
        if (low.len % 2 != 0)
            try output.int(u8, 0);
        try output.end(sm24);
    }
    try extra(&output, bank, .sdta);
    try output.end(sdta);

    const pdta = try output.begin("LIST");
    try output.append("pdta");

    const phdr = try output.begin("phdr");
    var bag_index: usize = 0;

    for (bank.presets) |preset| {
        try output.append(&preset.name);
        try output.int(u16, preset.program);
        try output.int(u16, preset.bank);
        try output.int(u16, try binary.index(bag_index));
        try output.int(u32, preset.library);
        try output.int(u32, preset.genre);
        try output.int(u32, preset.morphology);
        bag_index += preset.zones.len;
    }

    try output.append(&(model.name("EOP") catch unreachable));
    try output.int(u16, 0);
    try output.int(u16, 0);
    try output.int(u16, try binary.index(bag_index));
    try output.append(&@as([12]u8, @splat(0)));
    try output.end(phdr);
    try zoneTables(&output, bank.presets, "pbag", "pmod", "pgen", .instrument);

    const inst = try output.begin("inst");
    bag_index = 0;
    for (bank.instruments) |instrument| {
        try output.append(&instrument.name);
        try output.int(u16, try binary.index(bag_index));
        bag_index += instrument.zones.len;
    }
    try output.append(&(model.name("EOI") catch unreachable));
    try output.int(u16, try binary.index(bag_index));
    try output.end(inst);
    try zoneTables(&output, bank.instruments, "ibag", "imod", "igen", .sample_id);

    const shdr = try output.begin("shdr");
    for (bank.samples) |sample| {
        try output.append(&sample.name);
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

    try output.append(&(model.name("EOS") catch unreachable));
    try output.append(&@as([26]u8, @splat(0)));
    try output.end(shdr);
    try extra(&output, bank, .pdta);
    try output.end(pdta);
    try extra(&output, bank, .top);
    try output.end(riff);

    return output.bytes.toOwnedSlice(allocator);
}

fn extra(output: *Output, bank: model.Bank, parent: @FieldType(model.Chunk, "parent")) Error!void {
    for (bank.extra_chunks) |chunk| {
        if (chunk.parent == parent)
            try output.chunk(&chunk.tag, chunk.data);
    }
}

fn zoneTables(
    output: *Output,
    objects: anytype,
    bag_tag: []const u8,
    mod_tag: []const u8,
    gen_tag: []const u8,
    target_operator: model.Operator,
) Error!void {
    const bag = try output.begin(bag_tag);
    var gen_index: usize = 0;
    var mod_index: usize = 0;

    for (objects) |object| {
        for (object.zones) |zone| {
            try output.int(u16, try binary.index(gen_index));
            try output.int(u16, try binary.index(mod_index));
            gen_index += zone.generators.len + @intFromBool(zone.target != null);
            mod_index += zone.modulators.len;
        }
    }
    try output.int(u16, try binary.index(gen_index));
    try output.int(u16, try binary.index(mod_index));
    try output.end(bag);

    const mods = try output.begin(mod_tag);

    for (objects) |object| {
        for (object.zones) |zone| {
            for (zone.modulators) |modulator| {
                try output.int(u16, modulator.source);
                try output.int(u16, @intFromEnum(modulator.destination));
                try output.int(i16, modulator.amount);
                try output.int(u16, modulator.amount_source);
                try output.int(u16, modulator.transform);
            }
        }
    }
    try output.append(&@as([10]u8, @splat(0)));
    try output.end(mods);

    const gens = try output.begin(gen_tag);

    for (objects) |object| {
        for (object.zones) |zone| {
            for (zone.generators) |generator| {
                try output.int(u16, @intFromEnum(generator.operator));
                try output.int(u16, generator.amount);
            }
            if (zone.target) |target| {
                try output.int(u16, @intFromEnum(target_operator));
                try output.int(u16, @intFromEnum(target));
            }
        }
    }
    try output.int(u32, 0);
    try output.end(gens);
}
