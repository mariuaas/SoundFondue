# Custom sources

`writeSource(writer, source)` accepts a source with indexed fixed-width records and sequential variable-length lists. `bank.source()` and a borrowed `File` implement the same contract, so inspecting a file and writing it back does not require an owning document. The source provides records by value, borrowed metadata spans, and bounded PCM reads. It must remain unchanged throughout the call; any storage returned by its methods must stay valid throughout validation, sizing, and emission.

## Records

Count methods return `usize`. Indexed accessors return error unions so file-backed or other fallible sources can report failures. Indices start at zero and exclude terminal records. Counts, field values, zone lists, and references must describe one stable bank.

| Methods | Returned record |
| --- | --- |
| `metadata()` | A cursor returning `!?Info`, with a four-byte tag and borrowed payload |
| `sampleCount()`, `sampleAt(index)` | `Sample`, with absolute PCM pool offsets |
| `presetCount()`, `presetAt(index)` | `source.PresetHeader` |
| `instrumentCount()`, `instrumentAt(index)` | `source.InstrumentHeader` |
| `presetZone(object, local_index)` | A zone targeting an optional `InstrumentId` |
| `instrumentZone(object, local_index)` | A zone targeting an optional `SampleId` |
| `extraChunks()` | A cursor returning `!?Chunk`, with its parent, four-byte tag, and borrowed payload |

`metadata()` and `extraChunks()` open fresh, independent cursors. Each cursor's `next()` advances sequentially and returns null at the end. Validation, layout calculation, and writing traverse these lists in a bounded number of passes, so work is linear in the number of entries. Cursor errors propagate like other source errors. These operations do not require list counts or indexed list accessors. `File` and `BankSource` retain `metadataCount()`, `metadataAt(index)`, `extraCount()`, and `extraAt(index)` for inspection; counting or indexing a borrowed file list scans from its beginning, so use cursors when visiting all entries.

Headers contain `zone_start` and `zone_end`. Their difference gives the object's zone count. Zone accessors take a local index from zero to that count; the writer calculates its own flattened bag indices. A `BankSource` uses a zero start, while a `File` retains encoded bag offsets. Names and sample headers use the existing model types and SF2 units.

Each zone exposes a `target` field, `generatorCount()`, `generatorAt(index)`, `modulatorCount()`, and `modulatorAt(index)`. Generator and modulator accessors return `!Generator` and `!Modulator`. The optional target is typed as `?InstrumentId` for preset zones or `?SampleId` for instrument zones. A null target represents a global zone. Do not include the target generator in the generator list: the writer emits it last. Table counts and ordering must satisfy the same rules as a `Bank`.

## PCM blocks

```zig
pub fn frameCount(self: Source) usize;
pub fn hasLowFrames(self: Source) bool;
pub fn lowFrameCount(self: Source) usize;
pub fn readFrames(self: Source, offset: usize, buffer: []i16) !usize;
pub fn readLowFrames(self: Source, offset: usize, buffer: []u8) !usize;
```

Offsets address frames in the entire shared pool, including guards and unused regions. `readFrames` supplies signed high-16-bit PCM values in native integers; SoundFondue encodes little-endian bytes. If `hasLowFrames()` is true, `lowFrameCount()` must equal `frameCount()`, and `readLowFrames` supplies the low byte for each frame. Otherwise the low-plane accessor is never called.

Each read fills the beginning of the supplied buffer and returns the number of initialized elements. Short reads are supported. Returning zero before the requested block is complete, or returning a count larger than the buffer, fails with `error.InvalidSample`. Requests never exceed 512 frames. Full validation reads each sample's 46 guard frames, with similarly bounded requests; it does not scan the entire pool. Guard frames must be zero in both planes.

## Sizing and failures

`Layout.calculate(source)` inspects counts, metadata lengths, and zone structure to calculate chunk sizes and total output length. It does not call PCM readers. It checks arithmetic overflow, 16-bit table indices, and 32-bit chunk and RIFF sizes. `layout.byteCount()` includes the RIFF header. Layout calculation alone does not validate sample bounds, references, metadata contents, or guard frames.

`validateSource(source)` performs full validation without allocating. `writeSource` calls it and calculates the layout before writing headers. Source errors during these passes leave the writer untouched. Once emission begins, any source or writer error may leave partial output. No seeking or rollback is attempted, and flushing remains the caller's responsibility. For atomic file replacement, the application can write to a temporary file and replace the destination after successful writing and flushing.

See `ProbeSource` in [the tests](../tests/soundfont_test.zig) for an indexed source that delegates metadata to a `Bank` and exercises short reads, source failures, and large declared frame counts.
