#!/bin/bash
set -euo pipefail
set -euo pipefail
flutter precache --ios
FLUTTER_ROOT=$(dirname "$(dirname "$(command -v flutter)")")
FLUTTER_SLICE="$FLUTTER_ROOT/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
PYTHON_SLICE="$PWD/ios/PythonRuntime/Python.xcframework/ios-arm64_x86_64-simulator"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun clang -fsyntax-only -fobjc-arc -fmodules -target "$ARCH-apple-ios18.0-simulator" \
  -isysroot "$SDK" -F "$FLUTTER_SLICE" -F "$PYTHON_SLICE" \
  -I "$PYTHON_SLICE/Python.framework/Headers" ios/Runner/LumePythonController.m
set -euo pipefail
APP="$RUNNER_TEMP/LumePythonSmoke.app"
mkdir -p "$APP"
PYTHON_SLICE="$PWD/ios/PythonRuntime/Python.xcframework/ios-arm64_x86_64-simulator"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun clang -fobjc-arc -fmodules -target "$ARCH-apple-ios18.0-simulator" \
  -isysroot "$SDK" -F "$PYTHON_SLICE" -I "$PYTHON_SLICE/Python.framework/Headers" \
  -framework UIKit -framework Foundation -framework Python \
  -Wl,-rpath,@executable_path/Frameworks tool/ios_python_smoke.m -o "$APP/Smoke"
python3 - "$APP" <<'PY'
import plistlib,sys,pathlib
with (pathlib.Path(sys.argv[1])/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'Smoke','CFBundleIdentifier':'com.lumebox.python-smoke','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'18.0','UIDeviceFamily':[1]},f)
PY
TARGET_BUILD_DIR="$RUNNER_TEMP" WRAPPER_NAME=LumePythonSmoke.app \
  PLATFORM_NAME=iphonesimulator CURRENT_ARCH="$ARCH" CODE_SIGNING_ALLOWED=YES \
  EXPANDED_CODE_SIGN_IDENTITY=- python3 tool/prepare_python_runtime.py --embed
cp tool/test_python_sources.py "$APP/python/test_python_sources.py"
cp tool/ecc_rfc6979_vectors.json "$APP/python/ecc_rfc6979_vectors.json"
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["udid"] for v in d["devices"].values() for x in v if "iPhone" in x["name"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" com.lumebox.python-smoke data)
python3 - "$DEVICE" "$DATA" <<'PY'
import json,pathlib,subprocess,sys
status = pathlib.Path(sys.argv[2])/'Documents/python-smoke-status.json'
status.unlink(missing_ok=True)
result=subprocess.run(['xcrun','simctl','launch','--console',sys.argv[1],'com.lumebox.python-smoke'],capture_output=True,text=True,timeout=90)
output=result.stdout+result.stderr
print(output[-12000:])
detail = json.loads(status.read_text()) if status.exists() else {'phase':'missing','detail':'No native test result file'}
print(json.dumps(detail,ensure_ascii=False),flush=True)
assert detail.get('phase') == 'passed', 'Packaged iOS CPython smoke test failed: '+detail.get('detail','')
PY
