# SoundFont® Technical Specification

**Version 2.04**  
February 3, 2006

> Extracted and lightly structured from the official PDF for reference.  
> Original document is terse and assumes familiarity with RIFF and wavetable synthesis.

## 0 About This Document

### Revision History

| Rev. | Date              | Description |
|------|-------------------|-------------|
| 2.04 | September 10, 2002 | Add support for 24 bit samples |
| 2.01 | August 2, 1997     | Add specification for Modulators and standard NRPN implementation |
| 2.00b | May 2, 1997       | Change nomenclature from layer/split to zone. Fix typos |
| 2.00a | October 18, 1995   | First publicly released draft |

**Disclaimer**: Provided “AS IS”. License grants copy/reproduce/distribute for internal use only. SoundFont® is a registered trademark of E-mu Systems, Inc.

## 1 Introduction

This is the definitive source for the SoundFont 2 standard. It allows correct construction and interpretation of SoundFont 2 compatible banks. It does **not** cover synthesizer design or implementation.

### Objectives
Extensible, portable, universal interchange format for wavetable synthesizer samples and articulation data. Extensibility comes from enumerated generators and modulators. Portability from precisely defined, hardware-independent parameters.

Key improvements over 1.x:
- Relative parameters at the Preset level
- Improved sample data structures
- Stricter sample data rules
- Modulators

## 3 RIFF Structure

SoundFont files are RIFF files with form type `sfbk`.

A SoundFont 2 file consists of three top-level chunks (in fixed order):

1. **INFO-list** — metadata
2. **sdta-list** — sample data (`smpl` + optional `sm24`)
3. **pdta-list** — the nine “hydra” articulation sub-chunks

INFO sub-chunks may appear in any order. All other ordering is strict.

Unknown INFO sub-chunks must be ignored. Structurally unsound files (length mismatches, etc.) should generally be rejected.

## 4 SoundFont 2 RIFF File Format

### Level 0
```
RIFF ('sfbk'
  <INFO-list>
  <sdta-list>
  <pdta-list>
)
```

### Level 1 (high level)
```
LIST ('INFO'
  <ifil-ck>          ; mandatory version
  <isng-ck>          ; mandatory sound engine
  <INAM-ck>          ; mandatory bank name
  [<irom-ck>]
  [<iver-ck>]
  [<ICRD-ck>]
  [<IENG-ck>]
  [<IPRD-ck>]
  [<ICOP-ck>]
  [<ICMT-ck>]
  [<ISFT-ck>]
)

LIST ('sdta'
  [<smpl-ck>]        ; 16-bit samples
  [<sm24-ck>]        ; optional 8-bit LSBs for 24-bit
)

LIST ('pdta'
  <phdr-ck>
  <pbag-ck>
  <pmod-ck>
  <pgen-ck>
  <inst-ck>
  <ibag-ck>
  <imod-ck>
  <igen-ck>
  <shdr-ck>
)
```

### Key Record Structures (Level 3)

**sfVersionTag** (ifil / iver)
```c
struct sfVersionTag {
  WORD wMajor;
  WORD wMinor;
};
```

**sfPresetHeader** (38 bytes)
```c
struct sfPresetHeader {
  CHAR achPresetName[20];
  WORD wPreset;
  WORD wBank;
  WORD wPresetBagNdx;
  DWORD dwLibrary;      // reserved, write 0
  DWORD dwGenre;        // reserved, write 0
  DWORD dwMorphology;   // reserved, write 0
};
```

**sfPresetBag** (4 bytes)
```c
struct sfPresetBag {
  WORD wGenNdx;
  WORD wModNdx;
};
```

**sfModList** (10 bytes) — used for both PMOD and IMOD
```c
struct sfModList {
  SFModulator sfModSrcOper;
  SFGenerator sfModDestOper;
  SHORT modAmount;
  SFModulator sfModAmtSrcOper;
  SFTransform sfModTransOper;
};
```

**sfGenList** (4 bytes) — used for both PGEN and IGEN
```c
struct sfGenList {
  SFGenerator sfGenOper;
  genAmountType genAmount;   // union of ranges / SHORT / WORD
};
```

**sfInst** (22 bytes)
```c
struct sfInst {
  CHAR achInstName[20];
  WORD wInstBagNdx;
};
```

**sfInstBag** (4 bytes)
```c
struct sfInstBag {
  WORD wInstGenNdx;
  WORD wInstModNdx;
};
```

**sfSample** (46 bytes)
```c
struct sfSample {
  CHAR achSampleName[20];
  DWORD dwStart;
  DWORD dwEnd;
  DWORD dwStartloop;
  DWORD dwEndloop;
  DWORD dwSampleRate;
  BYTE byOriginalKey;
  CHAR chCorrection;
  WORD wSampleLink;
  SFSampleLink sfSampleType;
};
```

### SFSampleLink
```c
enum SFSampleLink {
  monoSample       = 1,
  rightSample      = 2,
  leftSample       = 4,
  linkedSample     = 8,
  RomMonoSample    = 0x8001,
  RomRightSample   = 0x8002,
  RomLeftSample    = 0x8004,
  RomLinkedSample  = 0x8008
};
```

## 5 The INFO-list Chunk

| Sub-chunk | Required | Contents |
|-----------|----------|----------|
| ifil | Yes | `sfVersionTag` (always 4 bytes) |
| isng | Yes | ZSTR sound engine (default “EMU8000”) |
| INAM | Yes | ZSTR bank name |
| irom | No | ZSTR ROM name |
| iver | No | `sfVersionTag` ROM version |
| ICRD | No | ZSTR creation date |
| IENG | No | ZSTR engineer(s) |
| IPRD | No | ZSTR product |
| ICOP | No | ZSTR copyright |
| ICMT | No | ZSTR comments (up to 64 KiB) |
| ISFT | No | ZSTR tools used |

ZSTR = zero-terminated ASCII string, padded to even length.

## 6 The sdta-list Chunk

- **smpl**: 16-bit signed little-endian samples. Each sample must be followed by ≥46 zero samples.
- **sm24** (optional, 2.04+): one LSB byte per 16-bit sample in `smpl`. Must be exactly half the size of `smpl` (plus padding to even).

### Looping Rules
- Loop start and end are “equivalent points”.
- Minimum 8 valid samples before loop start and after loop end.
- The 8 samples surrounding both points should be identical for artifact-free interpolation.

## 7 The pdta-list Chunk (Hydra)

Nine mandatory sub-chunks. Terminal records exist to give the final index.

### Important Rules
- Indices must be monotonically increasing.
- Every non-terminal preset/instrument must have ≥1 zone.
- First zone of a preset/instrument may be a **global zone** (last generator is not Instrument/sampleID).
- Non-global zones must end with an Instrument (preset) or sampleID (instrument) generator.
- Duplicate generators/modulators in a zone: first is ignored.
- PGEN generators are **additive relative** to IGEN.
- PMOD modulators are **additive relative** to IMOD.
- IGEN generators and IMOD modulators are **absolute** (replace defaults).

## 8 Enumerators

### 8.1 Generators

There are five kinds: Index, Range, Substitution, Sample, Value.

**Common generators** (partial list; see original for full definitions and ranges):

| # | Name | Notes |
|---|------|-------|
| 0–4, 12, 45, 50 | Address offsets (coarse + fine) | Instrument level only |
| 5 | modLfoToPitch | cents |
| 6 | vibLfoToPitch | cents |
| 7 | modEnvToPitch | cents |
| 8 | initialFilterFc | absolute cents (default ~20 kHz) |
| 9 | initialFilterQ | centibels |
| 15 | chorusEffectsSend | 0.1% |
| 16 | reverbEffectsSend | 0.1% |
| 17 | pan | 0.1% (–500 left … +500 right) |
| 21–40 | LFO + Envelope parameters | timecents / centibels |
| 41 | instrument | Index generator (terminal for PGEN) |
| 43 | keyRange | Range (lo/hi in one WORD) |
| 44 | velRange | Range |
| 46 | keynum | Override (instrument only) |
| 47 | velocity | Override (instrument only) |
| 48 | initialAttenuation | centibels |
| 51 | coarseTune | semitones |
| 52 | fineTune | cents |
| 53 | sampleID | Index generator (terminal for IGEN) |
| 54 | sampleModes | 0=no loop, 1=continuous, 3=loop until key release |
| 56 | scaleTuning | cents/key (default 100) |
| 57 | exclusiveClass | instrument only |
| 58 | overridingRootKey | instrument only |

Default values and valid ranges are tabulated in the original specification (section 8.1.3).

### 8.2 Modulator Sources

16-bit bitfield:

- Bits 0–6: Index
- Bit 7: CC flag (0 = general palette, 1 = MIDI CC)
- Bit 8: Direction
- Bit 9: Polarity (0 = unipolar, 1 = bipolar)
- Bits 10–15: Type (0=linear, 1=concave, 2=convex, 3=switch)

### Default Modulators (instrument level)

These are implicit and must be explicitly overridden if unwanted:

- Note-On Velocity → Initial Attenuation (concave, negative unipolar, 960 cB)
- Note-On Velocity → Filter Cutoff (linear, negative unipolar, –2400 cents)
- Channel Pressure → Vib LFO to Pitch
- CC1 (Mod Wheel) → Vib LFO to Pitch
- CC7 (Volume) → Initial Attenuation
- CC10 (Pan) → Pan
- CC11 (Expression) → Initial Attenuation
- CC91 → Reverb Send
- CC93 → Chorus Send
- Pitch Wheel (scaled by Pitch Wheel Sensitivity) → Initial Pitch

## 9 Synthesis Model (Summary)

Wavetable oscillator + resonant low-pass filter + final gain amp + effects sends.

Two LFOs (modulation + vibrato) and two envelopes (modulation + volume).

All pitch and filter modulation is logarithmic (cents). Volume is in dB/centibels.

## 10 Error Handling

- Structural errors (bad sizes, non-monotonic indices, missing required chunks) → reject file.
- Unknown chunks/enumerators → ignore.
- Illegal parameter values → clamp or ignore according to specific rules.
- Missing terminators → structurally unsound.

---

*This extraction prioritizes the binary structures and rules needed for a reader/writer. The full original specification contains additional detail on modulator theory of operation, NRPN implementation, and the glossary.*

*Original document © E-mu Systems. This markdown is a structural extraction for reference purposes.*
