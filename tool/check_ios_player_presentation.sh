#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter precache --ios
FLUTTER_ROOT=$(dirname "$(dirname "$(command -v flutter)")")
FRAMEWORKS="$FLUTTER_ROOT/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
test -d "$FRAMEWORKS"
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$CHECK_DIR/PlayerPresentation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('third_party/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/VideoPlayerPlugin.swift').read_text()
marker = '#if os(iOS)\n/// Operates on the existing player;'
assert source.count(marker) == 1
Path(sys.argv[1]).write_text('import AVFoundation\nimport Flutter\n' + source[source.index(marker):])
PY
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios18.0-simulator -F "$FRAMEWORKS" "$CHECK_DIR/PlayerPresentation.swift"
echo "AVFoundation presentation channel typecheck passed"
