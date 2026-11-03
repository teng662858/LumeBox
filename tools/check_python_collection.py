"""Offline protocol load check for the published Python collection; no live availability claim.
Dependencies use .cache/python-source-runtime/packages, as lume-python-source-check.py does.
Each script runs in a bounded child process; network, native calls and file writes are disabled.
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

def guard(event, args):
    if event.startswith(('socket.', 'subprocess.', 'os.system', 'os.exec', 'os.spawn', 'os.remove', 'os.rename', 'os.rmdir', 'os.mkdir', 'shutil.')):
        raise RuntimeError('OFFLINE_CHECK: blocked '+event)
    if event == 'open':
        mode, flags = args[1], args[2]
        if (isinstance(mode, str) and any(x in mode for x in 'wax+')) or (isinstance(flags, int) and flags & (1 | 2 | 64 | 512 | 1024)):
            raise RuntimeError('OFFLINE_CHECK: file writes disabled')
sys.addaudithook(guard)
result = json.loads(host.run(json.dumps({'sourceId':'audit','action':'load','script':script,'timeout':5})))
sys.stdout.buffer.write(json.dumps(result, ensure_ascii=True).encode('ascii'))
