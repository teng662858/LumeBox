import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/util/lume_log.dart';

void main() {
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      runApp(const LumeBoxApp());
    },
    (error, stackTrace) => LumeLog.error(error, stackTrace),
  );
}
