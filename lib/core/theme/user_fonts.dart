import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

class UserFont {
  const UserFont(this.id, this.name);
  final String id, name;
  String get family => 'LumeUserFont_$id';
}

/// Local font files are deliberately outside backup/sync manifests. Only the
/// selected font ID belongs to appearance settings; absent IDs use system fonts.
class UserFonts extends ChangeNotifier {
  UserFonts({Future<void> Function(String, Uint8List)? loader})
    : _loader = loader ?? _loadFont;
  static final instance = UserFonts();
  static const maxBytes = 32 * 1024 * 1024;
  final Future<void> Function(String, Uint8List) _loader;
  Directory? _directory;
  List<UserFont> _fonts = [];
  final Set<String> _loaded = {};
  List<UserFont> get fonts => List.unmodifiable(_fonts);

  static Future<void> _loadFont(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  Future<void>? _booting;
  Future<void> boot() => _booting ??= _boot();

  Future<void> _boot() async {
    if (_directory != null) return;
    _directory = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'custom_fonts'),
    );
    _fonts = [];
    try {
      final index = File(p.join(_directory!.path, 'index.json'));
      if (await index.exists()) {
        final data = jsonDecode(await index.readAsString());
        if (data is List) {
          final seen = <String>{};
          for (final item in data) {
            if (item is! Map ||
                item['id'] is! String ||
                item['name'] is! String) {
              continue;
            }
            final id = item['id'] as String, name = item['name'] as String;
            if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) || !seen.add(id)) {
              continue;
            }
            final file = _file(id);
            if (await file.exists() && await file.length() <= maxBytes) {
              _fonts.add(
                UserFont(id, name.length > 150 ? name.substring(0, 150) : name),
              );
            }
          }
        }
      }
    } catch (error) {
      LumeLog.warn('本机字体列表不可用，使用系统字体：$error');
    }
    notifyListeners();
  }

  File _file(String id) => File(p.join(_directory!.path, '$id.font'));
  UserFont? find(String id) {
    for (final font in _fonts) {
      if (font.id == id) return font;
    }
    return null;
  }

  String? familyFor(String id) =>
      _loaded.contains(id) ? find(id)?.family : null;

  Future<bool> ensureLoaded(String id) async {
    await boot();
    if (id.isEmpty || find(id) == null) return false;
    if (_loaded.contains(id)) return true;
    try {
      final bytes = await _file(id).readAsBytes();
      validateFont(bytes);
      if (sha256.convert(bytes).toString() != id) {
        throw const FormatException('字体文件校验失败');
      }
      await _loader(find(id)!.family, bytes);
      _loaded.add(id);
      notifyListeners();
      return true;
    } catch (error) {
      LumeLog.warn('字体载入失败，使用系统字体：$error');
      return false;
    }
  }

  Future<UserFont> importFile(XFile file) async {
    if (![
      '.ttf',
      '.otf',
      '.ttc',
    ].contains(p.extension(file.name).toLowerCase())) {
      throw const FormatException('请选择 .ttf、.otf 或 .ttc 字体文件');
    }
    if (await file.length() > maxBytes) {
      throw const FormatException('字体文件不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    validateFont(bytes);
    await boot();
    final id = sha256.convert(bytes).toString();
    final existing = find(id);
    if (existing != null) {
      if (!await ensureLoaded(id)) throw const FormatException('此字体暂时无法载入');
      return existing;
    }
    final name = p.basenameWithoutExtension(file.name);
    final font = UserFont(
      id,
      name.length > 150 ? name.substring(0, 150) : name,
    );
    await _loader(font.family, bytes);
    _directory!.createSync(recursive: true);
    final target = _file(id);
    target.writeAsBytesSync(bytes, flush: true);
    try {
      _save([..._fonts, font]);
    } catch (_) {
      target.deleteSync();
      rethrow;
    }
    _fonts.add(font);
    _loaded.add(id);
    notifyListeners();
    return font;
  }

  void _save(List<UserFont> fonts) {
    final index = File(p.join(_directory!.path, 'index.json'));
    final temp = File('${index.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode([
        for (final font in fonts) {'id': font.id, 'name': font.name},
      ]),
      flush: true,
    );
    temp.renameSync(index.path);
  }

  Future<void> remove(String id) async {
    if (find(id) == null) return;
    final next = _fonts.where((font) => font.id != id).toList();
    _save(next);
    _fonts = next;
    _loaded.remove(id);
    try {
      await _file(id).delete();
    } catch (error) {
      LumeLog.warn('字体文件清理失败：$error');
    }
    notifyListeners();
  }

  /// Validate SFNT directories, including TTC offsets, before passing bytes to
  /// the native font decoder. This rejects renamed images and truncated tables.
  @visibleForTesting
  static void validateFont(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > maxBytes) {
      throw const FormatException('字体文件大小无效');
    }
    final data = ByteData.sublistView(bytes);
    final offsets = <int>[];
    if (data.getUint32(0) == 0x74746366) {
      // ttcf
      final count = data.getUint32(8);
      if (count < 1 || count > 64 || 12 + count * 4 > bytes.length) {
        throw const FormatException('字体集合已损坏');
      }
      for (var i = 0; i < count; i++) {
        offsets.add(data.getUint32(12 + i * 4));
      }
    } else {
      offsets.add(0);
    }
    for (final offset in offsets) {
      if (offset + 12 > bytes.length) throw const FormatException('字体目录已截断');
      final tag = data.getUint32(offset);
      if (![0x00010000, 0x4F54544F, 0x74727565].contains(tag)) {
        throw const FormatException('无法识别此字体格式');
      }
      final count = data.getUint16(offset + 4);
      if (count < 1 ||
          count > 4096 ||
          offset + 12 + count * 16 > bytes.length) {
        throw const FormatException('字体数据表已损坏');
      }
      final tables = <int>{};
      for (var i = 0; i < count; i++) {
        final record = offset + 12 + i * 16;
        final start = data.getUint32(record + 8),
            size = data.getUint32(record + 12);
        if (start > bytes.length || size > bytes.length - start) {
          throw const FormatException('字体数据不完整');
        }
        tables.add(data.getUint32(record));
      }
      if (!tables.contains(0x636D6170) ||
          !tables.any([0x676C7966, 0x43464620, 0x43464632].contains)) {
        throw const FormatException('字体缺少字形或字符映射');
      }
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _booting = null;
    _directory = null;
    _fonts = [];
    _loaded.clear();
  }
}
