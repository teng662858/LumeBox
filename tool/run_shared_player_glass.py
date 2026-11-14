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
               '--timeout', '5m', '--reporter', 'expanded']
    recording_log = (output / 'recording.log').open('w')
    recording_start = time.time()
    recorder = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo',
                                 str(output / 'simulator.mp4')],
                                stdout=recording_log, stderr=subprocess.STDOUT)
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    lines = queue.Queue()

    def read():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()
    captures = {}
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
                match = re.search(r'PLAYER_GLASS_CAPTURE ([a-z-]+) ([0-9]+)', line)
                if match and match[1] not in captures:
                    # Flutter may flush test stdout in batches. Use the time
                    # inside the simulator, not when the host receives a line.
                    captures[match[1]] = max(0, int(match[2]) / 1_000_000 - recording_start + .8)
                match = re.search(r'SHARED_PLAYER_OK (avplayer|mpv|aether)', line)
                if match:
                    passed.add(match[1])
                    print(match[0], flush=True)
                if 'SHARED_PLAYER_ALL_OK' in line:
                    complete = True
            else:
                raise TimeoutError('Shared player simulator check timed out')
        code = process.wait(timeout=30)
        if code or not complete or passed != {'avplayer', 'mpv', 'aether'} or len(captures) != 6:
            print((output / 'shared-player.log').read_text()[-20000:])
            return code or 1
        return 0
    finally:
        if process.poll() is None:
            import os
            os.killpg(process.pid, signal.SIGTERM)
        recorder.send_signal(signal.SIGINT)
        try:
            recorder.wait(timeout=20)
        except subprocess.TimeoutExpired:
            recorder.terminate()
            recorder.wait(timeout=10)
        recording_log.close()
        # simctl screenshot can block while the display is being recorded.
        # Extract the settled states from the system recording after it closes.
        for name, seconds in captures.items():
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error',
                            '-ss', str(seconds), '-i', str(output / 'simulator.mp4'),
                            '-vf', 'transpose=cclock', '-frames:v', '1', '-y',
                            str(output / f'shared-{name}.png')],
                           check=True, timeout=30)


if __name__ == '__main__':
    sys.exit(main())
