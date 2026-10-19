import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'icon_catalog.dart';

class IconChoice {
  const IconChoice(this.id, {this.tint = false});
  final String id;
  final bool tint;
  Map<String, Object?> toJson() => {'id': id, 'tint': tint};
  static IconChoice? parse(Object? value) =>
      value is Map && value['id'] is String
      ? IconChoice(value['id'] as String, tint: value['tint'] == true)
      : null;
}

class UserIconImage {
  const UserIconImage(this.id, this.name, this.bytes);
  final String id, name;
  final Uint8List bytes;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'png': base64Encode(bytes),
  };
}

/// One shared registry for both player layouts and every application icon.
/// All glyphs resolve through const catalog entries, preserving release tree shaking.
class IconCustomization extends ChangeNotifier {
  IconCustomization();
  static final instance = IconCustomization();
  static const maxPackBytes = 16 * 1024 * 1024;
  static const maxImages = 128;
  static const maxOverrides = 3000;
  static final _catalog = {
    for (final slot in iconSlots) slot.id: slot,
    for (final entry in playerControlDefaults.entries)
      _variantKey('player.stroke', entry.value): IconSlot(
        _variantKey('player.stroke', entry.value),
        '视频播放器',
        '全屏 · ${entry.key}',
        entry.value,
      ),
  };
  static final _glyphs = {
    for (final entry in builtInIcons) entry.id: entry.icon,
  };
  final Map<String, IconChoice> _overrides = {};
  final Map<String, UserIconImage> _images = {};
  final Map<String, IconSlot> _seen = {};
  final Map<String, IconChoice?> _pendingChoices = {};
  bool _loaded = false, _resetBeforeBoot = false;
  bool editMode = false;
  Directory? _directory;
  Future<void>? _booting;
  Future<void> _writes = Future.value();
  List<UserIconImage> get images => List.unmodifiable(_images.values);
  Map<String, IconChoice> get overrides => Map.unmodifiable(_overrides);
  Iterable<IconSlot> get slots => [
    ..._catalog.values.where((s) => !_seen.containsKey(s.id)),
    ..._seen.values,
  ];

  Future<void> boot() => _booting ??= _boot();
  Future<void> _boot() async {
    try {
      _directory = await getApplicationSupportDirectory();
      final file = File(p.join(_directory!.path, 'custom_icons.json'));
      if (file.existsSync() && file.lengthSync() <= maxPackBytes) {
        _load(jsonDecode(await file.readAsString()), merge: false);
      }
    } catch (_) {
      // Damaged optional personalization must not prevent app startup.
    }
    if (_resetBeforeBoot) _overrides.clear();
    for (final entry in _pendingChoices.entries) {
      if (entry.value == null) {
        _overrides.remove(entry.key);
      } else {
        _overrides[entry.key] = entry.value!;
      }
    }
    _pendingChoices.clear();
    _loaded = true;
    notifyListeners();
  }

  static String _variantKey(String base, IconData icon) =>
      '$base@${icon.fontFamily}.${icon.codePoint.toRadixString(16)}';
  String slotKey(String base, IconData? icon, bool variant) =>
      variant && icon != null ? _variantKey(base, icon) : base;
  void seen(String id, IconData? original, {String? label, String? group}) {
    if (original == null) return;
    final base = id.split('@').first;
    final known = _catalog[id] ?? _catalog[base];
    _seen[id] = IconSlot(
      id,
      group ?? known?.group ?? '通用控件',
      label ?? known?.name ?? id,
      original,
      dynamic: known?.dynamic ?? false,
    );
  }

  IconChoice? choice(String id, [IconData? original]) =>
      _overrides[id] ??
      _overrides[id.split('@').first] ??
      (original == null
          ? null
          : _overrides['glyph:${original.fontFamily}:${original.codePoint}']);
  IconData? glyph(IconChoice? value) => _glyphs[value?.id];
  UserIconImage? image(IconChoice? value) => _images[value?.id];
  bool valid(IconChoice value) => glyph(value) != null || image(value) != null;

  void set(String id, IconChoice? value) {
    if (id.isEmpty || id.length > 300) {
      throw const FormatException('图标位置无效');
    }
    if (value != null && !valid(value)) throw const FormatException('这个图标不可用');
    if (value != null &&
        !_overrides.containsKey(id) &&
        _overrides.length >= maxOverrides) {
      throw const FormatException('最多更换 3000 项图标');
    }
    if (value == null) {
      _overrides.remove(id);
    } else {
      if (_images.isNotEmpty) {
        _checkPackSize({..._overrides, id: value}, _images);
      }
      _overrides[id] = value;
    }
    if (!_loaded) _pendingChoices[id] = value;
    _save();
    notifyListeners();
  }

  void setEditMode(bool enabled) {
    editMode = enabled;
    // Editing mode is deliberately session-only; relaunching restores normal gestures.
    notifyListeners();
  }

  void resetAll() {
    _overrides.clear();
    if (!_loaded) {
      _resetBeforeBoot = true;
      _pendingChoices.clear();
    }
    _save();
    notifyListeners();
  }

  void deleteImage(String id) {
    _images.remove(id);
    _overrides.removeWhere((_, value) => value.id == id);
    _save();
    notifyListeners();
  }

  Future<UserIconImage> importImage(XFile file) async {
    await boot();
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('图片请小于 8 MB');
    }
    final input = await file.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(input);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 24000000) {
        throw const FormatException('图片尺寸过大，请裁剪后导入');
      }
      final longest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final ratio = (256 / longest).clamp(0.0, 1.0);
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * ratio).round().clamp(1, 256),
        targetHeight: (descriptor.height * ratio).round().clamp(1, 256),
      );
      frame = (await codec.getNextFrame()).image;
      final data = await frame.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法读取这张图片');
      final bytes = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final id = 'image:${sha256.convert(bytes)}';
      if (!_images.containsKey(id) && _images.length >= maxImages) {
        throw const FormatException('最多保存 128 张自定义图标');
      }
      var name = p.basenameWithoutExtension(file.name);
      if (name.isEmpty) name = '自定义图标';
      final result = UserIconImage(
        id,
        name.substring(0, name.length.clamp(0, 80)),
        bytes,
      );
      _checkPackSize(_overrides, {..._images, id: result});
      _images[id] = result;
      await _save();
      notifyListeners();
      return result;
    } finally {
      frame?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Map<String, Object?> _data(
    Map<String, IconChoice> overrides,
    Map<String, UserIconImage> images,
  ) => {
    'format': 'lumebox-icons',
    'version': 1,
    'overrides': {for (final e in overrides.entries) e.key: e.value.toJson()},
    'images': images.values.map((e) => e.toJson()).toList(),
  };
  String exportPack() => jsonEncode(_data(_overrides, _images));
  void _checkPackSize(
    Map<String, IconChoice> overrides,
    Map<String, UserIconImage> images,
  ) {
    if (utf8.encode(jsonEncode(_data(overrides, images))).length >
        maxPackBytes) {
      throw const FormatException('图标包总大小超过 16 MB，请先删除部分图片');
    }
  }

  Future<void> importPack(String text) async {
    if (utf8.encode(text).length > maxPackBytes) {
      throw const FormatException('图标包请小于 16 MB');
    }
    final raw = jsonDecode(text);
    if (raw is! Map ||
        raw['format'] != 'lumebox-icons' ||
        raw['version'] != 1) {
      throw const FormatException('请选择 LumeBox 图标包');
    }
    await boot();
    _load(raw, merge: true);
    await _save();
    notifyListeners();
  }

  void _load(Object? raw, {required bool merge}) {
    if (raw is! Map ||
        raw['format'] != 'lumebox-icons' ||
        raw['version'] != 1 ||
        raw['overrides'] is! Map ||
        raw['images'] is! List) {
      throw const FormatException('图标包内容不完整');
    }
    final images = <String, UserIconImage>{};
    if ((raw['images'] as List).length > maxImages ||
        (raw['overrides'] as Map).length > maxOverrides) {
      throw const FormatException('图标包内容过多');
    }
    for (final item in raw['images'] as List) {
      if (item is! Map || item['png'] is! String || item['name'] is! String) {
        throw const FormatException('图片信息无效');
      }
      final bytes = base64Decode(item['png'] as String);
      if (bytes.length > 1024 * 1024 ||
          bytes.length < 24 ||
          !listEquals(bytes.take(8).toList(), [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ])) {
        throw const FormatException('图片格式无效');
      }
      final header = ByteData.sublistView(bytes);
      if (header.getUint32(16) > 256 ||
          header.getUint32(20) > 256 ||
          header.getUint32(16) == 0 ||
          header.getUint32(20) == 0) {
        throw const FormatException('图标包图片请使用 256 像素以内的 PNG');
      }
      final id = 'image:${sha256.convert(bytes)}';
      if (item['id'] != id) throw const FormatException('图标包图片校验失败');
      final name = item['name'] as String;
      images[id] = UserIconImage(
        id,
        name.length > 80 ? name.substring(0, 80) : name,
        bytes,
      );
    }
    final mergedImages = <String, UserIconImage>{
      if (merge) ..._images,
      ...images,
    };
    if (mergedImages.length > maxImages) {
      throw const FormatException('合并后超过 128 张图片');
    }
    final overrides = <String, IconChoice>{};
    for (final e in (raw['overrides'] as Map).entries) {
      final value = IconChoice.parse(e.value);
      if (e.key is! String ||
          (e.key as String).isEmpty ||
          (e.key as String).length > 300 ||
          value == null ||
          (!mergedImages.containsKey(value.id) &&
              !builtInIcons.any((i) => i.id == value.id))) {
        throw const FormatException('图标包含有不可用的图标');
      }
      overrides[e.key as String] = value;
    }
    final mergedOverrides = {if (merge) ..._overrides, ...overrides};
    if (mergedOverrides.length > maxOverrides) {
      throw const FormatException('合并后超过 3000 项图标');
    }
    _checkPackSize(mergedOverrides, mergedImages);
    _images
      ..clear()
      ..addAll(mergedImages);
    _overrides
      ..clear()
      ..addAll(mergedOverrides);
  }

  Future<void> _save() {
    _writes = _writes.catchError((_) {}).then((_) async {
      await boot();
      final directory = _directory;
      if (directory == null) return;
      final content = exportPack();
      final temp = File(p.join(directory.path, 'custom_icons.json.tmp'));
      await temp.writeAsString(content, flush: true);
      await temp.rename(p.join(directory.path, 'custom_icons.json'));
    });
    unawaited(_writes.catchError((_) {}));
    return _writes;
  }

  Future<void> flush() => _writes;

  @visibleForTesting
  Future<void> resetForTesting() async {
    await _writes.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _directory = null;
    _booting = null;
    _writes = Future.value();
    _images.clear();
    _overrides.clear();
    _seen.clear();
    _pendingChoices.clear();
    _loaded = false;
    _resetBeforeBoot = false;
    editMode = false;
    notifyListeners();
  }
}
