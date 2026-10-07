import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/js/sandbox_settings.dart';
import 'core/shell/shell_settings.dart';
import 'core/net/lume_net.dart';
import 'core/util/developer_mode.dart';
import 'core/util/lume_log.dart';

void main() {
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // 全局网络设置（并发 / UA / 代理 / 重试）：读一次落盘值，读不到就用默认，
      // 不阻断启动。四个板块的所有请求共用这一份额度（文档第六条）。
      unawaited(LumeNet.boot());
      // 全局沙箱设置（JS 超时，文档第 4 条点名项）：同样读一次落盘值，
      // 让首个图源引擎装配时用的就是用户设的值。
      unawaited(LumeSandboxSettings.boot());
      // 开发者模式（请求抓包开关）：读一次落盘值。抓包默认关闭，
      // 因此这里不会因为「忘了关」而在用户不知情时收集请求数据。
      unawaited(DeveloperMode.boot());
      // 壳层设置（底部导航栏开关）：读一次落盘值，避免启动时导航栏闪一下。
      unawaited(ShellSettingsController.instance.boot());
      runApp(const LumeBoxApp());
    },
    (error, stackTrace) => LumeLog.error(error, stackTrace),
  );
}
