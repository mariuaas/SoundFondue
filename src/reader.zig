const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const Cursor = binary.Cursor;
const Error = binary.Error;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    bank: model.Bank,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!Document {
    var document: Document = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .bank = .{},
    };
    errdefer document.deinit();

    const owned = try document.allocator().dupe(u8, input);
    try readBank(document.allocator(), &document.bank, owned);
    try @import("validate.zig").validate(document.bank);

    return document;
}

fn readBank(allocator: std.mem.Allocator, bank: *model.Bank, bytes: []const u8) Error!void {
    var root: Cursor = .{ .data = bytes };
    if (!binary.equal(try root.take(4), "RIFF"))
        return error.InvalidRiff;

    const size = try root.int(u32);
    if (size < 4 or size != bytes.len - 8)
        return error.InvalidRiff;
    if (!binary.equal(try root.take(4), "sfbk"))
        return error.InvalidRiff;

    var lists: [3]?[]const u8 = @splat(null);
    var extras: std.ArrayList(model.Chunk) = .empty;

    while (try root.next()) |chunk| {
        if (binary.equal(&chunk.tag, "LIST")) {
            if (chunk.data.len < 4)
                return error.InvalidChunk;

            var known = false;
            for ([_][]const u8{ "INFO", "sdta", "pdta" }, 0..) |tag, list_index| {
                if (binary.equal(chunk.data[0..4], tag)) {
                    if (lists[list_index] != null)
                        return error.DuplicateChunk;

                    lists[list_index] = chunk.data[4..];
                    known = true;
                    break;
                }
            }
            if (known)
                continue;
        }

        try extras.append(allocator, .{ .parent = .top, .tag = chunk.tag, .data = chunk.data });
    }

    var info: std.ArrayList(model.Info) = .empty;
    var info_cursor: Cursor = .{ .data = lists[0] orelse return error.MissingChunk };
    while (try info_cursor.next()) |chunk| {
        try info.append(allocator, .{ .tag = chunk.tag, .data = chunk.data });
    }
    bank.info = try info.toOwnedSlice(allocator);

    var sdta: Cursor = .{ .data = lists[1] orelse return error.MissingChunk };
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
        } else {
            try extras.append(allocator, .{ .parent = .sdta, .tag = chunk.tag, .data = chunk.data });
        }
    }

    if (pcm) |data| {
        if (data.len % 2 != 0)
            return error.InvalidSample;

        const frames = try allocator.alloc(i16, data.len / 2);
        var cursor: Cursor = .{ .data = data };

        for (frames) |*frame|
            frame.* = try cursor.int(i16);

        bank.sample_data = frames;
    }
    if (low) |data| {
        const count = bank.sample_data.len;
        if (data.len != count and data.len != count + count % 2)
            return error.InvalidSample;
        bank.sample_data_low = data[0..count];
    }

    var pdta: Cursor = .{ .data = lists[2] orelse return error.MissingChunk };
    var tables: [9]?[]const u8 = @splat(null);
    const tags = [_][]const u8{ "phdr", "pbag", "pmod", "pgen", "inst", "ibag", "imod", "igen", "shdr" };

    while (try pdta.next()) |chunk| {
        var known = false;
        for (tags, 0..) |tag, table_index| {
            if (binary.equal(&chunk.tag, tag)) {
                if (tables[table_index] != null)
                    return error.DuplicateChunk;

                tables[table_index] = chunk.data;
                known = true;
                break;
            }
        }
        if (!known)
            try extras.append(allocator, .{ .parent = .pdta, .tag = chunk.tag, .data = chunk.data });
    }

    const widths = [_]usize{ 38, 4, 10, 4, 22, 4, 10, 4, 46 };
    for (tables, widths) |maybe_table, width| {
        const table = maybe_table orelse return error.MissingChunk;
        if (table.len == 0 or table.len % width != 0)
            return error.InvalidTable;
    }
    const preset_zones = try readZones(
        model.PresetZone,
        allocator,
        tables[1].?,
        tables[2].?,
        tables[3].?,
        .instrument,
    );
    const instrument_zones = try readZones(
        model.InstrumentZone,
        allocator,
        tables[5].?,
        tables[6].?,
        tables[7].?,
        .sample_id,
    );

    const presets = try allocator.alloc(model.Preset, tables[0].?.len / 38 - 1);
    var preset_cursor: Cursor = .{ .data = tables[0].? };
    var expected_bag: usize = 0;

    for (presets) |*preset| {
        preset.name = (try preset_cursor.take(20))[0..20].*;
        preset.program = try preset_cursor.int(u16);
        preset.bank = try preset_cursor.int(u16);
        const first = try preset_cursor.int(u16);
        preset.library = try preset_cursor.int(u32);
        preset.genre = try preset_cursor.int(u32);
        preset.morphology = try preset_cursor.int(u32);

        const last = std.mem.readInt(u16, preset_cursor.data[preset_cursor.position + 24 ..][0..2], .little);
        if (first != expected_bag or first > last or last > preset_zones.len)
            return error.InvalidIndex;

        preset.zones = preset_zones[first..last];
        expected_bag = last;
    }
    if (expected_bag != preset_zones.len)
        return error.InvalidIndex;
    bank.presets = presets;

    const instruments = try allocator.alloc(model.Instrument, tables[4].?.len / 22 - 1);
    var inst_cursor: Cursor = .{ .data = tables[4].? };
    expected_bag = 0;

    for (instruments) |*instrument| {
        instrument.name = (try inst_cursor.take(20))[0..20].*;
        const first = try inst_cursor.int(u16);
        const last = std.mem.readInt(u16, inst_cursor.data[inst_cursor.position + 20 ..][0..2], .little);
        if (first != expected_bag or first > last or last > instrument_zones.len)
            return error.InvalidIndex;

        instrument.zones = instrument_zones[first..last];
        expected_bag = last;
    }
    if (expected_bag != instrument_zones.len)
        return error.InvalidIndex;
    bank.instruments = instruments;

    const samples = try allocator.alloc(model.Sample, tables[8].?.len / 46 - 1);
    var sample_cursor: Cursor = .{ .data = tables[8].? };

    for (samples) |*sample| {
        sample.name = (try sample_cursor.take(20))[0..20].*;
        sample.start = try sample_cursor.int(u32);
        sample.end = try sample_cursor.int(u32);
        sample.loop_start = try sample_cursor.int(u32);
        sample.loop_end = try sample_cursor.int(u32);
        sample.sample_rate = try sample_cursor.int(u32);
        sample.original_key = try sample_cursor.int(u8);
        sample.pitch_correction = try sample_cursor.int(i8);
        sample.link = try sample_cursor.int(u16);
        sample.sample_type = @enumFromInt(try sample_cursor.int(u16));
    }
    bank.samples = samples;
    bank.extra_chunks = try extras.toOwnedSlice(allocator);
}

fn readZones(
    comptime Zone: type,
    allocator: std.mem.Allocator,
    bags: []const u8,
    mods: []const u8,
    gens: []const u8,
    target_operator: model.Operator,
) Error![]const Zone {
    const zones = try allocator.alloc(Zone, bags.len / 4 - 1);
    var bag_cursor: Cursor = .{ .data = bags };
    var expected_gen: usize = 0;
    var expected_mod: usize = 0;

    for (zones) |*zone| {
        const first_gen = try bag_cursor.int(u16);
        const first_mod = try bag_cursor.int(u16);

        var next_bag = bag_cursor;
        const last_gen = try next_bag.int(u16);
        const last_mod = try next_bag.int(u16);
        if (first_gen != expected_gen or first_mod != expected_mod or
            first_gen > last_gen or first_mod > last_mod or
            last_gen >= gens.len / 4 or last_mod >= mods.len / 10)
            return error.InvalidIndex;

        var gen_cursor: Cursor = .{ .data = gens[@as(usize, first_gen) * 4 .. @as(usize, last_gen) * 4] };
        var generators: std.ArrayList(model.Generator) = .empty;
        zone.* = .{};

        while (gen_cursor.position < gen_cursor.data.len) {
            const operator: model.Operator = @enumFromInt(try gen_cursor.int(u16));
            const amount = try gen_cursor.int(u16);

            if (operator == target_operator) {
                if (gen_cursor.position != gen_cursor.data.len)
                    return error.InvalidZone;

                zone.target = @enumFromInt(amount);
            } else {
                try generators.append(allocator, .{ .operator = operator, .amount = amount });
            }
        }
        zone.generators = try generators.toOwnedSlice(allocator);

        const modulators = try allocator.alloc(model.Modulator, last_mod - first_mod);
        var mod_cursor: Cursor = .{ .data = mods[@as(usize, first_mod) * 10 .. @as(usize, last_mod) * 10] };

        for (modulators) |*modulator| {
            modulator.source = try mod_cursor.int(u16);
            modulator.destination = @enumFromInt(try mod_cursor.int(u16));
            modulator.amount = try mod_cursor.int(i16);
            modulator.amount_source = try mod_cursor.int(u16);
            modulator.transform = try mod_cursor.int(u16);
        }
        zone.modulators = modulators;
        expected_gen = last_gen;
        expected_mod = last_mod;
    }

    if (expected_gen != gens.len / 4 - 1 or expected_mod != mods.len / 10 - 1)
        return error.InvalidIndex;
    if (zones.len == 0) {
        if (try bag_cursor.int(u16) != 0 or try bag_cursor.int(u16) != 0)
            return error.InvalidIndex;
    }

    return zones;
}
