# Using SoundFondue

SoundFondue is a Zig 0.16 module for reading, editing, and writing SoundFont 2 banks. The [specification summary](sf2-spec-2.04.md) describes the underlying format; this guide describes the module.

## Read, edit, write

The application owns file I/O, paths, size limits, and save/replace policy. There are no process-global resources.

### Inspect without allocating

`File.parse(bytes)` retains borrowed spans into the input, checking RIFF sizes, chunk boundaries, table widths, and monotonic table indices. `file.validate()` checks metadata, references, zones, sample bounds, and guard frames. Both operations work without allocating. Keep the original bytes alive and immutable for the lifetime of the file and any records, metadata payloads, zones, or frame cursors borrowed from it.

```zig
const sf = @import("soundfondue");

const file = try sf.File.parse(input_bytes);
try file.validate();

const id: sf.SampleId = @enumFromInt(0);
const sample = try file.samples.get(id);
var frames = try file.frames(id);
while (try frames.next()) |frame| {
    // Use the signed PCM value here.
}
```

`file.presets`, `file.instruments`, and `file.samples` expose `count()`, `get(index)`, and `openCursor()`. Cursors return decoded records by value and exclude terminal records. Preset and instrument headers retain their encoded `zone_start` and `zone_end` indices; `file.presetZone(object, local_index)` and `file.instrumentZone(object, local_index)` expose their zones. Zone generators and modulators support the same table access.

PCM stays encoded in the borrowed view. `Frames.next()` reads a little-endian signed 16-bit value without assuming alignment or host byte order. `Frames.read(buffer)` decodes a block into caller-supplied storage. For 24-bit banks, these are the high 16 bits; `file.readLowFrames(offset, buffer)` reads the corresponding low bytes by absolute pool offset. `file.readFrames(offset, buffer)` similarly reads any part of the entire pool, including unused frames. `file.metadata()` walks borrowed INFO records, and `file.extraChunks()` walks borrowed opaque chunks. Both advance sequentially; use them rather than repeated indexed lookups to traverse a whole list. Validation, sizing, writing, and document materialization use these cursors and take linear time over the lists.

### Materialize a document to edit

Use `file.toDocument(allocator)` after inspecting a borrowed file, or `decode(allocator, bytes)` to parse and materialize in one call.

```zig
const sf = @import("soundfondue");

var document = try sf.decode(allocator, input_bytes);
defer document.deinit();

const samples = try document.allocator().dupe(sf.Sample, document.bank.samples);
samples[0].pitch_correction = -7;
document.bank.samples = samples;

const output_bytes = try sf.encode(allocator, document.bank);
defer allocator.free(output_bytes);
```

Materializing validates the file, decodes its PCM pool into one owned allocation, and copies metadata, zones, modulators, low sample bytes, and opaque payloads into `Document.arena`. It does not retain a copy of the encoded input file. The input may be freed immediately after success. `Document.deinit()` frees the entire document, including edits allocated through `document.allocator()`. Treat a document as a single owner; do not copy it and deinitialize both copies. Allocators obtained from a document must not outlive it or be retained across moving the document.

`Bank` contains decoded, nested slices; `File` contains encoded, borrowed spans. A bank can also be constructed directly from caller-owned slices and passed to `validate` or `encode`; no `Document` is needed. Its slices must remain alive throughout those calls. Encoding neither modifies the bank nor takes ownership of it. Its returned bytes belong to the allocator passed to `encode`.

### Write to a stream

```zig
try sf.write(writer, document.bank);
try sf.writeSource(writer, file);
```

`write` adapts a `Bank`; `writeSource` accepts either `bank.source()`, a borrowed `File`, or a [custom indexed source](sources.md). Both validate the source and calculate all sizes and table counts with checked arithmetic before emitting any bytes. Headers contain their final sizes; output requires neither seeking nor backpatching. PCM is read and encoded in blocks of at most 512 frames, with bounded scratch space and no output allocation. The writer's own buffering and any custom source allocations remain under caller control. Flush the writer yourself when needed.

`encode(allocator, bank)` uses the same writing implementation with `std.Io.Writer.Allocating` and returns the complete byte buffer. `Layout.calculate(source)` calculates checked sizes without reading PCM; it is a sizing operation, not a replacement for full validation. Full validation separately reads the 46 guard frames after each sample in each present PCM plane.

Keep the source and its borrowed storage unchanged throughout validation, sizing, and writing. Structural and size errors are detected before output begins. Source or output failures during emission can leave partial output; `writeSource` propagates source errors, and writer errors use `error.WriteFailed`. Neither writer flushes or rolls back partial output. `encode` maps allocating-writer failures to `error.OutOfMemory` and frees any partial buffer.

## Representation

- `Bank.info` retains INFO tags and raw payloads. The default is a 2.04 bank named Untitled, targeting EMU8000. Mandatory text fields include zero terminators and have an even byte count.
- `Bank.sample_data` contains the shared signed 16-bit PCM pool. Optional `sample_data_low` contains one low byte per frame for 24-bit samples. It excludes the `sm24` alignment byte. No normalization, downmixing, or resampling occurs.
- `Sample` retains its 20-byte name, absolute pool offsets, exclusive end and loop end, sample rate, original MIDI key, signed pitch correction in cents, sample type, and link. `Bank.frames(id)` returns a borrowed sample slice. Linked stereo channels remain separate sample records. Key 255 retains the unpitched marker.
- `Preset` retains name, bank/program numbers, reserved library fields, and zones. `Instrument` retains name and zones. Duplicate bank/program addresses and orphaned samples are preserved. Array indices are stable typed references.
- `PresetZone.target` is an optional `InstrumentId`; `InstrumentZone.target` is an optional `SampleId`. A null target represents the first, global zone. Targets are serialized as the final instrument/sample-ID generator automatically.
- `Generator` stores a non-exhaustive `Operator` and the original 16-bit amount. `signed`/`signedAmount` and `range`/`rangeAmount` handle its three encodings. Key and velocity ranges stay in the generator list, retaining their ordering. `zone.generator(op)` retrieves the last matching entry, without inheritance.
- `Modulator` retains source and amount-source bitfields, destination, signed amount, and transform. Unknown generator operators and modulator fields survive.
- `extra_chunks` retains opaque top-level, sdta, and pdta payloads. Unknown LIST chunks include their four-byte list type in the payload. Unknown INFO fields remain in `info`.

Sample offsets deliberately refer to the original shared pool. Retaining the pool also preserves overlapping sample ranges, unused frames, and regions addressed by zone offset generators. When constructing a bank, include at least 46 zero frames after every sample's exclusive end, in both PCM planes. The writer does not repack the pool or generate guard frames. For example, a 64-frame sample can use a 110-frame pool with `start = 0`, `end = 64`, and zero frames at positions 64..110. Looping behavior is specified by the instrument zone's `sample_modes` generator, not a boolean on the sample header.

All generators retain SF2 units: timecents, cents, centibels, and so on. Helpers `timecentsToSeconds` and `centibelsToGain` are explicit conversions only. They do not resolve global/local inheritance, combine preset and instrument parameters, apply defaults, or evaluate modulators.

## Substrate boundary

SoundFondue retains original rates, roots, tuning, loop ends, envelopes, key and velocity zones, and bank/program addresses. Substrate's current sample loader uses engine-rate tuning compensation, truncates PCM to implement a loop end, converts PCM16 to floating point, and applies ADSR per channel. Those translations belong in Substrate. Its sample-slot limits, current GM assignment CSV, and SMuLE's borrowed floating-point sample descriptors do not constrain this model.

An adapter will need to define how it selects layers, maps parameters, and reports unsupported synthesis features.

## Validation and round trips

Parsing checks RIFF sizes and padding, required lists and tables, record widths, monotonic table indices, and terminal index coverage. Full validation checks reference bounds, zone structure, sample bounds and guard frames, and mandatory metadata. The writer runs full validation and enforces the format's 16-bit table-index and 32-bit RIFF-size limits before output. Malformed input fails without publishing a partial document. Every allocation failure releases intermediate storage.

Round trips preserve represented data, not the original byte layout. The writer uses canonical list/table order, moves opaque chunks to the end of their parent, emits zero RIFF padding and conventional terminal records, and normalizes the optional `sm24` alignment byte. Terminal record fields and original chunk positions are not retained. Unknown chunks remain opaque: external offsets inside them are not interpreted or relocated.

This first pass supports SF2 2.00 through 2.04 RAM sample banks. ROM sample banks, SF3 compression, and newer format extensions requiring a changed sample encoding are unsupported. Structural validation is intentionally stricter than permissive synthesizers: malformed zones and metadata are rejected rather than repaired. It does not certify complete musical validity or portable hardware playback.

Tests cover an independently assembled SF2 2.01 fixture, 16/24-bit round trips, stereo metadata, global and local zones, native parameters, opaque chunks, truncation, byte mutations, hostile indices, table overflow, allocation failures, unaligned input, detached document ownership, direct/allocating writer equivalence, checked layout sizing, short block reads, and partial-output failures. A third-party bank corpus and live Substrate integration remain future validation work.

See the [SF2 specification summary](sf2-spec-2.04.md) for the file format, including [sample data](sf2-spec-2.04.md#6-the-sdta-list-chunk), [zone rules](sf2-spec-2.04.md#important-rules), and [generator units](sf2-spec-2.04.md#81-generators).

Tests and fixtures live in `tests/` and import the public `soundfondue` module. `zig build test` runs them; `zig build check` compiles them without running them, including when cross-compiling.
