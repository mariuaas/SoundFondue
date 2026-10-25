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

pub const Output = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Output) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn append(self: *Output, bytes: []const u8) Error!void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    pub fn int(self: *Output, comptime Integer: type, value: Integer) Error!void {
        var bytes: [@sizeOf(Integer)]u8 = undefined;
        std.mem.writeInt(Integer, &bytes, value, .little);
        try self.append(&bytes);
    }

    pub fn begin(self: *Output, tag: []const u8) Error!usize {
        const offset = self.bytes.items.len;
        try self.append(tag);
        try self.int(u32, 0);

        return offset;
    }

    pub fn end(self: *Output, offset: usize) Error!void {
        const size = self.bytes.items.len - offset - 8;
        const size32 = std.math.cast(u32, size) orelse return error.TooLarge;
        std.mem.writeInt(u32, self.bytes.items[offset + 4 ..][0..4], size32, .little);
        if (size % 2 != 0)
            try self.int(u8, 0);
    }

    pub fn chunk(self: *Output, tag: []const u8, data: []const u8) Error!void {
        const offset = try self.begin(tag);
        try self.append(data);
        try self.end(offset);
    }
};

pub fn index(value: usize) Error!u16 {
    return std.math.cast(u16, value) orelse error.TooLarge;
}
