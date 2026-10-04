#!/usr/bin/env python3
"""预取 sqlite3 的原生产物到 Flutter native assets 缓存。

sqlite3 3.x 通过构建钩子从 GitHub Release 下载预编译库。在 GitHub 直连不稳定的
网络下，Dart 的 HttpClient 常连接超时，导致 Android / iOS 构建在
`Building assets for package:sqlite3 failed` 处中断。

本脚本改用 curl 预取官方产物，按 sqlite3 包内附带的 SHA-256 表校验后写入钩子的
共享缓存目录（.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/），
后续构建即可直接命中缓存、不再联网。

用法:
    python tool/fetch_sqlite_assets.py                     # 默认 android windows
    python tool/fetch_sqlite_assets.py android ios macos
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE_CONFIG = os.path.join(PROJECT_ROOT, ".dart_tool", "package_config.json")
SHARED_DIR = os.path.join(
    PROJECT_ROOT, ".dart_tool", "hooks_runner", "shared", "sqlite3", "build"
)

# targetOS -> 钩子写入缓存时使用的库文件名
CACHE_FILENAME = {
    "android": "libsqlite3.so",
    "linux": "libsqlite3.so",
    "windows": "sqlite3.dll",
    "ios": "libsqlite3.dylib",
    "macos": "libsqlite3.dylib",
}

DEFAULT_TARGETS = ("android", "windows")
RETRIES = 4


def fail(message: str) -> None:
    print(f"错误: {message}", file=sys.stderr)
    raise SystemExit(1)


def package_dir(name: str) -> str:
    if not os.path.isfile(PACKAGE_CONFIG):
        fail(f"未找到 {PACKAGE_CONFIG}，请先运行 flutter pub get")
    with open(PACKAGE_CONFIG, encoding="utf-8") as handle:
        config = json.load(handle)
    for package in config["packages"]:
        if package["name"] != name:
            continue
        uri = package["rootUri"]
        if uri.startswith("file://"):
            path = urllib.request.url2pathname(urllib.parse.urlparse(uri).path)
            # Windows 上 file:///C:/x 解析后带前导斜杠，需去掉
            if re.match(r"^/[A-Za-z]:", path):
                path = path[1:]
            return path
        if os.path.isabs(uri):
            return uri
        return os.path.normpath(os.path.join(PROJECT_ROOT, uri))
    fail(f"package_config.json 中找不到 {name}")


def parse_hashes(path: str) -> tuple[str, dict[str, str]]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    tag = re.search(r"releaseTag = '([^']+)'", text)
    if tag is None:
        fail("无法从 asset_hashes.dart 解析 releaseTag")
    pairs = re.findall(r"'(libsqlite3\.[^']+|sqlite3\.[^']+)':\s*'([0-9a-f]{64})'", text)
    return tag.group(1), dict(pairs)


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: str) -> None:
    last_error = ""
    for attempt in range(1, RETRIES + 1):
        result = subprocess.run(
            ["curl", "-fSL", "--retry", "2", "--connect-timeout", "30",
             "-o", destination, url],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return
        last_error = (result.stderr or "").strip().splitlines()[-1:] or [""]
        last_error = last_error[0]
        if attempt < RETRIES:
            time.sleep(2 * attempt)
    fail(f"下载失败 {url}\n  {last_error}")


def fetch(asset: str, expected: str, tag: str, targets: tuple[str, ...]) -> bool:
    platform = asset.rsplit(".", 2)[-2]
    if platform not in targets:
        return False
    cache_name = CACHE_FILENAME.get(platform)
    if cache_name is None:
        return False

    directory = os.path.join(SHARED_DIR, f"download-{expected[:8]}")
    destination = os.path.join(directory, cache_name)
    os.makedirs(directory, exist_ok=True)

    if os.path.isfile(destination) and sha256_of(destination) == expected:
        print(f"已就绪  {asset}")
        return True

    url = (
        "https://github.com/simolus3/sqlite3.dart/releases/download/"
        f"{tag}/{asset}"
    )
    with tempfile.TemporaryDirectory() as tmp:
        staged = os.path.join(tmp, cache_name)
        download(url, staged)
        actual = sha256_of(staged)
        if actual != expected:
            fail(f"SHA-256 不匹配 {asset}\n  期望 {expected}\n  实际 {actual}")
        shutil.move(staged, destination)
    print(f"已获取  {asset} -> {os.path.relpath(destination, PROJECT_ROOT)}")
    return True


def cleanup_stale(targets: tuple[str, ...]) -> None:
    if not os.path.isdir(SHARED_DIR):
        return
    for entry in os.listdir(SHARED_DIR):
        candidate = os.path.join(SHARED_DIR, entry, "libsqlite3.so.tmp")
        if os.path.isfile(candidate):
            os.remove(candidate)
            print(f"已清理  {os.path.relpath(candidate, PROJECT_ROOT)}")


def main(argv: list[str]) -> int:
    targets = tuple(argv[1:]) or DEFAULT_TARGETS
    unknown = [name for name in targets if name not in CACHE_FILENAME]
    if unknown:
        fail(f"不支持的平台: {', '.join(unknown)}")

    sqlite_dir = package_dir("sqlite3")
    tag, hashes = parse_hashes(
        os.path.join(sqlite_dir, "lib", "src", "hook", "asset_hashes.dart")
    )
    print(f"sqlite3 {tag}，目标平台: {', '.join(targets)}")

    fetched = 0
    for asset, expected in sorted(hashes.items()):
        # 默认类型：Windows 为 sqlite3.*，其余平台为 libsqlite3.*；
        # 排除 sqlcipher / sqlite3mc 变体。
        if not asset.startswith(("sqlite3.", "libsqlite3.")):
            continue
        if fetch(asset, expected, tag, targets):
            fetched += 1

    cleanup_stale(targets)
    if fetched == 0:
        fail(f"没有找到匹配 {', '.join(targets)} 的产物")
    print(f"完成，共 {fetched} 个产物。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
