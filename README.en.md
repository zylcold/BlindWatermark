# BlindWatermark

English · [中文](README.md)

A screen-level blind watermark for iOS: an invisible chroma perturbation covers the whole app
window, so **every screenshot carries it**. From a screenshot you can later recover **device,
time and page**, which is what you need to identify who reported a problem.

No screenshot API is hooked. Screenshots are composited by the render server, so the pixels of
the watermark window end up in the output by construction.

- Payload: 256 bit / 32 bytes — uid + Unix seconds + page name code + 96-bit HMAC
- Invisible: luma residual 0.07/255 (below the visibility threshold), chroma plane only
- Survives JPEG: 8×8 px blocks encoded in pairs, flat inside each block; decodes at q=0.6
- Decoding: `swift run bwdecode shot.png --auto --layout --key <hex>`, ~0.1 s for a full-screen shot

---

## Contents

- [Why it is invisible](#why-it-is-invisible)
- [How it works](#how-it-works)
- [Integration](#integration)
- [Parameters](#parameters)
- [Decoding](#decoding)
- [Default payload layout](#default-payload-layout)
- [Measured results and limits](#measured-results-and-limits)
- [Simulator smoke test](#simulator-smoke-test)
- [CI](#ci)
- [Compliance](#compliance)

---

## Why it is invisible

The watermark lives on the **blue–yellow opponent plane**, not on the luma plane.

The luma null direction is `(0.128, 0.128, -1)` (`0.299×0.128 + 0.587×0.128 − 0.114 = 0`).
Two adjacent blocks get `(0,0,a)` and `(p,p,0)` respectively; with `p = round(0.114a/0.886)`
the two colours have **equal luma and differ only in chroma**.

The point is that blending is **linear in premultiplied alpha**: the luma difference of the
composite equals the luma difference of the overlay colours in premultiplied space, so it does
not decay with alpha. `p` therefore has to hit that ratio exactly — at `a=6` rounding yields
`p=0`, i.e. pure black paired with pure blue, a 0.68/255 luma step, and the grid becomes visible.
`a=8, p=1` is the sweet spot with a 0.026/255 residual.

Measured on an iPhone 16 simulator (plain page, horizontal band with no gradient inside it, so
what is measured is the watermark alone):

| Mode | Luma range | Chroma range |
|---|---|---|
| **chroma, alpha 8 (default)** | **0.07 / 255** | 9.04 |
| luma, alpha 6 | 6.04 / 255 | 0.10 |

Luma moves by 0.03% — essentially nothing. Human acuity for high-frequency chroma is far lower
than for luma (roughly 1/4), so the remaining chroma grid is hard to notice too. That is also why
chroma is the default: the 6/255 luma grid of luma mode is visible up close.

## How it works

- The screen is covered by a tiled **8×8 px block** pattern (tile = 256×256 device pixels), not by
  single-pixel noise — the inside of a block is flat, so JPEG does not smear it away.
- Every two adjacent blocks (A, B) encode 1 bit: `1` → A darker, B brighter; `0` → the opposite.
- Decoding takes `d = mean(A) − mean(B)`. The dark block loses `−base·α`, the bright one gains
  `(255−base)·α`; the `base` terms cancel, so `d ≈ ∓alpha`. **Independent of the background** —
  white, black and dark photos all decode.
- Among the repeated observations of the same bit, **polarity flips every other copy**: the
  watermark component adds up with the same sign while the picture's own luma gradient cancels.
- Reading is not taking a sign: signed differences are accumulated and divided by the standard
  error to get a z value. The watermark grows linearly with the number of observations, content
  noise decays as `1/√n`. One iPhone 16 screenshot gives each bit ~90 observations
  (256-bit layout, 2 repetitions per tile).

The decode margin was also measured, not guessed (iPhone 16, 3x, luma mode, 32-bit layout):

| Scheme | Median \|z\| | Weak bits | Verdict |
|---|---|---|---|
| 16px blocks, delta 3 | 1.9 | 27/32 | decoding is luck |
| 8px blocks, delta 3 | 3.3 | 12/32 | still unstable |
| **8px blocks, delta 6 (luma default)** | **6.4** | **0/32** | **reliable** |
| no watermark (control) | 0.5 | 32/32 | no false positives |

Those numbers are for the 32-bit layout. The **256-bit layout divides the observations per bit by
8, and luma is no longer enough** (see [Measured results and limits](#measured-results-and-limits)),
which is why the defaults are chroma + delta 8.

## Integration

### Swift Package Manager

```swift
.package(url: "git@github.com:zylcold/BlindWatermark.git", branch: "main")
```

```swift
import BlindWatermark

// The server computes the MAC and ships all 32 bytes; the client only renders them
Watermark.install(payload: serverIssuedBytes)

// Update the page name code on navigation
Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts,
    pageClassName: type(of: self).description(), key: key).bytes)

// The 32-bit convenience entry point still exists
Watermark.install(payload: 0xDEAD_BEEF)
```

With nothing configured, a default payload is used (`identifierForVendor` hash + Unix seconds),
so it runs out of the box.

### CocoaPods

```ruby
pod 'BlindWatermark', :path => '/path/to/BlindWatermark'
# or point at git
# pod 'BlindWatermark', :git => 'git@github.com:zylcold/BlindWatermark.git'
```

### Things to watch

- Zero-touch auto loading relies on the object file holding the ObjC `+load` being linked. As long
  as the app does `import BlindWatermark` and calls `Watermark.install` once, that holds. If you
  truly want zero calls, add `-ObjC` to the app target, otherwise static linking drops that file.
- The watermark window uses `windowLevel = .alert + 1` and `isUserInteractionEnabled = false`: it
  does not steal the key window and does not affect the keyboard. The pattern's delta is 8, a
  0.07/255 luma residual — not perceivable.
- **Multi-scene (iPad split view, external display)**: one window per scene, handled.
  A mid-session displayScale change does not repaint the pattern; add a trait observer if you
  really ship external-display support.
- The three parameters **`payloadBits` / `plane` / `delta` must match exactly between encoder and
  decoder**. Put them in the app's configuration, do not rely on memory.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `payload` | — | Payload bytes; bit 0 is the lowest bit of `payload[0]` |
| `payloadBits` | `payload.count × 8` | Number of significant bits, max 256; the decoder must agree |
| `plane` | `chroma` | `chroma` = chroma plane (invisible), `luma` = luma plane (simple but visible) |
| `delta` (named `alpha` in code) | 8 | Perturbation amplitude. \|d\| at the decoder: ≈ delta in luma, ≈ 1.13×delta in chroma. **Minimum 2** |
| `offsetX/offsetY` | 0 | Pattern phase when decoding; only needed for cropped screenshots |
| `windowLevel` | `.alert + 1` | Watermark window level; above system alerts so alert screenshots are traceable |

## Decoding

```bash
swift build -c release
# Parameters known (fastest, 0.08 s)
.build/release/bwdecode shot.png --layout --pages Demo/pages.json --key <hex>

# Cropped shots / unknown plane or bit count (0.1 s, exhaustive search + MAC arbitration)
.build/release/bwdecode shot.png --auto --layout --pages Demo/pages.json --key <hex>

# Plane and bit count known, phase unknown (cropped, never resized)
.build/release/bwdecode shot.png --auto-offset --layout --pages Demo/pages.json --key <hex>

# Print the short code of every class in the registry
.build/release/bwdecode --pages Demo/pages.json --dump-codes
```

`--auto` enumerates **2 planes × 64 phases × 512 tile shifts** (bit count defaults to 256 only; a
different `--bits` is added as a candidate only when passed explicitly) and arbitrates with the
MAC. Measured at 0.1 s (iPhone 16 screenshot, M1 Pro, release build).

`--auto-offset` is the narrower version: it assumes `--bits` / `--plane` are already correct
(256 / chroma by default) and only searches **the block grid phase (mod 8)**. It additionally
enumerates the 512 tile shifts **only when `--key` is given** (MAC arbitration). It is mutually
exclusive with `--offset` and overlaps `--auto` (passing both exits with an error). Without
`--key` it can only rank by median `|z|` and **does not guarantee a correct payload** — read the
weak-bit count.

Tile shifts must be searched because cropping off a non-multiple of 256 pixels moves the tile
origin relative to the image; every local pair index shifts, which shows up as a **rotation** of
the payload (cropping 137 px → 32 bits of rotation). A phase search only fixes block alignment
(mod 8) and cannot fix that shift: with phase-only search the payload is rotated yet
self-consistent — median `|z|` is high and weak bits are 0/256, it looks perfectly fine and is
simply wrong. **The only reliable arbiter is the MAC.**

Horizontal shifts must be taken **modulo per row and column separately** (a shift wraps to column
0 of the same row at the tile's right edge). Adding an offset to the linear index pushes 1/16 of
the observations into the next row; the z values still look great and only the MAC catches it —
see `BlockCodecTests.testAutoSurvivesHorizontalCrop`.

The ranking order follows from this: stage one sorts the 16 best-aligned phases by `|z|`, stage two
enumerates shifts on those and checks the MAC. Ranking by `signal` would be wrong — it is inflated
by content: a watermark-free luma plane scores 19 while a watermarked chroma plane scores 9, so
it would pick the wrong plane.

```
payload=0xefbeaddea048aa6acfe14c8e112103090000103059f32c1304708e9619bdb73c  payloadBits=256  平面=chroma  相位=(0,7)  signal=9.17  |z|中位=35.5  最弱=10.0  弱bit=0/256  OK(全部 256 bit 显著)
uid=3735928559(0xDEADBEEF)  time=2026-09-16 07:43:28 UTC  page=photogrid → BHPhotoGridViewController  layout=v3 app=1 env=0  mac=OK
```

Read the **weak-bit count** (bits with `|z| < 3`), not the single weakest bit — on real screens the
z value of individual bits collapses naturally and a global minimum is too harsh:

```
OK   weak bits = 0                    every bit is significant, conclusion stands
WEAK weak bits <= payloadBits/8       barely decoded, cross-check the conclusion (= 32 at 256 bits)
NO   more weak bits                   there is probably no watermark in the picture
```

When the verdict says `NO` / `WEAK` but `mac=OK`, **the MAC wins**: weak bits only mean little
margin, not a wrong payload. Conversely `mac=BAD` must be treated as failure — do not read the
numbers anyway.

An image without a watermark measures a median `|z|` of 0.5 and 32/32 weak bits, well separated
from watermarked images.

Agent usage: [`skills/blind-watermark/SKILL.md`](skills/blind-watermark/SKILL.md).

### Python decoder (cross-language backup)

`tools/bwdecode.py` is the same logic in Python: same flags, same output format, same reading rules
as the Swift version. It exists so a screenshot can be decoded **on a machine without Swift**, and
so the two implementations can be cross-checked.

```bash
python3 -m pip install numpy pillow
python3 tools/bwdecode.py shot.png --auto --layout --pages Demo/pages.json --key <hex>

# Cross-check the two implementations on the same PNG (payload / weak bits / fields);
# compares against .build/release/bwdecode when that binary exists
python3 tools/test_bwdecode.py
```

Measured (iPhone 16 screenshot, 1179×2556, M1 Pro): 0.21 s for a normal decode, 0.28 s with
`--auto`. The only dependencies are numpy and Pillow (Pillow reads the image, numpy computes the
feature plane and integral image). It is a mirror: **decoding logic changes must land in both**,
and `tools/test_bwdecode.py` cross-checks them on the same PNG.

## Default payload layout

`WatermarkPayload.payloadBits` = 256 bit / 32 bytes, all fields little-endian. The doc comment in
`Sources/BlindWatermarkCore/WatermarkPayload.swift` is authoritative; this is a copy:

```
[255:224] uid        32   UInt32   user ID, stored verbatim
[223:192] timestamp  32   UInt32   Unix seconds, second precision
[191:128] pageCode   64   UInt64   page class name code, 10 × 6-bit characters = 60 bit
[127: 96] tag        32   UInt32   [31:28] layout version [27:20] app [19:12] env [11:0] reserved
[ 95:  0] mac        96            HMAC-SHA256(first 20 bytes, server key) truncated to 96 bit
```

**Why 256 bit**: a 10-character page code alone needs 60 bit, so 128 bit does not fit; going any
larger pushes the repetitions per tile below 2, breaking the "flip every other copy to cancel the
luma gradient" mechanism (upper bound in `BlockCodec.maxPayloadBits`).

Zero-touch mode (no `Watermark.install`, no `payloadProvider`) builds a **256-bit recommended
layout** via `WatermarkDefaultPayload.currentBytes()`: uid = full 32 bits of
`fnv1a(identifierForVendor.uuidString)`, timestamp = current Unix seconds (**no 10-minute
bucketing**), pageCode = 0, tag = `layoutVersion << 28`, mac empty.
An empty `mac` means **no signature verification and forgeable**, and the device hash is
irreversible — good enough to prove the pipeline works.
**In production it must be replaced by a server-issued, signed payload**, otherwise the watermark
cannot identify anyone and can be forged to frame someone.

## Measured results and limits

### Unit tests

`swift test` covers 41 cases (runs on macOS, no simulator needed): pure white / pure black / mid
grey backgrounds, gradients plus photo-level detail, JPEG q=0.8 and q=0.6, partial cropping
(vertical and horizontal), the `delta = 2` floor, no false positives on watermark-free images,
tile geometry contracts, decodability of both chroma and luma, adversarial chroma textures not
silently decoding wrong, `--auto` phase / plane / bit-count detection, the 256-bit layout
round-trip with MAC tamper detection, `findBestOffset` (arbiter-driven) and
PageRegistry / PageNameCodec.

### Per-page simulator measurements

Six very different layouts in `Demo/`, iPhone 16 simulator (iOS 18.6, 1179×2556), payload using
the Demo's default 256-bit layout (uid `0xDEADBEEF` + current time + page code + real MAC),
delta 8.

chroma mode (**the default**):

| Page | Content | signal | median \|z\| | weakest | weak bits | Verdict |
|---|---|---|---|---|---|---|
| plain | near-flat gradient | 9.00 | 161.3 | 10.6 | 0/256 | OK |
| white | white + a bit of bubble text | 9.00 | 161.0 | 9.8 | 0/256 | OK |
| text | text-dense list | 9.00 | 161.3 | 6.7 | 0/256 | OK |
| photo | photo grid (synthetic noise + hard edges) | 9.34 | 28.8 | 8.0 | 0/256 | OK |
| dark | dark background + dark cards | 9.12 | 161.0 | 4.9 | 0/256 | OK |
| mixed | white over black + text + a photo | 9.12 | 160.6 | 4.8 | 0/256 | OK |

On the chroma plane greyscale content is identically zero, so the text page scores as high as the
flat page. The `photo` page is pulled down by large colourful areas, but every bit is still
significant.

luma mode as a control (same screenshots, 256-bit layout):

| delta | Result |
|---|---|
| 6 | 4–182/256 weak bits; the text page decodes wrong outright (mac=BAD). **Unusable at 256 bit** |
| 12 | plain / white / dark decode (`0/256` weak bits), mixed / photo degrade to WEAK but mac=OK, the text page still mac=BAD |

Conclusion: at 256 bits luma's margin is spread too thin, and raising delta makes the luma grid
visible to the eye. **Use chroma with 256 bits**; if you really need luma, shrink the payload and
re-measure with `Demo/sweep.sh` first.

> A large `signal` means large content noise and says nothing about decodability (the luma text
> page scores 20 yet is the worst). What decides is `|z|` and the MAC.

When validating an integration with different layouts, run `Demo/sweep.sh` and re-measure instead
of copying these numbers:

```bash
cd Demo && ./sweep.sh                          # chroma sweep over all pages (default)
cd Demo && ./sweep.sh "<UDID>" 4 luma          # switch plane / find the margin at a given delta
```

### Known limits

- **Chroma adversarial samples**: a scene whose chroma structure happens to sit at the 8 px scale
  degrades. `testChromaNeverSilentlyWrongOnAdversarialColorTexture` holds the line — such cases
  must fail to decode or report low confidence; silently returning a wrong payload is not allowed.
- **Resizing breaks it**: a resized screenshot (chat app forwarding, any resize) changes both the
  block size and the tiling period, so nothing decodes. Only native device-pixel resolution works;
  ask the user for the **original** image.
- **Photographing the screen does not work**: moiré and geometric distortion wreck the block grid;
  that path needs a sync template plus deep learning and is out of scope here.
- **Cropping does work**: `--auto` with `--key` covers vertical and horizontal crops (including
  half-pair offsets). Without `--key` it degrades to guessing by median `|z|` and guarantees
  nothing.

## Simulator smoke test

```bash
cd Demo && xcodegen generate
xcodebuild -project Demo.xcodeproj -scheme Demo \
  -destination 'id=<simulator UDID>' -derivedDataPath /tmp/bwdd build
xcrun simctl install booted /tmp/bwdd/Build/Products/Debug-iphonesimulator/Demo.app
xcrun simctl launch booted com.zylcold.blindwatermark.demo
xcrun simctl io booted screenshot /tmp/shot.png
.build/release/bwdecode /tmp/shot.png
```

Tuning knobs via environment variables (prefix with `SIMCTL_CHILD_` for `xcrun simctl launch`):
`SIMCTL_CHILD_BW_PAYLOAD=0x1234 SIMCTL_CHILD_BW_DELTA=8 SIMCTL_CHILD_BW_PLANE=chroma`.

## CI

`.github/workflows/ci.yml` runs four things on every PR:

1. `swift build` (all targets compile)
2. `swift test` (41 core test cases)
3. `xcodegen generate` + `xcodebuild -destination 'generic/platform=iOS Simulator'` building
   `Demo/`, which covers iOS-side compilation (the UIKit window layer, the ObjC `+load`) that
   `swift test` cannot reach on macOS.
4. `python3 tools/test_bwdecode.py`: Python decoder self-check (synthetic round trip, cropping,
   tamper detection, page codes) cross-checked against the Swift `bwdecode` on the same PNG.

Reproduce locally:

```bash
swift build && swift test
python3 tools/test_bwdecode.py
cd Demo && xcodegen generate && xcodebuild -project Demo.xcodeproj -scheme Demo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bwdd CODE_SIGNING_ALLOWED=NO build
```

## Compliance

The watermark carries device and time information, which is personal data. Privacy policies must
state its purpose and scope, and it must not be used for tracking beyond that purpose. Being
technically possible is not the same as being lawful.

## License

MIT
