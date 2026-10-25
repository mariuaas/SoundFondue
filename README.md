# SoundFondue

This is a small SF2 format reader / writer written in Zig. Extracted / constructed to function alongside some other private projects I am working on, particularly [SMuLE](https://github.com/mariuaas/SMuLE) and [NoteSelf](https://github.com/mariuaas/noteself). They were extracted because the other projects are bloating up in size, and I rather like extracting reusable modular variants that others might use in their projects.

It reads a bank into an editable document and writes it back out. No dependencies or playback engine; bring your own file I/O.

## Getting started

SoundFondue uses **Zig 0.16.0**. Add it as a package dependency, then connect it to your build:

```zig
const soundfondue = builder.dependency("soundfondue", .{
    .target = target,
    .optimize = optimize,
});
consumer.root_module.addImport("soundfondue", soundfondue.module("soundfondue"));
```

Already have SF2 bytes in memory?

```zig
const sf = @import("soundfondue");

var document = try sf.decode(allocator, input_bytes);
defer document.deinit();

const output_bytes = try sf.encode(allocator, document.bank);
defer allocator.free(output_bytes);
```

The [guide](docs/guide.md) covers editing, ownership, the bank representation, and the current limitations. There's also a [summary of the SF2 spec](docs/sf2-spec-2.04.md) if you want to dig into the file format.

## Testing and Dev

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check
zig fmt --check build.zig src tests
```

Tests and fixtures live in `tests/`. `check` compiles them without running them. Tests are not exhaustive at all yet.
