const model = @import("model.zig");
const Error = @import("binary.zig").Error;

pub const PresetHeader = struct {
    name: model.Name,
    program: u16,
    bank: u16,
    library: u32,
    genre: u32,
    morphology: u32,
    zone_start: usize,
    zone_end: usize,
};

pub const InstrumentHeader = struct {
    name: model.Name,
    zone_start: usize,
    zone_end: usize,
};

pub fn SliceCursor(comptime Entry: type) type {
    return struct {
        entries: []const Entry,
        index: usize = 0,

        pub fn next(self: *@This()) Error!?Entry {
            if (self.index == self.entries.len)
                return null;

            const entry = self.entries[self.index];
            self.index += 1;

            return entry;
        }
    };
}

pub fn BankZone(comptime Target: type) type {
    return struct {
        target: ?Target,
        generators: []const model.Generator,
        modulators: []const model.Modulator,

        pub fn generatorCount(self: @This()) usize {
            return self.generators.len;
        }

        pub fn generatorAt(self: @This(), index: usize) Error!model.Generator {
            if (index >= self.generators.len)
                return error.InvalidIndex;

            return self.generators[index];
        }

        pub fn modulatorCount(self: @This()) usize {
            return self.modulators.len;
        }

        pub fn modulatorAt(self: @This(), index: usize) Error!model.Modulator {
            if (index >= self.modulators.len)
                return error.InvalidIndex;

            return self.modulators[index];
        }
    };
}

pub const BankSource = struct {
    bank: model.Bank,

    pub fn metadata(self: BankSource) SliceCursor(model.Info) {
        return .{ .entries = self.bank.info };
    }

    pub fn metadataCount(self: BankSource) usize {
        return self.bank.info.len;
    }

    pub fn metadataAt(self: BankSource, index: usize) Error!model.Info {
        if (index >= self.bank.info.len)
            return error.InvalidIndex;

        return self.bank.info[index];
    }

    pub fn sampleCount(self: BankSource) usize {
        return self.bank.samples.len;
    }

    pub fn sampleAt(self: BankSource, index: usize) Error!model.Sample {
        if (index >= self.bank.samples.len)
            return error.InvalidIndex;

        return self.bank.samples[index];
    }

    pub fn presetCount(self: BankSource) usize {
        return self.bank.presets.len;
    }

    pub fn presetAt(self: BankSource, index: usize) Error!PresetHeader {
        if (index >= self.bank.presets.len)
            return error.InvalidIndex;

        const preset = self.bank.presets[index];
        return .{
            .name = preset.name,
            .program = preset.program,
            .bank = preset.bank,
            .library = preset.library,
            .genre = preset.genre,
            .morphology = preset.morphology,
            .zone_start = 0,
            .zone_end = preset.zones.len,
        };
    }

    pub fn presetZone(self: BankSource, object: usize, index: usize) Error!BankZone(model.InstrumentId) {
        if (object >= self.bank.presets.len or index >= self.bank.presets[object].zones.len)
            return error.InvalidIndex;

        const zone = self.bank.presets[object].zones[index];
        return .{ .target = zone.target, .generators = zone.generators, .modulators = zone.modulators };
    }

    pub fn instrumentCount(self: BankSource) usize {
        return self.bank.instruments.len;
    }

    pub fn instrumentAt(self: BankSource, index: usize) Error!InstrumentHeader {
        if (index >= self.bank.instruments.len)
            return error.InvalidIndex;

        const instrument = self.bank.instruments[index];
        return .{ .name = instrument.name, .zone_start = 0, .zone_end = instrument.zones.len };
    }

    pub fn instrumentZone(self: BankSource, object: usize, index: usize) Error!BankZone(model.SampleId) {
        if (object >= self.bank.instruments.len or index >= self.bank.instruments[object].zones.len)
            return error.InvalidIndex;

        const zone = self.bank.instruments[object].zones[index];
        return .{ .target = zone.target, .generators = zone.generators, .modulators = zone.modulators };
    }

    pub fn frameCount(self: BankSource) usize {
        return self.bank.sample_data.len;
    }

    pub fn hasLowFrames(self: BankSource) bool {
        return self.bank.sample_data_low != null;
    }

    pub fn lowFrameCount(self: BankSource) usize {
        return if (self.bank.sample_data_low) |low| low.len else 0;
    }

    pub fn readFrames(self: BankSource, offset: usize, buffer: []i16) Error!usize {
        if (offset > self.bank.sample_data.len)
            return error.InvalidIndex;

        const count = @min(buffer.len, self.bank.sample_data.len - offset);
        @memcpy(buffer[0..count], self.bank.sample_data[offset..][0..count]);

        return count;
    }

    pub fn readLowFrames(self: BankSource, offset: usize, buffer: []u8) Error!usize {
        const low = self.bank.sample_data_low orelse return error.InvalidSample;
        if (offset > low.len)
            return error.InvalidIndex;

        const count = @min(buffer.len, low.len - offset);
        @memcpy(buffer[0..count], low[offset..][0..count]);

        return count;
    }

    pub fn extraCount(self: BankSource) usize {
        return self.bank.extra_chunks.len;
    }

    pub fn extraChunks(self: BankSource) SliceCursor(model.Chunk) {
        return .{ .entries = self.bank.extra_chunks };
    }

    pub fn extraAt(self: BankSource, index: usize) Error!model.Chunk {
        if (index >= self.bank.extra_chunks.len)
            return error.InvalidIndex;

        return self.bank.extra_chunks[index];
    }
};

pub fn readFrames(source: anytype, offset: usize, buffer: []i16) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try source.readFrames(offset + filled, buffer[filled..]);
        if (count == 0 or count > buffer.len - filled)
            return error.InvalidSample;

        filled += count;
    }
}

pub fn readLowFrames(source: anytype, offset: usize, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try source.readLowFrames(offset + filled, buffer[filled..]);
        if (count == 0 or count > buffer.len - filled)
            return error.InvalidSample;

        filled += count;
    }
}
