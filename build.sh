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
    <string>0.5.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>语音输入需要使用麦克风</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>将你的语音转写为文字后进行优化</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>PolishPad：优化并替换</string>
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
                <string>PolishPad：全选优化并替换</string>
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
mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 优先使用固定的自签名证书（TCC 授权可跨版本存活），否则退回 ad-hoc
SIGN_IDENTITY="PolishPad Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
    echo "已使用证书签名：$SIGN_IDENTITY"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "未找到「$SIGN_IDENTITY」证书，使用 ad-hoc 签名（每次重打包需重新授权辅助功能）"
fi

# 刷新系统服务缓存，让右键菜单的「服务」项尽快出现
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/$APP" 2>/dev/null || true
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "打包完成：$(pwd)/$APP"
echo "运行：open $APP"
