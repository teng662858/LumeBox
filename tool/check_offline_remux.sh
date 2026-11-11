#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || brew install ffmpeg
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
# Use the same binary dependencies resolved for the app, including their macOS slices.
SEARCH_ROOTS=(build "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Caches/org.swift.swiftpm")
python3 - "$CHECK_DIR" "${SEARCH_ROOTS[@]}" <<'PY'
from pathlib import Path
import os, sys
dest = Path(sys.argv[1]) / 'frameworks'
dest.mkdir()
for root in map(Path, sys.argv[2:]):
    if not root.exists(): continue
    for framework in root.rglob('Aether*.framework'):
        if 'macos' not in str(framework.parent).lower(): continue
        target = dest / framework.name
        if not target.exists(): os.symlink(framework.resolve(), target)
assert (dest / 'AetherLibavformat.framework').exists(), 'Resolved FFmpeg macOS slice missing'
PY
cat > "$CHECK_DIR/main.swift" <<'SWIFT'
import Foundation
let worker = OfflineVideoRemuxer()
if CommandLine.arguments.contains("--cancel") { worker.cancel() }
do {
  let args = CommandLine.arguments
  if args.count == 5, args[1] == "--fragment", let sequence = Int(args[2]) {
    let output = try worker.fragment(input: Data(contentsOf: URL(fileURLWithPath: args[3])), sequence: sequence)
    try output.write(to: URL(fileURLWithPath: args[4]))
  } else { try worker.merge(directory: URL(fileURLWithPath: args[1])) }
}
catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
SWIFT
xcrun swiftc ios/Runner/OfflineVideoRemuxer.swift "$CHECK_DIR/main.swift" \
  -F "$CHECK_DIR/frameworks" -framework AetherLibavformat -framework AetherLibavcodec \
  -framework AetherLibavutil -Xlinker -rpath -Xlinker "$CHECK_DIR/frameworks" -o "$CHECK_DIR/remux"
python3 tool/test_offline_remux.py "$CHECK_DIR/remux" "$CHECK_DIR/fixtures"
