const std = @import("std");

pub const Name = [20]u8;

pub fn name(value: []const u8) error{NameTooLong}!Name {
    if (value.len > 20)
        return error.NameTooLong;

    var result: Name = @splat(0);
    @memcpy(result[0..value.len], value);

    return result;
}

pub const InstrumentId = enum(u16) { _ };
pub const SampleId = enum(u16) { _ };

pub const Range = struct {
    low: u8 = 0,
    high: u8 = 127,
};

pub const Operator = enum(u16) {
    start_addrs_offset = 0,
    end_addrs_offset = 1,
    startloop_addrs_offset = 2,
    endloop_addrs_offset = 3,
    start_addrs_coarse_offset = 4,
    mod_lfo_to_pitch = 5,
    vib_lfo_to_pitch = 6,
    mod_env_to_pitch = 7,
    initial_filter_fc = 8,
    initial_filter_q = 9,
    mod_lfo_to_filter_fc = 10,
    mod_env_to_filter_fc = 11,
    end_addrs_coarse_offset = 12,
    mod_lfo_to_volume = 13,
    chorus_effects_send = 15,
    reverb_effects_send = 16,
    pan = 17,
    delay_mod_lfo = 21,
    freq_mod_lfo = 22,
    delay_vib_lfo = 23,
    freq_vib_lfo = 24,
    delay_mod_env = 25,
    attack_mod_env = 26,
    hold_mod_env = 27,
    decay_mod_env = 28,
    sustain_mod_env = 29,
    release_mod_env = 30,
    keynum_to_mod_env_hold = 31,
    keynum_to_mod_env_decay = 32,
    delay_vol_env = 33,
    attack_vol_env = 34,
    hold_vol_env = 35,
    decay_vol_env = 36,
    sustain_vol_env = 37,
    release_vol_env = 38,
    keynum_to_vol_env_hold = 39,
    keynum_to_vol_env_decay = 40,
    instrument = 41,
    key_range = 43,
    vel_range = 44,
    startloop_addrs_coarse_offset = 45,
    keynum = 46,
    velocity = 47,
    initial_attenuation = 48,
    endloop_addrs_coarse_offset = 50,
    coarse_tune = 51,
    fine_tune = 52,
    sample_id = 53,
    sample_modes = 54,
    scale_tuning = 56,
    exclusive_class = 57,
    overriding_root_key = 58,
    _,
};

pub const Generator = struct {
    operator: Operator,
    amount: u16,

    pub fn signed(operator: Operator, value: i16) Generator {
        return .{ .operator = operator, .amount = @bitCast(value) };
    }

    pub fn range(operator: Operator, value: Range) Generator {
        return .{ .operator = operator, .amount = @as(u16, value.high) << 8 | value.low };
    }

    pub fn signedAmount(self: Generator) i16 {
        return @bitCast(self.amount);
    }

    pub fn rangeAmount(self: Generator) Range {
        return .{ .low = @truncate(self.amount), .high = @truncate(self.amount >> 8) };
    }
};

pub const Modulator = struct {
    source: u16,
    destination: Operator,
    amount: i16,
    amount_source: u16,
    transform: u16,
};

fn Zone(comptime Target: type) type {
    return struct {
        target: ?Target = null,
        generators: []const Generator = &.{},
        modulators: []const Modulator = &.{},

        pub fn generator(self: @This(), operator: Operator) ?Generator {
            var index = self.generators.len;
            while (index > 0) {
                index -= 1;
                const entry = self.generators[index];
                if (entry.operator == operator)
                    return entry;
            }

            return null;
        }
    };
}

pub const PresetZone = Zone(InstrumentId);
pub const InstrumentZone = Zone(SampleId);

pub const Preset = struct {
    name: Name,
    program: u16 = 0,
    bank: u16 = 0,
    library: u32 = 0,
    genre: u32 = 0,
    morphology: u32 = 0,
    zones: []const PresetZone,
};

pub const Instrument = struct {
    name: Name,
    zones: []const InstrumentZone,
};

pub const SampleType = enum(u16) {
    mono = 1,
    right = 2,
    left = 4,
    linked = 8,
    rom_mono = 0x8001,
    rom_right = 0x8002,
    rom_left = 0x8004,
    rom_linked = 0x8008,
    _,
};

pub const Sample = struct {
    name: Name,
    start: u32,
    end: u32,
    loop_start: u32,
    loop_end: u32,
    sample_rate: u32,
    original_key: u8 = 60,
    pitch_correction: i8 = 0,
    link: u16 = 0,
    sample_type: SampleType = .mono,
};

pub const Info = struct {
    tag: [4]u8,
    data: []const u8,
};

pub const Chunk = struct {
    parent: enum { top, sdta, pdta },
    tag: [4]u8,
    data: []const u8,
};

/// Slices are borrowed. decode returns a Document owning all of its Bank's storage.
/// Sample positions are absolute frame offsets in the shared pool; ends are exclusive.
/// Zone target == null denotes a global zone. Reference generators live in target,
/// not in generators. Generators and modulators retain their original SF2 units.
pub const Bank = struct {
    info: []const Info = &.{
        .{ .tag = "ifil".*, .data = &.{ 2, 0, 4, 0 } },
        .{ .tag = "isng".*, .data = "EMU8000\x00" },
        .{ .tag = "INAM".*, .data = "Untitled\x00\x00" },
    },
    sample_data: []const i16 = &.{},
    sample_data_low: ?[]const u8 = null,
    samples: []const Sample = &.{},
    instruments: []const Instrument = &.{},
    presets: []const Preset = &.{},
    extra_chunks: []const Chunk = &.{},

    pub fn source(self: Bank) @import("source.zig").BankSource {
        return .{ .bank = self };
    }

    pub fn metadata(self: Bank, tag: [4]u8) ?[]const u8 {
        for (self.info) |entry|
            if (std.mem.eql(u8, &entry.tag, &tag))
                return entry.data;

        return null;
    }

    pub fn frames(self: Bank, id: SampleId) ?[]const i16 {
        const index = @intFromEnum(id);
        if (index >= self.samples.len)
            return null;

        const sample = self.samples[index];
        if (@intFromEnum(sample.sample_type) & 0x8000 != 0 or
            sample.start > sample.end or
            sample.end > self.sample_data.len)
            return null;

        return self.sample_data[sample.start..sample.end];
    }
};
