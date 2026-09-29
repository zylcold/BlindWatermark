# BlindWatermark

Code version: **3.0.0** · Protocol: **v6** · [中文](README.md)

A low-amplitude chroma watermark for iOS screens. Recover uid, timestamp, build time, page code, app, and note from screenshots entirely offline, without a server lookup. The Swift runtime uses system frameworks only and supports iOS 13 / macOS 11; the Demo requires iOS 15.

Only v6 is supported. Historical screenshots require the corresponding historical tools. Defaults are `delta=4` and `plane=chroma`. CRC24 checks integrity, not signatures or identity. Review watermark visibility on target devices.

## Installation

Use the `main` branch for v6. In Swift Package Manager, add `https://github.com/zylcold/BlindWatermark.git`, select branch `main`, and choose the `BlindWatermark` product. Published versions are listed in [Releases](https://github.com/zylcold/BlindWatermark/releases).

For CocoaPods, point all three modules at the same source:

```ruby
watermark_source = { :git => 'https://github.com/zylcold/BlindWatermark.git', :branch => 'main' }
pod 'BlindWatermarkCore', watermark_source
pod 'BlindWatermarkAutoLoad', watermark_source
pod 'BlindWatermark', watermark_source
```

## Integration

Configure the payload on the main thread:

```swift
import BlindWatermark

guard let payload = WatermarkPayload(
    uid: 123456,
    timestamp: UInt64(Date().timeIntervalSince1970),
    buildTime: 1_790_064_000, // Example; inject actual UTC Unix seconds from the build pipeline
    pageClassName: "BHUserProfileViewController",
    app: 11,
    note: "ticket"
) else { fatalError("Payload exceeds v6 limits") }

Watermark.install(payload: payload) // delta=4, plane=.chroma
// On a page or timestamp change, construct a new payload and call Watermark.update(payload: newPayload).
```

| Field | Bits | Range / meaning |
|---|---:|---|
| uid | 32 | A stable business-defined UInt32 code |
| timestamp | 31 | Seconds since 2026-01-01 00:00:00 UTC |
| buildTime | 24 | Minutes since the same epoch; Unix seconds are rounded down |
| page | 42 | Up to 8 base37 characters |
| app | 14 | 0…9999 |
| note | 32 | Up to 6 base37 characters |

The base37 alphabet is `a-z0-9_`; decoding removes trailing underscores. `pageClassName` removes the module name and common class prefixes/suffixes, lowercases, then truncates to eight characters. Codes may collide. Notes accept only the listed characters. The `pageCode:` / `noteCode:` initializer rejects oversized or invalid codes.

ObjC `+load` mounts the watermark automatically. Without configuration, uid is an FNV-1a hash of IDFV, timestamp is the refresh time, build time is the protocol epoch, page/note are empty, and app is zero. Provide a business payload explicitly, or set `Watermark.payloadProvider` to generate one on each refresh when no explicit install is present. Each scene uses a watermark window that receives no touches and does not become the key window.

## Decoding

```bash
swift build -c release
.build/release/bwdecode shot.jpg --layout
.build/release/bwdecode shot.jpg --layout --scale 0.837
```

The decoder searches scale and phase automatically. Supply `--scale` when known; the valid range is 0.5…1.5. `--plane` must match the renderer and defaults to chroma; luma is experimental. Nonnegative `--offset X,Y` fixes pixel phase and disables automatic dark-border trimming. Without it, the reported phase is relative to the trimmed image.

Successful decoding with `--layout` reports the full payload and fields with `crcStatus=OK(完整性自检,未验签)`. Every codeword bit requires at least five valid physical observations. Uniform outer padding adds no observations; internal JPEG erasures still count. Observation count is not confidence.

If the primary chroma channel yields no valid payload, the decoder tries the existing R/G companion residual and reports `companionRecovery=true` on recovery. This changes decoding only, without increasing rendering strength; small-image and ambiguous results remain refusals.

| Result | Meaning | Exit code |
|---|---|---:|
| Success | One valid payload passes BCH, field validation, CRC, and the observation threshold | 0 |
| `TOO_SMALL` | Insufficient observations; `--layout` prints no fields | 1 with `--layout`; otherwise a warning and 0 |
| `NO` / `ambiguous` | No valid payload / multiple distinct valid payloads | 1 |
| Invalid arguments | Invalid options, scale, or phase | 2 |

The Python mirror uses numpy/Pillow: `python3 tools/bwdecode.py shot.jpg --layout`. See [the v6 protocol](docs/v6-protocol.md) for diagnostics, payload layout, and search algorithms.

## Validation and limits

```bash
swift test
python3 tools/test_bwdecode.py
```

Regression tests cover cropping, resizing, repeated JPEG encoding, frames, and small-image refusal, including Swift/Python agreement on the same files. [Samples](docs/samples/samples.json) and [measurement records](docs/v6-protocol.md#2026-09-28-本机验收) provide reproducible data and commands.

Tiny crops, severe blur, complete carrier quantization, photographs of a display, arbitrary rotation, and perspective distortion are outside recovery guarantees. Recorded success rates apply only to the listed samples and transformations. Actual messaging-app transfers, target devices, and visibility on dark/photo pages require separate acceptance checks.

See [the recovery analysis](docs/wechat-recovery.md) for measured messaging-app compression results and further improvement directions.

For agents: [decode skill](skills/blind-watermark/SKILL.md) · [integration skill](skills/blind-watermark-integration/SKILL.md).
