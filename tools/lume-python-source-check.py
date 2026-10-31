"""Run a Python source through the production Spider host with bounded curl HTTP.

This CLI supports the HTTP bridge; native crypto/web/media calls fail explicitly.
Usage: python tools/lume-python-source-check.py source.py [--json]
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types

ROOT = Path(__file__).resolve().parents[1]
CURL = shutil.which('curl.exe' if os.name == 'nt' else 'curl')


def http_request(url, method='GET', headers=None, body=b'', timeout=15):
    if not CURL:
        raise RuntimeError('curl is required for the bounded HTTP bridge')
    with tempfile.TemporaryDirectory(prefix='lume-py-check-') as directory:
        header_file = Path(directory) / 'headers'
        command = [CURL, '--silent', '--show-error', '--compressed', '--max-time', str(timeout),
                   '--max-filesize', '8388608', '--dump-header', str(header_file), '-X', method, url]
        for key, value in (headers or {}).items():
            if key.lower() not in ('content-length', 'accept-encoding'):
                command.extend(['-H', f'{key}: {value}'])
        if body:
            command.extend(['--data-binary', '@-'])
        response = subprocess.run(command, input=body, capture_output=True, timeout=timeout + 2)
        if response.returncode:
            raise RuntimeError('HTTP request failed (curl %s)' % response.returncode)
        raw_headers = header_file.read_bytes().decode('iso-8859-1')
        blocks = [block for block in raw_headers.split('\r\n\r\n') if block.startswith('HTTP/')]
        if not blocks:
            raise RuntimeError('HTTP response headers are missing')
        lines = blocks[-1].splitlines()
        status = int(lines[0].split()[1])
        parsed = {}
        for line in lines[1:]:
            if ':' in line:
                key, value = line.split(':', 1)
                parsed[key.lower()] = value.strip()
        return status, parsed, response.stdout


def invoke(raw):
    request = json.loads(raw)
    try:
        if request['method'] != 'http':
            raise RuntimeError('This CLI cannot verify native bridge: ' + request['method'])
        value = request['payload']
        status, headers, body = http_request(value['url'], value.get('method', 'GET'),
            value.get('headers'), base64.b64decode(value.get('body', '')),
            max(1, min(20, request.get('timeout', 15))))
        return json.dumps({'ok': True, 'value': {
            'status': status, 'headers': headers, 'body': base64.b64encode(body).decode(),
        }})
    except Exception as error:
        return json.dumps({'ok': False, 'error': str(error)})


def check(path):
    source = path.read_text(encoding='utf-8-sig')
    match = re.search(r'^\s*#\s*LumeSource:\s*(\{[^\n]+\})', source, re.M)
    identity = json.loads(match[1]) if match else {}
    report = {'id': identity.get('id', ''), 'file': str(path), 'ok': False, 'calls': {}}
    native = types.ModuleType('_lume_host')
    native.invoke = invoke
    sys.modules['_lume_host'] = native
    sys.path.insert(0, str(ROOT / 'assets/python'))
    sys.path.insert(0, str(ROOT / '.cache/python-source-runtime/packages'))
    spec = importlib.util.spec_from_file_location('lume_python', ROOT / 'assets/python/lume_python.py')
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)

    def call(method, argument=None):
        result = json.loads(host.run(json.dumps({
            'sourceId': 'cli-source', 'action': 'call', 'method': method,
            'argument': argument or {}, 'timeout': 30,
        })))
        if not result['ok']:
            raise RuntimeError(result['error']['message'])
        return result['value']

    try:
        loaded = json.loads(host.run(json.dumps({
            'sourceId': 'cli-source', 'action': 'load', 'script': source, 'timeout': 15,
        })))
        if not loaded['ok']:
            raise RuntimeError(loaded['error']['message'])
        categories = call('categories')
        report['calls']['categories'] = {'ok': True, 'count': len(categories)}
        home = call('home')
        report['calls']['home'] = {'ok': True, 'count': len(home)}
        category = categories[0]['id'] if categories else ''
        listing = call('list', {'categoryId': category, 'page': 1})['items']
        if not listing:
            raise RuntimeError('The first category returned no items')
        report['calls']['list'] = {'ok': True, 'count': len(listing)}
        item = listing[0]
        detail = call('detail', {'id': item['id']})
        report['calls']['detail'] = {'ok': bool(detail), 'title': 'present' if detail else ''}
        episodes = call('chapters', {'id': item['id']})
        if not episodes:
            raise RuntimeError('No episodes returned')
        report['calls']['chapters'] = {'ok': True, 'count': len(episodes)}
        content = call('content', {'id': item['id'], 'chapterId': episodes[0]['id']})
        report['calls']['content'] = {'ok': True, 'kind': content.get('kind')}
        status, headers, prefix = http_request(content['url'], headers={
            **content.get('headers', {}), 'Range': 'bytes=0-1023',
        })
        playable = status in (200, 206) and (
            prefix.startswith(b'#EXTM3U') or b'ftyp' in prefix[:32])
        report['calls']['playable'] = {'ok': playable, 'probe': {
            'ok': playable, 'status': status, 'type': headers.get('content-type', ''),
        }}
        report['ok'] = playable
    except Exception as error:
        report['calls']['run'] = {'ok': False, 'error': str(error)}
    finally:
        host.run(json.dumps({'sourceId': 'cli-source', 'action': 'dispose'}))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--json', action='store_true')
    options = parser.parse_args()
    result = check(options.source)
    print(json.dumps([result], ensure_ascii=not options.json, indent=2))
    raise SystemExit(0 if result['ok'] else 1)
