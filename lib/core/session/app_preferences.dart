import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum HapticStrength {
  light('轻柔'),
  medium('标准'),
  strong('强烈');

  const HapticStrength(this.label);
  final String label;
}

class AppPreferences {
  static final instance = AppPreferences();
  bool haptics = false, backgroundPlayback = true, autoBackup = false;
  static const maxSettingsShortcuts = 4;
  static const defaultSettingsShortcuts = ['appearance', 'sources', 'player'];
  List<String> settingsShortcuts = List.of(defaultSettingsShortcuts);
  HapticStrength hapticStrength = HapticStrength.medium;
  File? file;
  Future<void> boot() async {
    file = File(
      '${(await getApplicationSupportDirectory()).path}/app_preferences.json',
    );
    if (!file!.existsSync()) return;
    try {
      final data = jsonDecode(file!.readAsStringSync()) as Map;
      final shortcuts = data['settingsShortcuts'];
      settingsShortcuts = shortcuts is List
          ? shortcuts
                .whereType<String>()
                .toSet()
                .take(maxSettingsShortcuts)
                .toList()
          : List.of(defaultSettingsShortcuts);
      haptics = data['haptics'] == true;
      hapticStrength =
          HapticStrength.values
              .where((value) => value.name == data['hapticStrength'])
              .firstOrNull ??
          HapticStrength.medium;
      backgroundPlayback = data['backgroundPlayback'] != false;
      autoBackup = data['autoBackup'] == true;
    } catch (_) {
      /* Keep defaults for invalid local settings. */
    }
  }

  void save() {
    final target = file;
    if (target == null) return;
    target.parent.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'settingsShortcuts': settingsShortcuts,
        'haptics': haptics,
        'hapticStrength': hapticStrength.name,
        'backgroundPlayback': backgroundPlayback,
        'autoBackup': autoBackup,
      }),
      flush: true,
    );
    temp.renameSync(target.path);
  }

  Future<void> selectionFeedback() async {
    if (!haptics) return;
    switch (hapticStrength) {
      case HapticStrength.light:
        await HapticFeedback.lightImpact();
      case HapticStrength.medium:
        await HapticFeedback.mediumImpact();
      case HapticStrength.strong:
        await HapticFeedback.heavyImpact();
    }
  }
}
