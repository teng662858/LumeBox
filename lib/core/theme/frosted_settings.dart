import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// Only the ordinary backdrop blur switch remains.
class FrostedSettings extends ChangeNotifier {
  FrostedSettings();
  static final instance = FrostedSettings();
  static const fileName = 'frosted_settings.json';
  bool _frostedEnabled = true;
  bool get frostedEnabled => _frostedEnabled;
  File? _file;
  Future<void> _pending = Future<void>.value();
  Future<void> boot({Directory? directory}) async {
    await _pending;
    _frostedEnabled = true;
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      _file = File('${base.path}/$fileName');
      final legacy = File('${base.path}/glass_effects_settings.json');
      final source = await _file!.exists() ? _file! : legacy;
      if (await source.exists()) {
        final data = jsonDecode(await source.readAsString());
        if (data is Map) _frostedEnabled = data['frostedEnabled'] != false;
      }
    } catch (error) {
      LumeLog.warn('毛玻璃设置读取失败：$error');
    }
    notifyListeners();
  }

  Future<void> setFrostedEnabled(bool value) {
    _frostedEnabled = value;
    notifyListeners();
    final contents = jsonEncode({'frostedEnabled': value});
    _pending = _pending.then((_) async {
      try {
        final base = _file == null
            ? await getApplicationSupportDirectory()
            : null;
        _file ??= File('${base!.path}/$fileName');
        await _file!.parent.create(recursive: true);
        final temp = File('${_file!.path}.tmp');
        await temp.writeAsString(contents, flush: true);
        await temp.rename(_file!.path);
      } catch (error) {
        LumeLog.warn('毛玻璃设置保存失败：$error');
      }
    });
    return _pending;
  }
}
