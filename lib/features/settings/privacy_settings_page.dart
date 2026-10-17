import 'package:flutter/material.dart';

import '../../core/session/privacy_settings.dart';
import '../../shared/widgets/glass_card.dart';

class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({super.key, this.settings});
  final PrivacySettings? settings;
  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  PrivacySettings get settings => widget.settings ?? PrivacySettings.instance;
  bool busy = false;
  String? message;
  Future<void> run(Future<Object?> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await action();
      if (mounted && result == false) setState(() => message = '验证未完成，设置未更改');
    } catch (_) {
      if (mounted) setState(() => message = '设置未更改，请检查系统锁屏密码、面容权限与设备支持');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '隐私',
    child: ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile.adaptive(
            title: const Text('应用锁'),
            subtitle: const Text('启动及返回前台时验证，后台遮挡应用画面'),
            value: settings.appLock,
            onChanged: busy ? null : (v) => run(() => settings.setAppLock(v)),
          ),
          ListTile(
            title: const Text('解锁方式'),
            trailing: DropdownButton<AppUnlockMethod>(
              value: settings.method,
              items: [
                for (final method in AppUnlockMethod.values)
                  DropdownMenuItem(value: method, child: Text(method.label)),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      if (v != null) run(() => settings.setMethod(v));
                    },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '使用系统面容或本机锁屏密码，不设置额外 App 密码。启用、关闭及更换方式前需要验证。面容不可用时，可在锁定页使用锁屏密码。',
            ),
          ),
          const Divider(),
          SwitchListTile.adaptive(
            title: const Text('显示成人内容'),
            subtitle: const Text('显示已标记为 18+ 的源及对应收藏、历史；关闭只隐藏，不删除数据'),
            value: settings.showAdult,
            onChanged: busy ? null : (v) => run(() => settings.setShowAdult(v)),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('默认关闭。按已有成人源标记及仓库 NSFW 标记过滤，无法保证识别尚未标记的内容。'),
          ),
          if (busy) const Center(child: CircularProgressIndicator()),
          if (message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(message!)),
        ],
      ),
    ),
  );
}
