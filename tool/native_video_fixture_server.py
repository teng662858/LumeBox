"""Local simulator fixtures with the byte-range responses AVPlayer requires."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
import re


class MediaHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        self._remaining = None
        if self.path.startswith('/protected/'):
            if self.headers.get('X-Lume-Test') != r'ticket=a,b\c':
                self.send_error(403, 'Missing exact fixture header')
                return None
            self.path = self.path[len('/protected'):]
        path = self.translate_path(self.path)
        request = self.headers.get('Range')
        if not request or not os.path.isfile(path):
            return super().send_head()
        match = re.fullmatch(r'bytes=(\d*)-(\d*)', request)
        size = os.path.getsize(path)
        if not match or not any(match.groups()):
            self.send_error(400, 'Invalid byte range')
            return None
        first, last = match.groups()
        start = int(first) if first else max(0, size - int(last))
        end = min(size - 1, int(last)) if first and last else size - 1
        if start >= size or end < start:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{size}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None
        source = open(path, 'rb')
        source.seek(start)
        self._remaining = end - start + 1
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(self._remaining))
        self.end_headers()
        return source

    def copyfile(self, source, output):
        try:
            if self._remaining is None:
                super().copyfile(source, output)
                return
            while self._remaining:
                block = source.read(min(65536, self._remaining))
                if not block:
                    return
                output.write(block)
                self._remaining -= len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Players routinely cancel read-ahead after receiving a prefix.


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    parser.add_argument('--port', type=int, default=18765)
    args = parser.parse_args()
    ThreadingHTTPServer(('127.0.0.1', args.port), partial(MediaHandler, directory=args.directory)).serve_forever()
