#!/bin/zsh
# 编译并打包成 PolishPad.app（输出在本目录下）
set -e
cd "$(dirname "$0")"

swift build -c release

APP=PolishPad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.polishpad</string>
    <key>CFBundleName</key>
    <string>PolishPad</string>
    <key>CFBundleExecutable</key>
    <string>PolishPad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>语音输入需要使用麦克风</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>将你的语音转写为文字后进行润色</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>PolishPad：润色并替换</string>
            </dict>
            <key>NSMessage</key>
            <string>polishSelection</string>
            <key>NSPortName</key>
            <string>PolishPad</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
            </array>
            <key>NSReturnTypes</key>
            <array>
                <string>NSStringPboardType</string>
            </array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>PolishPad：全选润色并替换</string>
            </dict>
            <key>NSMessage</key>
            <string>polishAll</string>
            <key>NSPortName</key>
            <string>PolishPad</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

cp .build/release/PolishPad "$APP/Contents/MacOS/PolishPad"
codesign --force --sign - "$APP" 2>/dev/null || true

# 刷新系统服务缓存，让右键菜单的「服务」项尽快出现
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/$APP" 2>/dev/null || true
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "打包完成：$(pwd)/$APP"
echo "运行：open $APP"
