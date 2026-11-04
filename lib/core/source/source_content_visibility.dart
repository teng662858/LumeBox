import 'dart:convert';
import 'dart:io';

import '../session/privacy_settings.dart';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../session/section.dart';
import '../util/lume_log.dart';
import 'source.dart';
import 'source_picker_groups.dart';
import 'source_content_category.dart';

/// Only source-drawer visibility; it never changes enabled sources or search scope.
class SourceContentVisibility extends ChangeNotifier {
  SourceContentVisibility();
  static final instance = SourceContentVisibility();
  static const types = [
    ('comic', '漫画', '漫画作品'),
    ('photo', '美图', '网络美图与写真图库'),
    ('novel', '小说', '文字小说与章节阅读'),
    ('audiobook', '有声', '有声小说与听书'),
    ('kazumi', 'Kazumi', '动漫规则源'),
    ('video', '视频', '网络小视频及现有泛视频源'),
    ('movie', '影视', '网络影视站'),
    ('tvbox', 'TVBOX', 'TVBox 导入的采集接口、Python 和直播列表'),
    ('js', 'JS 源', '视频抽屉中的 JavaScript 源'),
    ('python', 'PY 源', '视频抽屉中的 Python 源'),
    ('module', '模块源', '视频抽屉中的 ESM 与 CommonJS 模块源'),
    ('cat', '猫源', '视频抽屉中的猫源订阅及站点'),
    ('web', '网页主页', '视频抽屉中的网页主页和本地 HTML'),
  ];
  final Set<String> _hidden = {};
  File? _file;
  bool isVisible(String id) => !_hidden.contains(id);
  List<(String, String)> groups(Section section) =>
      SourcePickerGroups.forSection(section)
          .where((group) => isVisible(group.$1))
          .toList();
  bool sectionVisible(Section section) => groups(section).isNotEmpty;
  bool videoTypeVisible(String type) => switch (type) {
    'all' || 'audio' || 'kazumi' => true,
    'ordinary' => isVisible('js'),
    _ => isVisible(type),
  };
  bool videoRuntimeVisible(SourceDescriptor source) => isVisible(
    source.isTvBox
        ? 'tvbox'
        : switch (source.runtimeKind) {
            'python' => 'python',
            'module' => 'module',
            _ => 'js',
          },
  );
  bool allows(Section section, SourceDescriptor source) =>
      isVisible(SourcePickerGroups.groupFor(section, source)) &&
      (section != Section.video || videoRuntimeVisible(source)) &&
      PrivacySettings.instance.allowsSource(source.id, source.name) &&
      (section != Section.video ||
          !SourceContentCategories.appliesTo(source) ||
          PrivacySettings.instance.showAdult ||
          (source.contentCategory != 'adult' &&
              source.group != '成人' &&
              SourceContentCategories.forSource(source) !=
                  SourceContentCategory.adult));
  Future<void> boot({File? file}) async {
    try {
      _file =
          file ??
          File(
            '${(await getApplicationSupportDirectory()).path}/source_content_visibility.json',
          );
      _hidden.clear();
      if (_file!.existsSync()) {
        final data = jsonDecode(_file!.readAsStringSync());
        if (data is List) {
          _hidden.addAll(
            data.whereType<String>().where(
              (id) => types.any((type) => type.$1 == id),
            ),
          );
        }
      }
      notifyListeners();
    } catch (error) {
      LumeLog.warn('内容分类显示设置读取失败：$error');
    }
  }

  void setVisible(String id, bool visible) {
    if (!types.any((type) => type.$1 == id)) return;
    if (visible) {
      _hidden.remove(id);
    } else {
      _hidden.add(id);
    }
    try {
      final file = _file;
      if (file != null) {
        file.parent.createSync(recursive: true);
        final temporary = File('${file.path}.tmp');
        temporary.writeAsStringSync(jsonEncode(_hidden.toList()), flush: true);
        temporary.renameSync(file.path);
      }
    } catch (error) {
      LumeLog.warn('内容分类显示设置保存失败：$error');
    }
    notifyListeners();
  }
}
