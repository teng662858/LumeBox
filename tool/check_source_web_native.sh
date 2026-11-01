#!/usr/bin/env bash
# Compile source-web modules and typecheck XCTest code, without building an App/IPA.
set -euo pipefail
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLUTTER_RUNTIME=$(dirname "$(dirname "$(command -v flutter)")")
FRAMEWORKS="$FLUTTER_RUNTIME/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
if [ ! -d "$FRAMEWORKS" ]; then
  FRAMEWORKS=$(find "$FLUTTER_RUNTIME/bin/cache/artifacts/engine" -type d -path '*/Flutter.xcframework/ios-arm64_x86_64-simulator' | head -1)
fi
test -n "$FRAMEWORKS"
git clone --quiet --depth 1 --branch 2.9.6 https://github.com/scinfu/SwiftSoup.git "$TASK_TMP/SwiftSoup"
test "$(git -C "$TASK_TMP/SwiftSoup" rev-parse HEAD)" = dee225a3da7b68d34936abc4dc8f34f2264db647
find "$TASK_TMP/SwiftSoup/Sources" -name '*.swift' -print0 | xargs -0 xcrun swiftc   -emit-module -parse-as-library -swift-version 5 -module-name SwiftSoup   -sdk "$SDK" -target arm64-apple-ios18.0-simulator -emit-module-path "$TASK_TMP/SwiftSoup.swiftmodule"
xcrun swiftc -emit-module -enable-testing -parse-as-library -swift-version 5 -module-name Runner   -sdk "$SDK" -target arm64-apple-ios18.0-simulator -I "$TASK_TMP" -F "$FRAMEWORKS"   -emit-module-path "$TASK_TMP/Runner.swiftmodule"   ios/Runner/SourceWebController.swift ios/Runner/WafCookieController.swift ios/Runner/PipController.swift ios/Runner/PipFramePump.swift
PLATFORM_DEVELOPER="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
TEST_FRAMEWORKS="$PLATFORM_DEVELOPER/Library/Frameworks"
xcrun swiftc -typecheck -swift-version 5 -sdk "$SDK" -target arm64-apple-ios18.0-simulator   -I "$TASK_TMP" -I "$PLATFORM_DEVELOPER/usr/lib" -F "$FRAMEWORKS" -F "$TEST_FRAMEWORKS" ios/RunnerTests/RunnerTests.swift
printf 'Native source runtime and XCTest typechecks passed; no App or IPA generated.\n'
