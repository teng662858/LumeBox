"""Run each iOS kernel independently, retaining evidence if a runner hangs."""

import argparse
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys


def collect_stall(device, output, kernel):
    subprocess.run(
        ['xcrun', 'simctl', 'io', device, 'screenshot',
         str(output / f'{kernel}-stalled.png')],
        check=False, timeout=20,
    )
    processes = subprocess.run(
        ['pgrep', '-x', 'Runner'], capture_output=True, text=True, check=False,
    )
    for value in processes.stdout.splitlines():
        if value.isdigit():
            subprocess.run(
                ['sample', value, '3', '-file',
                 str(output / f'{kernel}-native-stack-{value}.txt')],
                check=False, timeout=20,
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('device')
    parser.add_argument('--output', type=Path, default=Path('out/playback-smoke'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    failed = []
    # A blocked native constructor in one engine must not prevent the other
    # kernels from executing. Reuse the same native build between app launches.
    for index, kernel in enumerate(['avplayer', 'mdk', 'aether', 'mpv']):
        log_path = args.output / f'{kernel}-test.log'
        command = [
            'flutter', 'test', '--no-pub', '--no-dds', '--verbose',
            'integration_test/playback_smoke_test.dart', '-d', args.device,
            f'--dart-define=KERNEL_SMOKE={kernel}', '--timeout', '2m',
        ]
        print(f'Starting {kernel} simulator checks', flush=True)
        with log_path.open('w') as log:
            process = subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
            try:
                # First invocation includes the cold Xcode build. Later runs
                # rebuild the Dart entrypoint but reuse compiled native SDKs.
                code = process.wait(timeout=720 if index == 0 else 240)
            except subprocess.TimeoutExpired:
                print(f'{kernel} exceeded its runner deadline', flush=True)
                try:
                    collect_stall(args.device, args.output, kernel)
                except (OSError, subprocess.TimeoutExpired) as error:
                    print(f'Could not collect all stall evidence: {error}', flush=True)
                # Only terminate this subprocess session and its descendants.
                if process.poll() is None and os.getpgid(process.pid) == process.pid:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=15)
                code = 124
        container = subprocess.run(
            ['xcrun', 'simctl', 'get_app_container', args.device,
             'com.lumebox.app', 'data'],
            check=False, capture_output=True, text=True, timeout=20,
        )
        if container.returncode == 0:
            stages = Path(container.stdout.strip()) / 'tmp/lumebox-playback-stage.log'
            if stages.is_file():
                shutil.copyfile(stages, args.output / f'{kernel}-stages.log')
                print(stages.read_text(), flush=True)
                stages.unlink()
        subprocess.run(
            ['xcrun', 'simctl', 'terminate', args.device, 'com.lumebox.app'],
            check=False, timeout=20, capture_output=True,
        )
        lines = log_path.read_text(errors='replace').splitlines()
        marker_pattern = re.compile(
            rf'(?:KERNEL_SMOKE_OK {kernel}|PLAYBACK_SMOKE_OK) (smoke\.(?:mp4|m3u8))'
        )
        markers = {}
        for line in lines:
            match = marker_pattern.search(line)
            if match:
                markers[match[1]] = line
        for line in markers.values():
            print(line, flush=True)
        if code != 0 or len(markers) != 2:
            failed.append(kernel)
            print('\n'.join(lines[-40:]), flush=True)
            print(f'{kernel}: FAILED (exit={code}, completed={len(markers)}/2)',
                  flush=True)
        else:
            print(f'{kernel}: PASSED (2/2)', flush=True)
    if failed:
        print(f'Failed kernels: {", ".join(failed)}', flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
