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
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // 全局网络设置（并发 / UA / 代理 / 重试）：读一次落盘值，读不到就用默认，
      // 不阻断启动。四个板块的所有请求共用这一份额度（文档第六条）。
      // 这三项只影响**行为**、不影响首帧长相，因此不 await：让启动尽早出画面。
      unawaited(LumeNet.boot());
      unawaited(LumeSandboxSettings.boot());
      unawaited(DeveloperMode.boot());
      // 壳层设置（底部导航栏逐项开关 + 顺序）：这一项**必须 await**。
      // 它决定首帧的导航栏长什么样——不等的话，用户会先看到一份「全部显示、
      // 规范顺序」的默认导航栏，读盘完成后再跳成自己的配置（隐藏过的页签
      // 一闪而过）。多等一次本地读盘（几毫秒）换首帧即正确，是笔划算的账。
      // `boot` 内部已吞掉读盘异常（失败回默认），因此这里不会因它启动失败。
      await ShellSettingsController.instance.boot();
      runApp(const LumeBoxApp());
    },
    (error, stackTrace) => LumeLog.error(error, stackTrace),
  );
}
