"""Offline protocol load check for the published Python collection; no live availability claim.
Dependencies use .cache/python-source-runtime/packages, as lume-python-source-check.py does.
Each script runs in a bounded child process; network/native calls and writes outside scratch are disabled.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys


def batch():
    root = Path(__file__).resolve().parents[1]
    rows = json.loads((root / 'sources/python-collection.json').read_text('utf-8'))['sources']
    paths = [root / 'sources' / row['path'] for row in rows if row['status'] == 'published']
    def check(path):
        try:
            result = subprocess.run([sys.executable, __file__, '--worker', str(path)], capture_output=True, timeout=12)
            return path, json.loads(result.stdout)
        except Exception as error:
            return path, {'ok': False, 'error': str(error)}
    passed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for number, (path, result) in enumerate(pool.map(check, paths), 1):
            passed += bool(result.get('ok'))
            if not result.get('ok'):
                print(path.name, json.dumps(result, ensure_ascii=True), flush=True)
            if number % 50 == 0:
                print('Checked', number, flush=True)
    print('Passed %s/%s offline host loads' % (passed, len(paths)))
    return 0 if passed == len(paths) else 1


if __name__ == '__main__' and '--worker' not in sys.argv:
    raise SystemExit(batch())

# Worker-only imports and audit guard follow.
import importlib.util
import json
from pathlib import Path
import sys
import types
import os
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT/'.cache/python-source-runtime/packages'))
sys.path.insert(0, str(ROOT/'assets/python'))
native = types.ModuleType('_lume_host')
native.invoke = lambda raw: json.dumps({'ok':False,'error':'OFFLINE_CHECK: network and native calls disabled'})
sys.modules['_lume_host'] = native
spec = importlib.util.spec_from_file_location('lume_python', ROOT/'assets/python/lume_python.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
raw = Path(sys.argv[2]).read_bytes()
import base64
script = '# LumePythonBytes: '+base64.b64encode(raw).decode()

# The production host creates a private writable directory even for a plain
# script. Permit that scratch area while keeping user/project files read-only.
scratch = tempfile.TemporaryDirectory(prefix='lume-offline-audit-')
tempfile.tempdir = scratch.name
scratch_root = Path(scratch.name).resolve()


def scratch_path(value):
    if not isinstance(value, (str, bytes, os.PathLike)):
        return False
    try:
        return Path(os.fsdecode(value)).resolve().is_relative_to(scratch_root)
    except (OSError, ValueError):
        return False

def guard(event, args):
    if event.startswith(('socket.', 'subprocess.', 'os.system', 'os.exec', 'os.spawn')):
        raise RuntimeError('OFFLINE_CHECK: blocked '+event)
    if event in ('os.remove', 'os.rmdir', 'os.mkdir') and not scratch_path(args[0]):
        raise RuntimeError('OFFLINE_CHECK: writes outside scratch disabled')
    if event == 'os.rename' and not all(scratch_path(value) for value in args[:2]):
        raise RuntimeError('OFFLINE_CHECK: writes outside scratch disabled')
    if event == 'open':
        mode, flags = args[1], args[2]
        if (isinstance(mode, str) and any(x in mode for x in 'wax+')) or (isinstance(flags, int) and flags & (1 | 2 | 64 | 512 | 1024)):
            if not scratch_path(args[0]):
                raise RuntimeError('OFFLINE_CHECK: file writes outside scratch disabled')
sys.addaudithook(guard)
result = json.loads(host.run(json.dumps({'sourceId':'audit','action':'load','script':script,'timeout':5})))
host.run(json.dumps({'sourceId':'audit','action':'dispose'}))
sys.stdout.buffer.write(json.dumps(result, ensure_ascii=True).encode('ascii'))
