"""Exercise real Flutter/UIKit compositing and retain simulator screenshots."""
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time


def main():
    device = sys.argv[1]
    output = Path('out/playback-smoke')
    output.mkdir(parents=True, exist_ok=True)
    command = ['flutter', 'test', '--no-pub', '--verbose',
               'integration_test/shared_player_glass_test.dart', '-d', device,
               '--timeout', '5m']
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    lines = queue.Queue()

    def read():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()
    captured = set()
    passed = set()
    complete = False
    deadline = time.monotonic() + 1800
    try:
        with (output / 'shared-player.log').open('w') as log:
            while time.monotonic() < deadline:
                try:
                    line = lines.get(timeout=1)
                except queue.Empty:
                    continue
                if line is None:
                    break
                log.write(line)
                log.flush()
                match = re.search(r'PLAYER_GLASS_CAPTURE ([a-z-]+)', line)
                if match and match[1] not in captured:
                    name = match[1]
                    subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot',
                                    str(output / f'shared-{name}.png')],
                                   check=True, timeout=20)
                    captured.add(name)
                match = re.search(r'SHARED_PLAYER_OK (avplayer|mpv|aether)', line)
                if match:
                    passed.add(match[1])
                    print(match[0], flush=True)
                if 'SHARED_PLAYER_ALL_OK' in line:
                    complete = True
            else:
                raise TimeoutError('Shared player simulator check timed out')
        code = process.wait(timeout=30)
        if code or not complete or passed != {'avplayer', 'mpv', 'aether'} or len(captured) != 4:
            print((output / 'shared-player.log').read_text()[-20000:])
            return code or 1
        return 0
    finally:
        if process.poll() is None:
            import os
            os.killpg(process.pid, signal.SIGTERM)


if __name__ == '__main__':
    sys.exit(main())
