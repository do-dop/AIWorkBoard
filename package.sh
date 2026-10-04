#!/bin/zsh
# 배포용 zip 생성: dist/AIWorkBoard-<version>.zip
set -euo pipefail
ROOT="${0:A:h}"
zsh "$ROOT/build.sh" >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Info.plist" 2>/dev/null || echo 1.0)
OUT="$ROOT/dist/AIWorkBoard-$VERSION.zip"
rm -f "$OUT"
(cd "$ROOT/dist" && ditto -c -k --keepParent "AI Work Board.app" "$OUT")
echo "$OUT"
