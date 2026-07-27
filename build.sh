#!/bin/bash
# build.sh — MeetingScribe.swift をビルドして .app バンドルを生成する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP="MeetingScribe.app"
BIN="MeetingScribe"

echo "==> swiftc でビルド"
swiftc -O MeetingScribe.swift -o "$BIN"
swiftc -O AudioTapRecorder.swift -o MeetingScribeRecorder
codesign --force -s - MeetingScribeRecorder

echo "==> .app バンドルを生成"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.meetingscribe</string>
	<key>CFBundleName</key>
	<string>MeetingScribe</string>
	<key>CFBundleExecutable</key>
	<string>MeetingScribe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>会議の録音に使用します</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>会議相手の声（システム音声）の録音に使用します</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 署名"
codesign --force --deep -s - "$APP"

echo ""
echo "完了: $SCRIPT_DIR/$APP"
echo "起動するには: open $SCRIPT_DIR/$APP"
