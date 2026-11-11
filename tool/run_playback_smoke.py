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


def run_attempt(command, seconds, device, output, label):
    log_path = output / f'{label}-test.log'
    with log_path.open('w') as log:
        process = subprocess.Popen(
            command, stdout=log, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            print(f'{label} exceeded its runner deadline', flush=True)
            try:
                collect_stall(device, output, label)
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f'Could not collect all stall evidence: {error}', flush=True)
            if process.poll() is None and os.getpgid(process.pid) == process.pid:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=15)
            code = 124
    subprocess.run(
        ['xcrun', 'simctl', 'terminate', device, 'com.lumebox.app'],
        check=False, timeout=20, capture_output=True,
    )
    lines = log_path.read_text(errors='replace').splitlines()
    for line in lines:
        match = re.search(r'KERNEL_SMOKE_TRACE (.+)', line)
        if match:
            stages = Path(match[1].strip())
            if (stages.is_absolute() and stages.name == 'lumebox-playback-stage.log'
                    and stages.is_file()):
                shutil.copyfile(stages, output / f'{label}-stages.log')
                print(stages.read_text(), flush=True)
                stages.unlink()
            break
    return code, lines


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
        command = [
            'flutter', 'test', '--no-pub', '--verbose',
            'integration_test/playback_smoke_test.dart', '-d', args.device,
            f'--dart-define=KERNEL_SMOKE={kernel}', '--timeout', '2m',
        ]
        if kernel == 'mpv':
            command.append('--dart-define=KERNEL_SMOKE_HEADLESS_AUDIO=true')
            print('MPV simulator uses a timed null audio sink; speaker output is not tested.',
                  flush=True)
        print(f'Starting {kernel} simulator checks', flush=True)
        code, lines = run_attempt(
            command, 900 if index == 0 else 360, args.device, args.output, kernel,
        )
        # Retry only a launch that never entered Dart tests, retaining both logs.
        # Actual assertion failures and playback errors are never retried away.
        if (index == 0 and code != 0
                and not any('KERNEL_SMOKE_STAGE' in line for line in lines)
                and any('Waiting for VM Service port' in line for line in lines)):
            print('Cold launch did not connect to the VM; retrying once with the warm build.',
                  flush=True)
            code, lines = run_attempt(
                command, 360, args.device, args.output, f'{kernel}-retry',
            )
        marker_pattern = re.compile(
            (r'PLAYBACK_SMOKE_OK' if kernel == 'avplayer'
             else rf'KERNEL_SMOKE_OK {kernel}') + r' (smoke\.(?:mp4|m3u8))'
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
