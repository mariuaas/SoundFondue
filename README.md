# SoundFondue

This is a small SF2 format reader / writer written in Zig. Extracted / constructed to function alongside some other private projects I am working on, particularly [SMuLE](https://github.com/mariuaas/SMuLE) and [NoteSelf](https://github.com/mariuaas/noteself). They were extracted because the other projects are bloating up in size, and I rather like extracting reusable modular variants that others might use in their projects.

Inspect a bank without allocating, load a document to edit, or write straight to a `std.Io.Writer`. No dependencies or playback engine; bring your own file I/O.

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

const file = try sf.File.parse(input_bytes);
try file.validate();

try sf.writeSource(writer, file);
```

Need to edit? `file.toDocument(allocator)` gives you an owning bank. `decode` and `encode` are there for convenient whole-file buffers too. The [guide](docs/guide.md) covers ownership, the representation, and the current limitations; [custom sources](docs/sources.md) explains how to supply your own data. There's also a [summary of the SF2 spec](docs/sf2-spec-2.04.md) if you want to dig into the file format.

## Testing and Dev

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check
zig fmt --check build.zig src tests
```

Tests and fixtures live in `tests/`. `check` compiles them without running them. Tests are not exhaustive at all yet.
