# BlindWatermark

Version: **3.0.0 (v6, unreleased)** · [中文](README.md)

A low-amplitude screen watermark for iOS. Screenshots can recover uid, timestamp, build time, page code, app, and note entirely offline. The Swift runtime uses system frameworks only, with iOS 13 / macOS 11 minimums; the Demo requires iOS 15.

**3.0.0 is a breaking, v6-only migration.** The v4/v5.2 codecs, raw-bit APIs, HMAC, page registry, and mixed-protocol detection have been removed. Historical screenshots require historical tools. v6 cannot restore an old signal already destroyed by compression. The old v4 build number, tag, 15-character page, and 22-byte free-text note are replaced by the compact fields below. No server-side token lookup is required.

v6 combines BCH(511,211,t40) with overall even parity, two differently interleaved copies, a smooth 32×8 px carrier, and a separate chroma synchronization column. Defaults are `delta=4` and `plane=chroma`. CRC24 checks integrity; **it is not a signature or identity authentication**. Low amplitude does not guarantee invisibility. Visibility must be reviewed on target devices, especially dark and photo pages.

## Installation and payload

Add this repository through SPM using its release tag, or CocoaPods with matching versions for all three pods (`3.0.0` after release). Use a local path while testing the development branch.

```ruby
pod 'BlindWatermark', :path => '/path/to/BlindWatermark'
```

```swift
import BlindWatermark

// Configure on the main thread. Use a stable business-defined UInt32 uid.
guard let payload = WatermarkPayload(
    uid: 123456,
    timestamp: UInt64(Date().timeIntervalSince1970),
    buildTime: 1_790_064_000, // Inject actual UTC Unix seconds from the build pipeline
    pageClassName: "BHUserProfileViewController",
    app: 11,
    note: "ticket"
) else { fatalError("Payload exceeds v6 limits") }
Watermark.install(payload: payload) // delta=4, plane=.chroma

// Construct a fresh payload when the page or timestamp changes.
Watermark.update(payload: payload)
```

| Field | Bits | Range / meaning |
|---|---:|---|
| profile | 4 | Fixed at 6 |
| uid | 32 | UInt32 |
| timestamp | 31 | Seconds since 2026-01-01 00:00:00 UTC |
| buildTime | 24 | Minutes since the same epoch; Unix seconds are rounded down |
| page | 42 | An 8-character base37 code |
| app | 14 | 0…9999 |
| note | 32 | Up to 6 base37 characters |
| CRC24 | 24 | Integrity check over the preceding 179 bits |
| reserved | 8 | Must be zero |

The 211 bits occupy 27 bytes; the last byte's upper five bits must be zero. The base37 alphabet is `a-z0-9_`, with the first character as the most significant radix digit. Fields are right-padded with `_`, and trailing underscores are removed on decode, so literal trailing underscores cannot be distinguished. `pageClassName` removes the module name and common class prefixes/suffixes, lowercases, then truncates to eight characters. Codes may collide and do not uniquely identify a class. Notes cannot contain Chinese/free text or exceed six characters. The `pageCode:` / `noteCode:` initializer rejects oversized or invalid codes.

ObjC `+load` still enables zero-configuration installation. Without explicit configuration, uid is an FNV-1a hash of IDFV, timestamp is the refresh time, build time is the protocol epoch, page/note are empty, and app is zero. This exercises the pipeline rather than establishing identity. Set `Watermark.payloadProvider: (() -> WatermarkPayload)?` on the main thread for a typed payload on each refresh when no explicit install is present. Explicit installation uses `update` instead. Each scene has a non-interactive watermark window that does not become the key window.

## Decoding

```bash
swift build -c release
.build/release/bwdecode shot.jpg --layout
.build/release/bwdecode shot.jpg --layout --scale 0.837
python3 tools/bwdecode.py shot.jpg --layout
```

The Python tooling continues to use numpy/Pillow; the Swift runtime does not depend on them. Only `--protocol v6` is supported. `--auto` means the default geometry search. `--plane` must match the renderer, defaulting to chroma. Luma is an experimental visibility mode and does not inherit chroma visibility conclusions.

Default decoding tries scale 1.0, then 21 coarse scales from 0.50…1.50 followed by local refinement. Use `--scale` when the ratio is known. Decoder APIs and the CLI accept only finite scales in the closed range 0.5…1.5. The two Chase retry candidates are ranked by their own pilotScore, preserving input order on ties. Nonnegative `--offset X,Y` fixes pixel phase, disables dark-border trimming, and still searches tile shifts. Without it, phase is relative to the trimmed image. Only uniform dark borders are conservatively trimmed; white or irregular frames rely on geometry search and cannot always be recovered.

The first line reports `protocol=v6`, the 27-byte `payload`, plane, phase, tileShift, scale, correctedBits, softRecovery, pilotScore, minObs, avgObs, median absolute z, and optional `trim=(left,top,right,bottom)`. Successful `--layout` decoding prints the complete fields on the second line ending with:

```text
crcStatus=OK(完整性自检,未验签)
```

There is no `mac=` field. No BCH + CRC-valid candidate produces `NO`; multiple distinct valid payloads produce `ambiguous`. Both exit 1. Invalid arguments exit 2, with no historical fallback.

**Every codeword bit needs at least five non-overlapping physical cell observations before fields are interpreted.** Cells quantized to zero by JPEG still count, but contribute zero signal. Observation count is not confidence. Evidence counts include only cells fully inside the content rectangle, bounded by RGB-nonuniform rows and columns. Uniform outer padding is excluded without changing coordinates or signal statistics; internal JPEG erasures still count. This does not identify textured frames or arbitrary unwatermarked regions. BCH, valid fields, and CRC must also pass. Small images may pass CRC yet produce `TOO_SMALL`: with `--layout`, exit 1 and no fields; without it, diagnostics and a warning only, exit 0.

## Validation and samples

```bash
swift test
python3 tools/test_bwdecode.py
Demo/sweep.sh <booted-simulator-UDID> 4 chroma
python3 tools/benchmark_v6.py --input-dir /private/tmp/bw-v6-demo-samples
python3 tools/benchmark_channels.py --input-dir /private/tmp/bw-v6-demo-samples --automatic
```

The sweep requires installed XcodeBuildMCP and sim-use tools plus device authorization. It captures original device pixels across plain, white chat, text list, photo, dark, and mixed pages. Combined-channel tests cover cropping, off-grid resizing, two JPEG passes, black/white frames, and small-image refusal, with Swift/Python agreement on the same files.

See [the v6 protocol and measurement record](docs/v6-protocol.md) for exact conditions and limits. The [decode skill](skills/blind-watermark/SKILL.md) reads screenshots; the [integration skill](skills/blind-watermark-integration/SKILL.md) handles installation and acceptance. Committed samples contain only Demo content.

Photographs of a display, perspective distortion, arbitrary rotation, tiny crops, severe blur, or complete carrier quantization are outside recovery guarantees. Reported results describe only the recorded samples and transformations, not every messaging application.
