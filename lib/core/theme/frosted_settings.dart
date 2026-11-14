import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';
import 'liquid_glass_style.dart';
import 'glass_modules.dart';
import 'native_glass_style.dart';
export 'native_glass_style.dart';
export 'liquid_glass_style.dart';

/// Persisted shared material, with module/part overrides and a solid fallback.
class FrostedSettings extends ChangeNotifier {
  FrostedSettings();
  static final instance = FrostedSettings();
  static const fileName = 'frosted_settings.json';
  bool _frostedEnabled = true;
  bool get frostedEnabled => _frostedEnabled;
  final Map<String, LiquidGlassStyle> _styles = {};
  bool lightweight = false;
  bool playerNative = false;
  static const defaultPlayerGlassShade = .12;
  double _playerGlassShade = defaultPlayerGlassShade;
  double get playerGlassShade => _playerGlassShade;
  Future<void> setPlayerGlassShade(double value, {bool persist = true}) {
    if (!value.isFinite) return Future<void>.value();
    _playerGlassShade = value.clamp(0, .5);
    notifyListeners();
    return persist ? save() : Future<void>.value();
  }

  Future<void> setPlayerNative(bool value) {
    playerNative = value;
    notifyListeners();
    return save();
  }

  bool _nativePreview = false;
  bool get nativePreview => _nativePreview;

  Future<void> setNativePreview(bool value) {
    _nativePreview = value;
    notifyListeners();
    return save();
  }

  bool _reduceTransparency = false;
  bool get reduceTransparency => _reduceTransparency || lightweight;
  set reduceTransparency(bool value) => _reduceTransparency = value;
  Future<void> setLightweight(bool value) {
    lightweight = value;
    notifyListeners();
    return save();
  }

  NativeGlassStyle native = const NativeGlassStyle();
  Future<void> setNative(NativeGlassStyle value, {bool persist = true}) {
    native = value;
    notifyListeners();
    return persist ? save() : Future<void>.value();
  }

  String _key(GlassModule module, GlassPart? part) =>
      '${module.name}:${part?.name ?? 'all'}';
  LiquidGlassStyle style(GlassModule module, GlassPart? part) =>
      _styles[_key(module, part)] ??
      _styles[_key(module, null)] ??
      _styles[_key(GlassModule.all, part)] ??
      _styles['all:all'] ??
      const LiquidGlassStyle();
  bool hasOverride(GlassModule module, GlassPart? part) =>
      _styles.containsKey(_key(module, part));
  Future<void> setStyle(
    GlassModule module,
    GlassPart? part,
    LiquidGlassStyle value, {
    bool persist = true,
  }) {
    _styles[_key(module, part)] = value;
    notifyListeners();
    return persist ? save() : Future<void>.value();
  }

  Future<void> resetStyle(GlassModule module, GlassPart? part) {
    _styles.remove(_key(module, part));
    notifyListeners();
    return save();
  }

  Future<void> setReduceTransparency(bool value) {
    reduceTransparency = value;
    notifyListeners();
    return save();
  }

  File? _file;
  Future<void> _pending = Future<void>.value();
  Future<void> boot({Directory? directory}) async {
    await _pending;
    _frostedEnabled = true;
    _styles.clear();
    reduceTransparency = false;
    lightweight = false;
    _nativePreview = false;
    playerNative = false;
    _playerGlassShade = defaultPlayerGlassShade;
    native = const NativeGlassStyle();
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      _file = File('${base.path}/$fileName');
      final legacy = File('${base.path}/glass_effects_settings.json');
      final source = await _file!.exists() ? _file! : legacy;
      if (await source.exists()) {
        final data = jsonDecode(await source.readAsString());
        if (data is Map) {
          _frostedEnabled = data['frostedEnabled'] != false;
          reduceTransparency = data['reduceTransparency'] == true;
          lightweight = data['lightweight'] == true;
          _nativePreview = data['nativePreview'] == true;
          playerNative = data['playerNative'] == true;
          final shade = data['playerGlassShade'];
          if (shade is num && shade.isFinite) {
            _playerGlassShade = shade.toDouble().clamp(0, .5);
          }
          if (data['native'] is Map) {
            native = NativeGlassStyle.fromJson(data['native'] as Map);
          }
          if (data['styles'] is Map) {
            for (final entry in (data['styles'] as Map).entries) {
              final valid = [
                for (final m in GlassModule.values)
                  for (final p in [
                    'all',
                    ...GlassPart.values.map((p) => p.name),
                  ])
                    '${m.name}:$p',
              ];
              if (valid.contains(entry.key) && entry.value is Map) {
                _styles['${entry.key}'] = LiquidGlassStyle.fromJson(
                  entry.value as Map,
                );
              }
            }
          }
        }
      }
    } catch (error) {
      LumeLog.warn('毛玻璃设置读取失败：$error');
    }
    notifyListeners();
  }

  Future<void> setFrostedEnabled(bool value) {
    _frostedEnabled = value;
    notifyListeners();
    return save();
  }

  Future<void> save() {
    final contents = jsonEncode({
      'frostedEnabled': _frostedEnabled,
      'reduceTransparency': _reduceTransparency,
      'lightweight': lightweight,
      'nativePreview': _nativePreview,
      'playerNative': playerNative,
      'playerGlassShade': playerGlassShade,
      'native': native.toJson(),
      'styles': {for (final e in _styles.entries) e.key: e.value.toJson()},
    });
    _pending = _pending.catchError((Object _) {}).then((_) async {
      try {
        _file ??= File(
          '${(await getApplicationSupportDirectory()).path}/$fileName',
        );
        await _file!.parent.create(recursive: true);
        final temp = File('${_file!.path}.tmp');
        await temp.writeAsString(contents, flush: true);
        await temp.rename(_file!.path);
      } catch (error) {
        LumeLog.warn('玻璃设置保存失败：$error');
      }
    });
    return _pending;
  }
}
