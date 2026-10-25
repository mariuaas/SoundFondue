const std = @import("std");

pub const model = @import("model.zig");
pub const Bank = model.Bank;
pub const Sample = model.Sample;
pub const Preset = model.Preset;
pub const Instrument = model.Instrument;
pub const PresetZone = model.PresetZone;
pub const InstrumentZone = model.InstrumentZone;
pub const Generator = model.Generator;
pub const Operator = model.Operator;
pub const Modulator = model.Modulator;
pub const Info = model.Info;
pub const Chunk = model.Chunk;
pub const Name = model.Name;
pub const name = model.name;
pub const InstrumentId = model.InstrumentId;
pub const SampleId = model.SampleId;
pub const Range = model.Range;
pub const SampleType = model.SampleType;
pub const Error = @import("binary.zig").Error;
pub const Document = @import("reader.zig").Document;
pub const decode = @import("reader.zig").decode;
pub const encode = @import("writer.zig").encode;
pub const validate = @import("validate.zig").validate;

pub fn timecentsToSeconds(value: i16) f64 {
    return if (value == std.math.minInt(i16))
        0
    else
        std.math.pow(f64, 2, @as(f64, @floatFromInt(value)) / 1200);
}

pub fn centibelsToGain(value: i16) f64 {
    return std.math.pow(f64, 10, -@as(f64, @floatFromInt(value)) / 200);
}
