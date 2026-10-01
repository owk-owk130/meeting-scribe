#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP="MeetingScribe.app"
BIN="MeetingScribe"

echo "==> .app バンドルを生成"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> swiftc でビルド"
swiftc -O app/MeetingScribe/*.swift app/Shared/*.swift -o "$APP/Contents/MacOS/$BIN"
swiftc -O app/MeetingScribeRecorder/*.swift app/Shared/*.swift -o "$APP/Contents/MacOS/MeetingScribeRecorder"

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
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>録音中の会議の予定名と参加者をノートに記録するために使用します</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 署名"
codesign --force --deep -s - "$APP"

echo ""
echo "完了: $SCRIPT_DIR/$APP"
echo "起動するには: open $SCRIPT_DIR/$APP"
