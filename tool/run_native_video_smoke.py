"""Compile and validate the production native video screen; never creates an IPA."""
from pathlib import Path
import sys
from run_playback_smoke import run_attempt


def main():
    device = sys.argv[1]
    output = Path('out/playback-smoke')
    output.mkdir(parents=True, exist_ok=True)
    command = ['flutter', 'test', '--no-pub', '--verbose',
               'integration_test/native_video_smoke_test.dart', '-d', device,
               '--timeout', '3m']
    code, lines = run_attempt(command, 1100, device, output, 'native-video')
    # Retry only a VM attach failure before the test suite starts.
    if (code and not any('native avplayer video' in line for line in lines)
            and any('Waiting for VM Service port' in line for line in lines)):
        code, lines = run_attempt(command, 360, device, output, 'native-video-retry')
    markers = set()
    for line in lines:
        if 'NATIVE_VIDEO_OK ' in line or 'NATIVE_VIDEO_SWITCH_OK' in line:
            print(line, flush=True)
            markers.add(line.split('NATIVE_VIDEO_', 1)[1])
    if code or len(markers) < 5:
        print('\n'.join(lines[-100:]), flush=True)
        return code or 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
