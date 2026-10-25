const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    Truncated,
    InvalidRiff,
    InvalidChunk,
    DuplicateChunk,
    MissingChunk,
    UnsupportedVersion,
    UnsupportedRomSamples,
    InvalidMetadata,
    InvalidTable,
    InvalidIndex,
    InvalidZone,
    InvalidSample,
    TooLarge,
};

pub fn equal(first: []const u8, second: []const u8) bool {
    return std.mem.eql(u8, first, second);
}

pub const Cursor = struct {
    data: []const u8,
    position: usize = 0,

    pub fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (count > self.data.len - self.position)
            return error.Truncated;

        const result = self.data[self.position..][0..count];
        self.position += count;

        return result;
    }

    pub fn int(self: *Cursor, comptime Integer: type) Error!Integer {
        const bytes = try self.take(@sizeOf(Integer));

        return std.mem.readInt(Integer, bytes[0..@sizeOf(Integer)], .little);
    }

    pub fn next(self: *Cursor) Error!?struct { tag: [4]u8, data: []const u8 } {
        if (self.position == self.data.len)
            return null;

        const tag = (try self.take(4))[0..4].*;
        const size = try self.int(u32);
        const data = try self.take(size);
        _ = try self.take(size % 2);

        return .{ .tag = tag, .data = data };
    }
};

pub fn index(value: usize) Error!u16 {
    return std.math.cast(u16, value) orelse error.TooLarge;
}
