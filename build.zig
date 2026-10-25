const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.addModule(
        "soundfondue",
        .{
            .root_source_file = builder.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const test_module = builder.createModule(
        .{
            .root_source_file = builder.path("tests/soundfont_test.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    test_module.addImport("soundfondue", module);
    const tests = builder.addTest(.{ .root_module = test_module });
    builder.step("test", "Run SoundFont reader/writer tests").dependOn(&builder.addRunArtifact(tests).step);
    builder.step("check", "Compile library tests without running them").dependOn(&tests.step);
}
