"""Fetch a pinned CPython iOS runtime and hash-locked pure-Python packages.

Run before an iOS build. --packages-only also runs on Windows for source tests.
No third-party source scripts or credentials are bundled by this tool.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_URL = "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b13/Python-3.13-iOS-support.b13.tar.gz"
RUNTIME_SHA256 = "d1f95f95137a4b91dc0cbe9b99ddfc0a78918dde883c7fbe7147074a5e715274"


def download(url, digest, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return
    temporary = path.with_suffix(path.suffix + ".partial")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as out:
            shutil.copyfileobj(response, out)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
            raise ValueError("下载校验失败：" + path.name)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare(output, packages_only=False):
    output.mkdir(parents=True, exist_ok=True)
    cache = ROOT / ".cache/python-runtime"
    if not packages_only and not (output / "Python.xcframework/Info.plist").exists():
        archive = cache / "Python-3.13-iOS-support.b13.tar.gz"
        download(RUNTIME_URL, RUNTIME_SHA256, archive)
        # tarfile's data filter validates links stay inside the pinned archive.
        with tarfile.open(archive) as package:
            package.extractall(output, filter="data")
    lock = (ROOT / "tool/python_packages.lock.json").read_bytes()
    fingerprint = hashlib.sha256(lock).hexdigest()
    stamp = output / "packages.sha256"
    if not stamp.exists() or stamp.read_text().strip() != fingerprint:
        staging = output / "packages.staging"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir()
        for item in json.loads(lock):
            filename = item["url"].rsplit("/", 1)[1]
            wheel = cache / filename
            download(item["url"], item["sha256"], wheel)
            with zipfile.ZipFile(wheel) as package:
                for name in package.namelist():
                    target = (staging / name).resolve()
                    if not target.is_relative_to(staging.resolve()):
                        raise ValueError("wheel 路径越界")
                    if name.endswith((".so", ".pyd", ".dylib")):
                        raise ValueError("只允许纯 Python wheel")
                package.extractall(staging)
        installed = output / "packages"
        if installed.exists():
            shutil.rmtree(installed)
        staging.replace(installed)
        stamp.write_text(fingerprint + "\n")
    print("Python packages ready" if packages_only else "CPython 3.13-b13 and Python packages ready")
    if not packages_only:
        prepare_native()


def prepare_native():
    """Only hash-locked iOS wheels; phone-time imports never install binaries."""
    for item in json.loads((ROOT / 'tool/python_native_packages.lock.json').read_bytes()):
        name = item['url'].rsplit('/', 1)[1]
        if not name.endswith('_' + item['arch'] + '_' + item['platform'] + '.whl') or '-cp313-' not in name:
            raise ValueError('原生 wheel 架构或 Python ABI 不匹配：' + name)
        download(item['url'], item['sha256'], ROOT / '.cache/python-runtime' / name)


def install_native(packages, architecture, simulator):
    platform = 'iphonesimulator' if simulator else 'iphoneos'
    for item in json.loads((ROOT / 'tool/python_native_packages.lock.json').read_bytes()):
        if item['arch'] != architecture or item['platform'] != platform:
            continue
        wheel = ROOT / '.cache/python-runtime' / item['url'].rsplit('/', 1)[1]
        download(item['url'], item['sha256'], wheel)
        with zipfile.ZipFile(wheel) as archive:
            for name in archive.namelist():
                target = (packages / name).resolve()
                if not target.is_relative_to(packages.resolve()) or '\\' in name or ':' in name:
                    raise ValueError('原生 wheel 路径越界')
                if name.endswith(('.dylib', '.pyd')) or '.data/' in name:
                    raise ValueError('原生 wheel 需先整理为独立扩展模块：' + name)
            archive.extractall(packages)


def embed(output):
    """Xcode post-resource phase: install architecture-specific Python modules."""
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    runtime = output / "Python.xcframework"
    simulator = os.environ.get("PLATFORM_NAME") == "iphonesimulator"
    slice_path = runtime / ("ios-arm64_x86_64-simulator" if simulator else "ios-arm64")
    architecture = os.environ.get("CURRENT_ARCH", "arm64")
    if architecture not in ("arm64", "x86_64"):
        architecture = os.environ.get("ARCHS", "arm64").split()[0]
    destination = app / "python"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(runtime / "lib", destination / "lib", ignore=shutil.ignore_patterns("__pycache__", "test", "tests"))
    shutil.copytree(slice_path / ("lib-" + architecture), destination / "lib", dirs_exist_ok=True)
    shutil.copytree(output / "packages", destination / "packages", ignore=shutil.ignore_patterns("__pycache__"))
    install_native(destination / 'packages', architecture, simulator)
    shutil.copytree(ROOT / "assets/python", destination, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("__pycache__"))

    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    python_framework = frameworks / "Python.framework"
    if python_framework.exists():
        shutil.rmtree(python_framework)
    shutil.copytree(slice_path / "Python.framework", python_framework, symlinks=True)
    for name in ("Headers", "Modules"):
        candidate = python_framework / name
        if candidate.is_symlink():
            candidate.unlink()
        elif candidate.is_dir():
            shutil.rmtree(candidate)
    import plistlib
    import subprocess
    native_roots = [destination / 'lib/python3.13/lib-dynload', destination / 'packages']
    for binary in [path for base in native_roots for path in base.rglob('*.so')]:
        base = next(base for base in native_roots if binary.is_relative_to(base))
        relative = binary.relative_to(base)
        module = '.'.join((*relative.parts[:-1], binary.name.split('.', 1)[0]))
        if module.startswith(("_test", "xx")):
            binary.unlink()
            continue
        folder = frameworks / (module + ".framework")
        folder.mkdir(exist_ok=True)
        target = folder / module
        subprocess.run(['/usr/bin/lipo', str(binary), '-verify_arch', architecture], check=True)
        shutil.move(str(binary), target)
        identifier = os.environ.get("PRODUCT_BUNDLE_IDENTIFIER", "com.lumebox.app") + "." + module.replace("_", "-")
        with (folder / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": module, "CFBundleIdentifier": identifier,
                "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "18.0"}, handle)
        marker = binary.with_suffix(".fwork")
        marker.write_text(target.relative_to(app).as_posix() + "\n")
        (folder / (module + ".origin")).write_text(marker.relative_to(app).as_posix() + "\n")
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        for framework in frameworks.glob("*.framework"):
            if framework.name == "Python.framework" or (framework / (framework.stem + ".origin")).exists():
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", str(framework)], check=True)
    print("Embedded CPython", architecture, "simulator" if simulator else "device")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages-only", action="store_true")
    parser.add_argument("--embed", action="store_true")
    parser.add_argument("--native-packages-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "ios/PythonRuntime")
    args = parser.parse_args()
    if args.native_packages_only:
        prepare_native()
    elif args.embed:
        embed(args.output)
    else:
        prepare(args.output, args.packages_only)
