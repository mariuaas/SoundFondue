const std = @import("std");
const model = @import("model.zig");
const binary = @import("binary.zig");
const source_helpers = @import("source.zig");
const File = @import("file.zig").File;

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

pub fn decode(allocator: std.mem.Allocator, input: []const u8) binary.Error!Document {
    const file = try File.parse(input);
    return file.toDocument(allocator);
}

pub fn materialize(allocator: std.mem.Allocator, source: anytype) !Document {
    try @import("validate.zig").validateSource(source);

    var document: Document = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .bank = .{},
    };
    errdefer document.deinit();

    const owned = document.allocator();
    const info = try owned.alloc(model.Info, source.metadataCount());
    var metadata = source.metadata();
    for (info) |*entry| {
        const original = try metadata.next() orelse return error.InvalidMetadata;
        entry.* = .{ .tag = original.tag, .data = try owned.dupe(u8, original.data) };
    }
    document.bank.info = info;

    const frames = try owned.alloc(i16, source.frameCount());
    try source_helpers.readFrames(source, 0, frames);
    document.bank.sample_data = frames;

    if (source.hasLowFrames()) {
        const low = try owned.alloc(u8, source.frameCount());
        try source_helpers.readLowFrames(source, 0, low);
        document.bank.sample_data_low = low;
    }

    const samples = try owned.alloc(model.Sample, source.sampleCount());
    for (samples, 0..) |*sample, index|
        sample.* = try source.sampleAt(index);
    document.bank.samples = samples;

    const presets = try owned.alloc(model.Preset, source.presetCount());
    for (presets, 0..) |*preset, index| {
        const header = try source.presetAt(index);
        preset.* = .{
            .name = header.name,
            .program = header.program,
            .bank = header.bank,
            .library = header.library,
            .genre = header.genre,
            .morphology = header.morphology,
            .zones = try ownZones(true, owned, source, index, header.zone_end - header.zone_start),
        };
    }
    document.bank.presets = presets;

    const instruments = try owned.alloc(model.Instrument, source.instrumentCount());
    for (instruments, 0..) |*instrument, index| {
        const header = try source.instrumentAt(index);
        instrument.* = .{
            .name = header.name,
            .zones = try ownZones(false, owned, source, index, header.zone_end - header.zone_start),
        };
    }
    document.bank.instruments = instruments;

    const extras = try owned.alloc(model.Chunk, source.extraCount());
    var extra_cursor = source.extraChunks();
    for (extras) |*entry| {
        const original = try extra_cursor.next() orelse return error.InvalidChunk;
        entry.* = .{
            .parent = original.parent,
            .tag = original.tag,
            .data = try owned.dupe(u8, original.data),
        };
    }
    document.bank.extra_chunks = extras;

    return document;
}

fn OwnedZone(comptime preset: bool) type {
    return if (preset) model.PresetZone else model.InstrumentZone;
}

fn ownZones(
    comptime preset: bool,
    allocator: std.mem.Allocator,
    source: anytype,
    object: usize,
    count: usize,
) ![]const OwnedZone(preset) {
    const zones = try allocator.alloc(OwnedZone(preset), count);
    for (zones, 0..) |*zone, index| {
        const original = if (preset)
            try source.presetZone(object, index)
        else
            try source.instrumentZone(object, index);

        const generators = try allocator.alloc(model.Generator, original.generatorCount());
        for (generators, 0..) |*generator, generator_index|
            generator.* = try original.generatorAt(generator_index);

        const modulators = try allocator.alloc(model.Modulator, original.modulatorCount());
        for (modulators, 0..) |*modulator, modulator_index|
            modulator.* = try original.modulatorAt(modulator_index);

        zone.* = .{
            .target = original.target,
            .generators = generators,
            .modulators = modulators,
        };
    }

    return zones;
}
