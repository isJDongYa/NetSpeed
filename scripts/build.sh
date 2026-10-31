#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
target_arch="${1:-$(uname -m)}"
case "$target_arch" in
    arm64|x86_64) ;;
    *)
        printf 'Usage: zsh scripts/build.sh [arm64|x86_64]\n' >&2
        exit 2
        ;;
esac
app_dir="$project_dir/delivery/NetSpeed.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/build"

xcrun swift "$project_dir/scripts/make-icon.swift" "$project_dir/build"
iconutil -c icns "$project_dir/build/NetSpeed.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -whole-module-optimization -target "$target_arch-apple-macos13.0" \
    "$project_dir/Sources/NetworkMonitor.swift" "$project_dir/Sources/App.swift" "$project_dir/Sources/main.swift" \
    -framework AppKit -framework SystemConfiguration -framework ServiceManagement \
    -o "$app_dir/Contents/MacOS/NetSpeed"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>NetSpeed</string>
    <key>CFBundleIdentifier</key><string>local.jiandong.NetSpeed</string>
    <key>CFBundleName</key><string>NetSpeed</string>
    <key>CFBundleDisplayName</key><string>NetSpeed</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.jiandong.NetSpeed "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
