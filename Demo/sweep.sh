#!/usr/bin/env bash
# 逐页截屏解码，对比水印在不同版式上的解码余量。
# 用法: ./sweep.sh [模拟器UDID] [delta] [luma|chroma] [v4|v52]
#   v52：用 BW_PROTOCOL=v52 启动 Demo（v5.2 紧凑协议），再用 --protocol v5.2 --auto 解码。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print([x["udid"] for v in d.values() for x in v][0])')}"
DELTA="${2:-}"
PLANE="${3:-chroma}"
PROTOCOL="${4:-v4}"
BUNDLE=com.zylcold.blindwatermark.demo

swift build -c release --package-path "$ROOT" >/dev/null
( cd "$HERE" && xcodegen generate >/dev/null )
xcodebuild -project "$HERE/Demo.xcodeproj" -scheme Demo -configuration Debug \
  -destination "id=$UDID" -derivedDataPath /tmp/bwdd build >/dev/null
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" /tmp/bwdd/Build/Products/Debug-iphonesimulator/Demo.app

echo "protocol=$PROTOCOL  plane=$PLANE  delta=${DELTA:-默认}  模拟器=$UDID"
for PAGE in plain white text photo dark mixed; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  ENV=(SIMCTL_CHILD_BW_PAGE=$PAGE SIMCTL_CHILD_BW_PLANE=$PLANE)
  [ -n "$DELTA" ] && ENV+=(SIMCTL_CHILD_BW_DELTA=$DELTA)
  [ "$PROTOCOL" = v52 ] && ENV+=(SIMCTL_CHILD_BW_PROTOCOL=v52)
  env "${ENV[@]}" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep 4
  if [ "$PROTOCOL" = v52 ]; then
    SHOT="/tmp/bw_v52_${PLANE}_$PAGE.png"
  else
    SHOT="/tmp/bw_${PLANE}_$PAGE.png"
  fi
  xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1
  printf "%-6s " "$PAGE"
  if [ "$PROTOCOL" = v52 ]; then
    "$ROOT/.build/release/bwdecode" "$SHOT" --protocol v5.2 --auto --layout | tail -2
  else
    "$ROOT/.build/release/bwdecode" "$SHOT" --plane "$PLANE" --layout --pages "$HERE/pages.json" --key 00112233445566778899aabbccddeeff | tail -2
  fi
done
