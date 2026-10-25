# Using SoundFondue

SoundFondue is a Zig 0.16 module for reading, editing, and writing SoundFont 2 banks. The [specification summary](sf2-spec-2.04.md) describes the underlying format; this guide describes the module.

## Read, edit, write

`decode` and `encode` operate on whole-file bytes. The application owns file I/O, paths, size limits, and save/replace policy. There are no process-global resources.

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

Decoding copies the input and owns all decoded storage in `Document.arena`. The input may be freed immediately. `Document.deinit()` frees the entire document, including edits allocated through `document.allocator()`. Treat a document as a single owner; do not copy it and deinitialize both copies. Allocators obtained from a document must not outlive it or be retained across moving the document.

`Bank` itself is a borrowed view. It can also be constructed directly from caller-owned slices and passed to `validate` or `encode`; no `Document` is needed. Its slices must remain alive throughout those calls. Encoding neither modifies the bank nor takes ownership of it. Its returned bytes belong to the allocator passed to `encode`.

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

The reader checks RIFF sizes and padding, required lists and tables, record widths, monotonic table indices, terminal index coverage, reference bounds, zone structure, sample bounds and guard frames, and mandatory metadata. The writer runs the same checks and enforces the format's 16-bit table-index limits. Malformed input fails without publishing a partial document. Every allocation failure releases intermediate storage.

Round trips preserve represented data, not the original byte layout. The writer uses canonical list/table order, moves opaque chunks to the end of their parent, emits zero RIFF padding and conventional terminal records, and normalizes the optional `sm24` alignment byte. Terminal record fields and original chunk positions are not retained. Unknown chunks remain opaque: external offsets inside them are not interpreted or relocated.

This first pass supports SF2 2.00 through 2.04 RAM sample banks. ROM sample banks, SF3 compression, and newer format extensions requiring a changed sample encoding are unsupported. Structural validation is intentionally stricter than permissive synthesizers: malformed zones and metadata are rejected rather than repaired. It does not certify complete musical validity or portable hardware playback.

Tests cover an independently assembled SF2 2.01 fixture, 16/24-bit round trips, stereo metadata, global and local zones, native parameters, opaque chunks, truncation, byte mutations, hostile indices, table overflow, and allocation failures. A third-party bank corpus and live Substrate integration remain future validation work.

See the [SF2 specification summary](sf2-spec-2.04.md) for the file format, including [sample data](sf2-spec-2.04.md#6-the-sdta-list-chunk), [zone rules](sf2-spec-2.04.md#important-rules), and [generator units](sf2-spec-2.04.md#81-generators).

Tests and fixtures live in `tests/` and import the public `soundfondue` module. `zig build test` runs them; `zig build check` compiles them without running them, including when cross-compiling.
