import 'dart:io';
import 'dart:typed_data';

typedef _Box = ({String type, int payload, int end});

/// Both offline remuxers produce a non-fragmented, fast-start MP4. Inspect
/// its track metadata before committing it in place of the original HLS.
Future<bool> isMergedVideoMp4(File file) async {
  RandomAccessFile? handle;
  try {
    final input = handle = await file.open();
    final size = await input.length();
    var media = false, video = false;
    await for (final box in _boxes(input, 0, size)) {
      if (box.type == 'mdat' && box.end > box.payload) media = true;
      if (box.type != 'moov') continue;
      await for (final track in _boxes(input, box.payload, box.end)) {
        if (track.type != 'trak') continue;
        await for (final child in _boxes(input, track.payload, track.end)) {
          if (child.type == 'mdia' && await _hasVideoSamples(input, child)) {
            video = true;
          }
        }
      }
    }
    return media && video;
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  } finally {
    await handle?.close();
  }
}

Stream<_Box> _boxes(RandomAccessFile input, int start, int end) async* {
  for (var offset = start; offset < end;) {
    if (end - offset < 8) throw const FormatException('MP4 box header');
    await input.setPosition(offset);
    final header = await input.read(8);
    if (header.length != 8) throw const FormatException('MP4 box header');
    final type = String.fromCharCodes(header, 4);
    if (offset == 0 && type != 'ftyp') {
      throw const FormatException('MP4 file type');
    }
    var size = ByteData.sublistView(header).getUint32(0), headerSize = 8;
    if (size == 0) {
      size = end - offset;
    } else if (size == 1) {
      final extended = await input.read(8);
      if (extended.length != 8) {
        throw const FormatException('MP4 extended size');
      }
      size = ByteData.sublistView(extended).getUint64(0);
      headerSize = 16;
    }
    if (size < headerSize || size > end - offset) {
      throw const FormatException('MP4 box size');
    }
    yield (type: type, payload: offset + headerSize, end: offset + size);
    offset += size;
  }
}

Future<bool> _hasVideoSamples(RandomAccessFile input, _Box media) async {
  var video = false, samples = false;
  await for (final child in _boxes(input, media.payload, media.end)) {
    if (child.type == 'hdlr' && child.end - child.payload >= 12) {
      await input.setPosition(child.payload + 8);
      video = String.fromCharCodes(await input.read(4)) == 'vide';
    } else if (child.type == 'minf') {
      await for (final table in _boxes(input, child.payload, child.end)) {
        if (table.type != 'stbl') continue;
        await for (final box in _boxes(input, table.payload, table.end)) {
          if (box.type != 'stsz' && box.type != 'stz2') continue;
          if (box.end - box.payload < 12) continue;
          await input.setPosition(box.payload + 4);
          final fields = await input.read(8);
          if (fields.length != 8) continue;
          final data = ByteData.sublistView(fields);
          final count = data.getUint32(4);
          if (count == 0) continue;
          final int bits;
          if (box.type == 'stz2') {
            bits = fields[3];
            if (bits != 4 && bits != 8 && bits != 16) continue;
          } else {
            bits = data.getUint32(0) == 0 ? 32 : 0;
          }
          samples = count * bits <= (box.end - box.payload - 12) * 8;
        }
      }
    }
  }
  return video && samples;
}
