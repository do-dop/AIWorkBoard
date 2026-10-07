#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/AI Work Board.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.build/module-cache"

ICON_SOURCE="$ROOT/assets/app-icon-bot.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ICON_SOURCE" "$ROOT/.build/app-icon-cropped.png"
for size in 16 32 128 256 512; do
  doubled=$((size * 2))
  sips -z "$size" "$size" "$ROOT/.build/app-icon-cropped.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$doubled" "$doubled" "$ROOT/.build/app-icon-cropped.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  # 일부 macOS 버전에서 정상 PNG iconset도 iconutil이 거부한다.
  python3 - "$ICONSET" "$APP/Contents/Resources/AppIcon.icns" <<'PY'
from pathlib import Path
import struct
import sys

source, output = map(Path, sys.argv[1:])
chunks = []
for kind, name in (
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
):
    data = (source / name).read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
fi
cp "$ROOT/assets/crt-bot.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "$ROOT/assets/crt-bot@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
cp "$ROOT/assets/pixel-chara-clean.png" "$APP/Contents/Resources/PixelChara.png"
cp "$ROOT/assets/pixel-spider.png" "$APP/Contents/Resources/PixelSpider.png"
mkdir -p "$APP/Contents/Resources/Chiikawa"
cp "$ROOT"/assets/chiikawa/*.png "$APP/Contents/Resources/Chiikawa/"
mkdir -p "$APP/Contents/Resources/Eva"
cp "$ROOT"/assets/eva/*.png "$APP/Contents/Resources/Eva/"
mkdir -p "$APP/Contents/Resources/Tamagotchi"
cp "$ROOT"/assets/tamagotchi/*.png "$APP/Contents/Resources/Tamagotchi/"

sips -c 500 500 "$ROOT/assets/openai-mark.png" --out "$ROOT/.build/openai-cropped.png" >/dev/null
sips -z 96 96 "$ROOT/.build/openai-cropped.png" --out "$APP/Contents/Resources/OpenAIMark.png" >/dev/null

# Apple Silicon + Intel 모두 지원하는 universal 바이너리
for arch in arm64 x86_64; do
  swiftc \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$arch-apple-macosx13.0" \
    -module-cache-path "$ROOT/.build/module-cache" \
    -O \
    "$ROOT/AIWorkBoard.swift" \
    -o "$ROOT/.build/AIWorkBoard-$arch"
done
lipo -create "$ROOT/.build/AIWorkBoard-arm64" "$ROOT/.build/AIWorkBoard-x86_64" -output "$APP/Contents/MacOS/AIWorkBoard"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
echo "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
