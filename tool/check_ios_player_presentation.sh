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

# Compile the actual inline layer registry and check its Swift/PiP integration.
# The full simulator App has optional NodeMobile dependencies; these checks do
# not require those unrelated runtimes or create an installable App package.
NATIVE_ROOT="$PWD/third_party/video_player_avfoundation/darwin/video_player_avfoundation/Sources"
HEADER="$NATIVE_ROOT/video_player_avfoundation_objc/include/video_player_avfoundation_objc/FVPNativeVideoView.h"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
# Compile the actual player wiring for the minimum supported iOS target, then
# run the platform-independent AVFoundation policy checks on the macOS host.
for source in FVPVideoPlayer FVPLumeBuffering; do
  xcrun clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -target arm64-apple-ios18.0-simulator -F "$FRAMEWORKS" \
    -c "$NATIVE_ROOT/video_player_avfoundation_objc/$source.m" \
    -o "$CHECK_DIR/$source.o"
done
xcrun clang -fobjc-arc -fmodules -framework Foundation -framework AVFoundation \
  -framework CoreMedia -I "$NATIVE_ROOT/video_player_avfoundation_objc" \
  tool/avplayer_buffer_resume_smoke.m \
  "$NATIVE_ROOT/video_player_avfoundation_objc/FVPLumeBuffering.m" \
  -o "$CHECK_DIR/avplayer-buffer-resume"
"$CHECK_DIR/avplayer-buffer-resume"
xcrun clang -fobjc-arc -fmodules -isysroot "$SDK" \
  -target arm64-apple-ios18.0-simulator -F "$FRAMEWORKS" \
  -c "$NATIVE_ROOT/video_player_avfoundation_ios/FVPNativeVideoView.m" \
  -o "$CHECK_DIR/InlineVideoView.o"
xcrun clang -fobjc-arc -fmodules -isysroot "$SDK" \
  -target arm64-apple-ios18.0-simulator -F "$FRAMEWORKS" \
  -c "$NATIVE_ROOT/video_player_avfoundation_objc/FVPTextureBasedVideoPlayer.m" \
  -o "$CHECK_DIR/TexturePlayer.o"
cat > "$CHECK_DIR/PlayerViews.h" <<HEADERS
#import "$HEADER"
#import "$(dirname "$HEADER")/FVPTextureBasedVideoPlayer.h"
HEADERS
cat > "$CHECK_DIR/InlineLayer.swift" <<'SWIFT'
import AVFoundation
import Flutter
func readTextureState(_ texture: FVPTextureBasedVideoPlayer) -> [String: Bool] {
  ["attached": texture.textureSampled, "readyForDisplay": texture.textureFrameReady]
}
func prepareInlinePip(_ player: AVPlayer) {
  let layer = FVPNativeVideoView.layer(for: player)
  NotificationCenter.default.post(name: Notification.Name("LumeBox.avplayer.pip"),
                                  object: player,
                                  userInfo: layer.map { ["playerLayer": $0] })
}
SWIFT
xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
  -F "$FRAMEWORKS" -import-objc-header "$CHECK_DIR/PlayerViews.h" \
  "$CHECK_DIR/InlineLayer.swift" ios/Runner/PipController.swift ios/Runner/PipFramePump.swift
echo "AVPlayer inline layer Objective-C and PiP Swift checks passed (iOS 18)"
