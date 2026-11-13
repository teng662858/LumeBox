#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter precache --ios
FLUTTER_ROOT=$(dirname "$(dirname "$(command -v flutter)")")
FLUTTER_FRAMEWORK="$FLUTTER_ROOT/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
mkdir -p out/native-video "$CHECK/NativeVideoCheck.app/Frameworks" "$CHECK/fixtures"
# Same verified libmpv binary distribution as the app's pinned iOS dependency.
curl --fail -L --retry 2 'https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.6.0/libmpv-xcframeworks_v0.6.0_ios-universal-video-default.tar.gz' -o "$CHECK/mpv.tar.gz"
echo 'a95bc18508af26136b8a408341c05b5585d644ec013f00ac07db09d2e28d36ae  '"$CHECK/mpv.tar.gz" | shasum -a 256 -c -
tar -xzf "$CHECK/mpv.tar.gz" -C "$CHECK"
python3 - "$CHECK" "$ARCH" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
root = Path(sys.argv[1]); destination = root / 'NativeVideoCheck.app/Frameworks'
for package in root.rglob('*.xcframework'):
    data = plistlib.loads((package / 'Info.plist').read_bytes())
    for lib in data['AvailableLibraries']:
        if lib.get('SupportedPlatformVariant') == 'simulator' and lib['SupportedPlatform'] == 'ios' and sys.argv[2] in lib['SupportedArchitectures']:
            framework = package / lib['LibraryIdentifier'] / lib['LibraryPath']
            shutil.copytree(framework, destination / framework.name, dirs_exist_ok=True)
            break
PY
cp -R "$FLUTTER_FRAMEWORK/Flutter.framework" "$CHECK/NativeVideoCheck.app/Frameworks/"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -isysroot "$SDK" \
  -target "${ARCH}-apple-ios18.0-simulator" -c ios/Runner/NativeMPVBridge.m -o "$CHECK/NativeMPVBridge.o"
cat ios/Runner/NativeVideoPlayerController.swift tool/native_video_smoke.swift > "$CHECK/NativeVideoCheck.swift"
xcrun swiftc -D DEBUG -sdk "$SDK" -target "${ARCH}-apple-ios18.0-simulator" \
  -F "$CHECK/NativeVideoCheck.app/Frameworks" -import-objc-header ios/Runner/NativeMPVBridge.h \
  ios/Runner/NativeVideoEngine.swift "$CHECK/NativeVideoCheck.swift" "$CHECK/NativeMPVBridge.o" \
  -framework Flutter -framework Mpv -framework OpenGLES -framework QuartzCore -framework CoreVideo -framework CoreMedia \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$CHECK/NativeVideoCheck.app/NativeVideoCheck"
cat > "$CHECK/NativeVideoCheck.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.lumebox.native-video-check</string><key>CFBundleExecutable</key><string>NativeVideoCheck</string><key>CFBundleName</key><string>NativeVideoCheck</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>MinimumOSVersion</key><string>18.0</string><key>UILaunchScreen</key><dict/><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict><key>UIBackgroundModes</key><array><string>audio</string></array><key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
codesign --force --sign - --deep "$CHECK/NativeVideoCheck.app"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine=frequency=440 -t 12 -vf 'drawbox=x=0:y=0:w=iw:h=48:color=red:t=fill,drawbox=x=0:y=ih-48:w=iw:h=48:color=blue:t=fill' -c:v libx264 -pix_fmt yuv420p -g 24 -c:a aac -movflags +faststart "$CHECK/fixtures/smoke.mp4"
ffmpeg -hide_banner -loglevel error -i "$CHECK/fixtures/smoke.mp4" -c copy -hls_time 1 -hls_list_size 0 "$CHECK/fixtures/smoke.m3u8"
python3 tool/native_video_fixture_server.py "$CHECK/fixtures" > out/native-video/http.log 2>&1 &
HTTP_PID=$!
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for v in d["devices"].values() for x in v if "iPhone" in x["name"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$CHECK/NativeVideoCheck.app"
python3 - "$DEVICE" <<'PY' 2>&1 | tee out/native-video/test.log
import subprocess,sys
subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',sys.argv[1],'com.lumebox.native-video-check'], timeout=240, check=True)
PY
kill "$HTTP_PID" || true
grep -q NATIVE_VIDEO_ALL_OK out/native-video/test.log
echo 'Production UIKit video session and AVPlayer/libmpv checks passed (no IPA)'
