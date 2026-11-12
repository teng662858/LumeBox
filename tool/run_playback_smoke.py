"""Run each iOS kernel independently, retaining evidence if a runner hangs."""

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
    # Keep the old command name usable without resurrecting removed decoders.
    from run_native_video_smoke import main as run_native
    return run_native()


if __name__ == '__main__':
    sys.exit(main())
