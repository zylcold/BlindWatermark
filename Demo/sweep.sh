#!/usr/bin/env bash
# 逐页截屏解码，对比水印在不同版式上的解码余量。
# 用法: ./sweep.sh [模拟器UDID] [delta]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print([x["udid"] for v in d.values() for x in v][0])')}"
DELTA="${2:-}"
BUNDLE=com.zylcold.blindwatermark.demo

swift build -c release --package-path "$ROOT" >/dev/null
( cd "$HERE" && xcodegen generate >/dev/null )
xcodebuild -project "$HERE/Demo.xcodeproj" -scheme Demo -configuration Debug \
  -destination "id=$UDID" -derivedDataPath /tmp/bwdd build >/dev/null
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" /tmp/bwdd/Build/Products/Debug-iphonesimulator/Demo.app

echo "delta=${DELTA:-默认}  模拟器=$UDID"
for PAGE in plain white text photo dark mixed; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  if [ -n "$DELTA" ]; then
    SIMCTL_CHILD_BW_PAGE=$PAGE SIMCTL_CHILD_BW_DELTA=$DELTA \
      xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  else
    SIMCTL_CHILD_BW_PAGE=$PAGE xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  fi
  sleep 4
  xcrun simctl io "$UDID" screenshot "/tmp/bw_$PAGE.png" >/dev/null 2>&1
  printf "%-6s " "$PAGE"
  "$ROOT/.build/release/bwdecode" "/tmp/bw_$PAGE.png" | tail -1
done
