import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/net/lume_net.dart';
import 'core/util/lume_log.dart';

void main() {
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // 全局网络设置（并发 / UA / 代理 / 重试）：读一次落盘值，读不到就用默认，
      // 不阻断启动。四个板块的所有请求共用这一份额度（文档第六条）。
      unawaited(LumeNet.boot());
      runApp(const LumeBoxApp());
    },
    (error, stackTrace) => LumeLog.error(error, stackTrace),
  );
}
