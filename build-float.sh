#!/bin/zsh
set -e

cd "$(dirname "$0")"

APP="dist/MibandFloat.app"
SOURCE="native/main.swift"
PLIST="native/Info.plist"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "未找到 Swift 工具链。请先安装 Xcode Command Line Tools：xcode-select --install"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"

swiftc -O -whole-module-optimization \
  -target arm64-apple-macos12.0 \
  -framework AppKit \
  "$SOURCE" \
  -o "$APP/Contents/MacOS/MibandFloat"

chmod +x "$APP/Contents/MacOS/MibandFloat"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true

echo "已生成 $APP"
