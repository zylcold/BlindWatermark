# BlindWatermark

English · [中文](README.md)

A screen-level blind watermark for iOS: an invisible chroma perturbation covers the whole app
window, so **every screenshot carries it**. From a screenshot you can later recover **device,
time and page**, which is what you need to identify who reported a problem.

No screenshot API is hooked. Screenshots are composited by the render server, so the pixels of
the watermark window end up in the output by construction.

- Payload: 512 bit / 64 bytes (layout v4) — uid + Unix seconds + build number + 15-character
  page code + 22-byte note + 96-bit check value
- Version: `1.0.0` ([Releases](https://github.com/zylcold/BlindWatermark/releases); SwiftPM uses
  `from: "1.0.0"`, CocoaPods uses `:tag => '1.0.0'`)
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
  (512-bit layout, 23287 pairs in total).

The decode margin was also measured, not guessed (iPhone 16, 3x, luma mode, 32-bit layout):

| Scheme | Median \|z\| | Weak bits | Verdict |
|---|---|---|---|
| 16px blocks, delta 3 | 1.9 | 27/32 | decoding is luck |
| 8px blocks, delta 3 | 3.3 | 12/32 | still unstable |
| **8px blocks, delta 6 (luma default)** | **6.4** | **0/32** | **reliable** |
| no watermark (control) | 0.5 | 32/32 | no false positives |

Those numbers are for the old 32-bit prototype. The current layout is 512 bit, which **halves the
observations per bit**, so luma is no longer usable at all (see
[Measured results and limits](#measured-results-and-limits)) — the defaults are chroma + delta 8.

## Integration

### Swift Package Manager

```swift
.package(url: "git@github.com:zylcold/BlindWatermark.git", from: "1.0.0")
```

```swift
import BlindWatermark

// The server computes the check value and ships all 64 bytes; the client only renders them
Watermark.install(payload: serverIssuedBytes)

// Deployments without a key (the client builds the payload itself): fill the public self-check
// value so the decoder can validate without any secret. build/note come from the caller
// (CI build number / ticket id) and are optional
Watermark.install(payload: WatermarkPayload.selfChecked(uid: uid, timestamp: ts,
    build: 202609161722, pageClassName: type(of: self).description(),
    note: "hotfix-3", app: 1).bytes)

// Update the page name code on navigation (v4 sets every field at once)
Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts, build: build,
    pageClassName: type(of: self).description(), note: note, key: key).bytes)

// The 32-bit convenience entry point still exists
Watermark.install(payload: 0xDEAD_BEEF)
```

The check value lives in the 96-bit `mac` field and has three flavours:

| Constructed with | Field content | Decoder side |
|---|---|---|
| `WatermarkPayload(… key:)` | HMAC-SHA256(first 20 bytes, server key) | with a key → `mac=OK(验签)`; without → `mac=未校验(需要 --key)` |
| `WatermarkPayload.selfChecked(…)` | SHA-256(first 20 bytes), truncated | anyone → `mac=OK(自检,未验签)` |
| `mac: []` / all zeros | no check value | `mac=未签名`; cropping search falls back to the structural check |

The self-check catches "alignment was off by a few bits" aliases (measured: zero false positives
over the whole search space) but **cannot stop forgery** (anyone can compute it). Preventing
someone from planting a payload that frames another user requires server-side HMAC.

With nothing configured, a default payload is used (`identifierForVendor` hash + Unix seconds),
so it runs out of the box.

### CocoaPods

Under CocoaPods the three targets ship as three pods (module names match SwiftPM), and **all three
must be declared**: `BlindWatermark` depends on the other two via `s.dependency`, so declaring only
it breaks at `import BlindWatermarkCore`.

```ruby
pod 'BlindWatermarkCore',     :path => '/path/to/BlindWatermark'
pod 'BlindWatermarkAutoLoad', :path => '/path/to/BlindWatermark'
pod 'BlindWatermark',         :path => '/path/to/BlindWatermark'

# Switching to a git source: the repo has tags since 1.0.0
# pod 'BlindWatermarkCore', :git => 'git@github.com:zylcold/BlindWatermark.git', :tag => '1.0.0'
```

Note the podspecs declare `ios.deployment_target = '13.0'` (the repo's platform floor). Xcode 27
only supports 15.0 and above, so building a pod project with it needs the pod targets bumped to
15.0, or an older Xcode.

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
| `payloadBits` | `payload.count × 8` | Number of significant bits, max 512 (a v4 payload is always 512); the decoder must agree |
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
self-consistent — median `|z|` is high and weak bits are 0/512, it looks perfectly fine and is
simply wrong. **The only reliable arbiter is the check value.**

### Validator ladder

Crop recovery is decided by a **check value** (a wrong shift produces a perfectly self-consistent
payload, so brute force without an arbiter is guessing). The CLI runs three passes:

1. strict validator (HMAC or public self-check) + regular phases
2. strict validator + **block parity** (`ox` in 0..<16) — rescues horizontal crops by an **odd
   number of blocks**
3. structural check as a last resort (only option when the payload carries no check value); it
   prints a warning and does not guarantee a correct payload

Pass 2 fixes a real gap: a pair is two adjacent blocks, so when the block grid is offset by one
block the decoder pairs blocks that straddle two pattern pairs; the reading becomes the sum of two
neighbouring bits (observations survive only where both bits agree) and some bits end up with no
evidence at all. Measured on a text-heavy page cropped by 40 px: the plain phase search cannot find
truth, while with block parity it shows up at `ox=8, rotation=3` and median `|z|` goes from 58.9
back to 67.3 (the same as an even-block crop).

Measured on real pixels (4 pages × 5 crops = 20 cases, no key given):

| Payload | `--auto` without a key |
|---|---|
| carries the public self-check value | **20/20 correct** |
| `mac` all zeros (no check value, structural fallback) | 19/20 (a near-copy slips through) |
| HMAC-signed but no key available | cannot decode (no arbiter) — get the key or have the sender also embed a self-check value |

Horizontal shifts must be taken **modulo per row and column separately** (a shift wraps to column
0 of the same row at the tile's right edge). Adding an offset to the linear index pushes 1/16 of
the observations into the next row; the z values still look great and only the check value catches
it — see `BlockCodecTests.testAutoSurvivesHorizontalCrop`.

The ranking order follows from this: stage one sorts the 16 best-aligned phases by `|z|`, stage two
enumerates shifts on those and checks the check value. Ranking by `signal` would be wrong — it is inflated
by content: a watermark-free luma plane scores 19 while a watermarked chroma plane scores 9, so
it would pick the wrong plane.

```
payload=0xefbeaddefab3ab6afa75722c2f00000013714d0b224d2449922449922449920100686f746669782d33000000000000000000000084c6b56fc6e6ac14ed4f3912  payloadBits=512  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=120.6  最弱=2.9  弱bit=1/512  WEAK(1/512 bit 证据不足，结论谨慎)
uid=3735928559(0xDEADBEEF)  time=2026-09-17 09:33:19 UTC  page=textlist → BHTextListViewController  build=202609161722  note=hotfix-3  layout=v4 app=1 env=0  mac=OK(自检,未验签)
build 时间: 2026-09-16 17:22（构建方当地墙上时间）
```

Read the **weak-bit count** (bits with `|z| < 3`), not the single weakest bit — on real screens the
z value of individual bits collapses naturally and a global minimum is too harsh:

```
OK   weak bits = 0                    every bit is significant, conclusion stands
WEAK weak bits <= payloadBits/8       barely decoded, cross-check the conclusion (= 64 at 512 bits)
NO   more weak bits                   there is probably no watermark in the picture
```

When the verdict says `NO` / `WEAK` but `mac=OK`, **the MAC wins**: weak bits only mean little
margin, not a wrong payload. Conversely `mac=BAD` must be treated as failure — do not read the
numbers anyway.

An image without a watermark measures a median `|z|` of 0.5 and 32/32 weak bits, well separated
from watermarked images.

Agent usage: decoding in [`skills/blind-watermark/SKILL.md`](skills/blind-watermark/SKILL.md),
integration in [`skills/blind-watermark-integration/SKILL.md`](skills/blind-watermark-integration/SKILL.md).

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

## Payload layout (v4)

`WatermarkPayload.byteCount` = 64 bytes / `payloadBits` = 512, all fields little-endian. The doc
comment in `Sources/BlindWatermarkCore/WatermarkPayload.swift` is authoritative; this is a copy:

```
[511:480] uid        32   UInt32   user ID, stored verbatim
[479:448] timestamp  32   UInt32   Unix seconds (screenshot time)
[447:384] build      64   UInt64   build number, 12-digit YYYYMMDDHHMM (e.g. 202609161722); 0 = unset
[383:288] pageCode   96            page class name code, 15 × 6-bit characters = 90 bit (low 6 bits must be 0)
[287:272] tag        16   UInt16   app(8) + environment(8)
[271: 96] note      176            custom note, 22 bytes UTF-8, zero padded
[ 95:  0] check      96            HMAC-SHA256(first 52 bytes, server key) truncated, or SHA-256 (self-check)
```

**There is no version field**: this is the layout, and changing field boundaries means changing the
protocol. **v3 (256 bit / 32 bytes) is deprecated** — historical v3 screenshots do not decode with
this version (see "Known limits").

**Why 512 bit, and what it costs**: observations per bit = image area / pair area / payloadBits, so
**doubling the payload halves the margin**. An iPhone 16 screenshot has 23287 pairs → ~45
observations per bit at 512 bit. Raise `delta` to buy margin back (8 → 10 → 12, measured below);
shrinking blocks to 4 px would restore 183 observations per bit but fails JPEG q80 in practice, so
blocks stay at 8 px.

**At 512 bit each tile holds only one copy**, which disables the "flip every other copy to cancel
content gradients" mechanism. Measured on strong chroma gradients it does not degrade (0/512 weak
bits), and enlarging the tile to 512 px buys little (weak bits 40 → 32), so the geometry stays at
tile 256.

**15-character page code**: `BHUserProfileEditViewController → userprofileedit` fits exactly (the
10-character v3 code truncated it to `userprofil`). The 90 bits used leave 6 bits in the 96-bit field
that must be zero — the structural check verifies them, buying 6 bits of discrimination for free.
Collisions only ever yield 2–3 candidates, resolvable with
`grep -rin "class.*userprofileedit" --include='*.swift'`.

**build and note are supplied by the caller**: build comes from the CI build number (12 digits,
stored and printed verbatim; the decoder also prints a human-readable time), note carries a ticket
id or environment description (≤ 22 bytes UTF-8).

Zero-touch mode (no `Watermark.install`, no `payloadProvider`) builds a v4 payload via
`WatermarkDefaultPayload.currentBytes()`: uid = full 32 bits of `fnv1a(identifierForVendor.uuidString)`,
timestamp = current Unix seconds, build/pageCode/note empty, and the check field holds the **public
self-check value**. The device hash is irreversible; **in production this must be replaced by a
server-issued, signed payload**.

## Measured results and limits

### Unit tests

`swift test` covers 48 cases (runs on macOS, no simulator needed): pure white / pure black / mid
grey backgrounds, gradients plus photo-level detail, JPEG q=0.8 and q=0.6, partial cropping
(vertical, horizontal, odd-block offsets), the `delta = 2` floor, no false positives on
watermark-free images, tile geometry contracts, decodability of both chroma and luma, adversarial
chroma textures not silently decoding wrong, `--auto` phase / plane / bit-count detection, the
256-bit layout round-trip with all three check tiers (HMAC / public self-check / unsigned),
near-copy aliases being rejected by the self-check but not by the structural check, block parity
restoring `|z|` for odd-block crops, `findBestOffset` (arbiter-driven) and
PageRegistry / PageNameCodec.

`python3 tools/test_bwdecode.py` adds 74 checks and cross-checks against the Swift binary on the
same PNG.

### Per-page simulator measurements

Six very different layouts in `Demo/`, iPhone 16 simulator (iOS 18.6, 1179×2556), layout v4 payload
(uid `0xDEADBEEF` + time + build `202609161722` + 15-character code + note), chroma at delta 8
(default), no key (the check field holds the public self-check value):

| Page | Content | signal | median \|z\| | weakest | weak bits | Verdict | Check |
|---|---|---|---|---|---|---|---|
| plain | near-flat gradient | 9.00 | 120.3 | 4.1 | 0/512 | OK | self-check |
| white | white + a bit of bubble text | 9.00 | 113.8 | 4.7 | 0/512 | OK | self-check |
| text | text-dense list | 9.00 | 120.6 | 2.9 | 1/512 | WEAK | self-check |
| photo | photo grid (synthetic noise + hard edges) | 9.10 | 35.0 | 6.6 | 0/512 | OK | self-check |
| dark | dark background + dark cards | 9.12 | 113.8 | 1.9 | 4/512 | WEAK | self-check |
| mixed | white over black + text + a photo | 9.21 | 54.9 | 2.1 | 4/512 | WEAK | self-check |

Compared with the 256-bit layout on the same pages: median `|z|` 161.0 → 120.3, weakest 6.7 → 2.9 —
**the margin is roughly halved** (twice the payload = half the observations per bit). The WEAK
verdicts above merely mean "not zero weak bits"; they are far from the 512/8 = 64 threshold, and
`mac=OK(自检,未验签)` already proves the payload is correct. **At 512 bit, judge by the check value;
weak bits only tell you about margin.**

Harshest realistic content (springboard photo wallpaper + icons, composited offline on real pixels):

| delta | observations/bit | decoded | median \|z\| | weak bits |
|---|---|---|---|---|
| 8 (default) | 45.5 | OK | 9.4 | 32/512 |
| 10 | 45.5 | OK | 14.9 | 22/512 |
| 12 | 45.5 | OK | 19.3 | 9/512 |

**luma is unusable at 512 bit** (at delta 12: plain 10/512 WEAK, text 139/512 NO, photo 103/512 NO;
lower delta is worse). luma needs a smaller payload, and re-measurement with `Demo/sweep.sh` first.

> A large `signal` means large content noise and says nothing about decodability (the luma text
> page scores 20 yet is the worst). What decides is `|z|` and the check value.

Verdicts versus the check value: when the verdict says `NO` / `WEAK` but `mac=OK(…)`, **the check
value wins** — weak bits only mean little margin, not a wrong payload. Conversely a payload that
carries a check value and fails it (`mac=BAD`) must be treated as a failure; do not read the
numbers anyway.

The `mac` field is reported in tiers (end of the second `--layout` line):

| Output | Meaning |
|---|---|
| `mac=OK(验签)` | HMAC verified — account/time trustworthy and unforged |
| `mac=OK(自检,未验签)` | public self-check passed — proves "decoded correctly", **not** "not forged" |
| `mac=未签名(字段自洽,退结构自检)` | payload carries no check value; crop conclusions unreliable |
| `mac=未校验(需要 --key)` | HMAC-signed payload but no key given |
| `mac=BAD(密钥不符或载荷被改)` | key given and neither check matches |

When validating an integration with different layouts, run `Demo/sweep.sh` and re-measure instead
of copying these numbers:

```bash
cd Demo && ./sweep.sh                          # chroma sweep over all pages (default)
cd Demo && ./sweep.sh "<UDID>" 4 luma          # switch plane / find the margin at a given delta
```

### Known limits

- **layout v3 (256 bit / 32 bytes) is deprecated**: field boundaries changed, so historical v3
  screenshots no longer decode — an explicit breaking change. To read older images, use the decoder
  from the 1.0.0 tag.

- **Chroma adversarial samples**: a scene whose chroma structure happens to sit at the 8 px scale
  degrades. `testChromaNeverSilentlyWrongOnAdversarialColorTexture` holds the line — such cases
  must fail to decode or report low confidence; silently returning a wrong payload is not allowed.
- **Resizing breaks it**: a resized screenshot (chat app forwarding, any resize) changes both the
  block size and the tiling period, so nothing decodes. Only native device-pixel resolution works;
  ask the user for the **original** image.
- **Photographing the screen does not work**: moiré and geometric distortion wreck the block grid;
  that path needs a sync template plus deep learning and is out of scope here.
- **Cropping does work**: `--auto` covers vertical and horizontal crops (including half-pair and
  odd-block offsets). The arbiter is the check value: pass `--key` for a server HMAC, or rely on
  the payload's public self-check value. With neither (`mac` all zeros) it falls back to the
  structural check — measured 19/20 on the 20-case real-pixel sweep, and the one miss looks like a
  plausible answer.

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
2. `swift test` (48 core test cases)
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
