#!/bin/bash
set -euo pipefail
FLUTTER_ROOT=$(dirname "$(dirname "$(command -v flutter)")")
FLUTTER_SLICE="$FLUTTER_ROOT/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
export SDKROOT="$SDK"
ARCH=$(uname -m)
APP="$RUNNER_TEMP/LumeSystemTabBarSmoke.app"
mkdir -p "$APP/Frameworks"
xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-ios18.0-simulator" \
  -F "$FLUTTER_SLICE" -framework UIKit -framework Flutter \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  ios/Runner/LumeSystemTabBar.swift tool/ios_system_tab_bar_smoke.swift -o "$APP/Smoke"
cp -R "$FLUTTER_SLICE/Flutter.framework" "$APP/Frameworks/"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
with (pathlib.Path(sys.argv[1])/'Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable':'Smoke','CFBundleIdentifier':'com.lumebox.system-tab-bar-smoke',
                  'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
                  'MinimumOSVersion':'18.0','UIDeviceFamily':[1], 'UILaunchScreen':{}},output)
PY
codesign --force --sign - "$APP/Frameworks/Flutter.framework"
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS-26" in k for x in v if "iPhone" in x["name"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" com.lumebox.system-tab-bar-smoke data)
mkdir -p out/system-tab-bar
python3 tool/run_ios_tab_bar_smoke.py "$DEVICE" "$DATA" out/system-tab-bar
