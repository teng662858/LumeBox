"""Exercise the actual Swift/FFmpeg remuxer with generated media (macOS CI)."""
from pathlib import Path
import json
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.decode(errors="replace")}')
    return result


executable, root = sys.argv[1], Path(sys.argv[2])
root.mkdir(parents=True)
base = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y']
video = ['-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=10']
audio = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000']
codec = ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '10', '-c:a', 'aac']
hls = ['-f', 'hls', '-hls_time', '1', '-hls_playlist_type', 'vod']


def probe(path):
    return json.loads(run('ffprobe', '-v', 'error', '-show_streams', '-show_format',
                          '-of', 'json', str(path)).stdout)


def hashes(path):
    hls_options = ['-allowed_extensions', 'ALL', '-extension_picky', '0'] if Path(path).suffix == '.m3u8' else []
    output = run('ffmpeg', '-v', 'error', '-protocol_whitelist', 'file,crypto,data',
                 *hls_options, '-i', str(path), '-map', '0:v:0',
                 '-f', 'framemd5', '-').stdout.decode()
    return [line.split(',')[-1].strip() for line in output.splitlines()
            if line and not line.startswith('#')]


def check(directory, source=None):
    before = {str(p): p.read_bytes() for p in directory.rglob('*') if p.is_file()}
    run(executable, str(directory))
    output = directory / 'merged.mp4.part'
    result = probe(output)
    assert {s['codec_type'] for s in result['streams']} == {'video', 'audio'}, result
    assert 3.8 <= float(result['format']['duration']) <= 4.3, result
    assert hashes(output) == hashes(source or directory / 'index.m3u8'), 'Video content changed'
    for name, contents in before.items():
        assert Path(name).read_bytes() == contents, 'Original media changed'
    assert not (directory / '.remux-work').exists()


plain = root / 'plain'
plain.mkdir()
run(*base, *video, *audio, '-t', '4', *codec, *hls, str(plain / 'index.m3u8'))
playlist = plain / 'index.m3u8'
playlist.write_text(playlist.read_text().replace('#EXTINF:1.000000,', '#EXTINF:1.000000,URI="missing.ts"'))
check(plain)

fragmented = root / 'fmp4'
fragmented.mkdir()
run(*base, *video, *audio, '-t', '4', *codec, *hls,
    '-hls_segment_type', 'fmp4', str(fragmented / 'index.m3u8'))
check(fragmented)

separate = root / 'separate'
(separate / 'video').mkdir(parents=True)
(separate / 'audio').mkdir()
(separate / 'dub').mkdir()
run(*base, *video, '-t', '4', *codec, '-an', *hls, str(separate / 'video/index.m3u8'))
run(*base, *audio, '-t', '4', '-c:a', 'aac', *hls, str(separate / 'audio/index.m3u8'))
run(*base, '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000',
    '-t', '4', '-c:a', 'aac', *hls, str(separate / 'dub/index.m3u8'))
(separate / 'index.m3u8').write_text(
    '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Original,URI=missing",'
    'LANGUAGE="en",DEFAULT=NO,URI="audio/index.m3u8"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Mandarin",'
    'LANGUAGE="zh-Hans",DEFAULT=YES,URI="dub/index.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="audio"\nvideo/index.m3u8\n')
check(separate)
tracks = [s for s in probe(separate / 'merged.mp4.part')['streams'] if s['codec_type'] == 'audio']
assert [(s['tags']['language'], s['tags']['handler_name'], s['disposition']['default']) for s in tracks] == [
    ('eng', 'Original,URI=missing', 0), ('zho', 'Mandarin', 1)], tracks

encrypted = root / 'encrypted'
encrypted.mkdir()
(encrypted / 'key').write_bytes(bytes(range(16)))
(root / 'key-info').write_text(f'key\n{encrypted / "key"}\n')
run(*base, *video, *audio, '-t', '4', *codec, *hls,
    '-hls_key_info_file', str(root / 'key-info'), str(encrypted / 'index.m3u8'))
playlist = encrypted / 'index.m3u8'
playlist.write_text(playlist.read_text().replace('#EXT-X-KEY:', '#EXT-X-KEY:X-NOTE=",METHOD=NONE",'))
check(encrypted)

# Failure and cancellation must leave input intact and no completed-looking output.
for name, contents, cancel in [
    ('missing', '#EXTM3U\n#EXTINF:1,\nmissing.ts\n#EXT-X-ENDLIST\n', False),
    ('escape', '#EXTM3U\n#EXTINF:1,\n../plain/index0.ts\n#EXT-X-ENDLIST\n', False),
    ('cancel', (plain / 'index.m3u8').read_text(), True),
]:
    folder = root / name
    folder.mkdir()
    (folder / 'index.m3u8').write_text(contents)
    result = subprocess.run([executable, str(folder)] + (['--cancel'] if cancel else []),
                            capture_output=True)
    assert result.returncode != 0, name
    assert not (folder / 'merged.mp4.part').exists(), name
    assert not (folder / '.remux-work').exists(), name
    assert (folder / 'index.m3u8').read_text() == contents
print('Native remux: TS, fMP4, separate audio, AES-128, missing input, path escape and cancellation passed')

# Serve one init and independently requested HEVC fragments, including a seek
# (conversion runs in reverse order). Compare every decoded video and audio frame.
hevc = root / 'hevc-ts'
hevc.mkdir()
run(*base, *video, *audio, '-t', '4', '-c:v', 'libx265', '-g', '10',
    '-x265-params', 'scenecut=0', '-c:a', 'aac', *hls, str(hevc / 'index.m3u8'))
parts = sorted(hevc.glob('*.ts'))
assert len(parts) >= 2
playlist = (hevc / 'index.m3u8').read_text().replace('#EXT-X-VERSION:3',
    '#EXT-X-VERSION:7\n#EXT-X-MAP:URI="init.mp4"')
for i in reversed(range(len(parts))):
    output = hevc / 'mux.mp4'
    run(executable, '--fragment', str(i + 1), str(parts[i]), str(output))
    data = output.read_bytes()
    offset = 0
    while data[offset + 4:offset + 8] != b'moof':
        size = int.from_bytes(data[offset:offset + 4], 'big')
        assert 8 <= size <= len(data) - offset, 'Malformed MP4 box'
        offset += size
    if not i:
        (hevc / 'init.mp4').write_bytes(data[:offset])
    fragment = parts[i].with_suffix('.m4s')
    fragment.write_bytes(data[offset:])
    playlist = playlist.replace(parts[i].name, fragment.name)
converted = hevc / 'converted.m3u8'
converted.write_text(playlist)
assert hashes(converted) == hashes(hevc / 'index.m3u8'), 'HEVC playback frames changed'
for path in [converted, hevc / 'index.m3u8']:
    pcm = run('ffmpeg', '-v', 'error', '-i', str(path), '-map', '0:a:0', '-f', 's16le', '-').stdout
    if path == converted:
        decoded = pcm
    else:
        assert pcm == decoded, 'AAC playback samples changed'
