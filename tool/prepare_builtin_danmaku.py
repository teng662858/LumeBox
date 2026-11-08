"""Rebuild the current mobile component from a checked-out upstream repository."""
import subprocess
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
subprocess.run(['node', str(root / 'tool/build_builtin_danmaku.mjs'), sys.argv[1]], cwd=root, check=True)
