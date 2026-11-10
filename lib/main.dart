import 'core/source/reading_section_migration.dart';
import 'core/util/frame_profile.dart';
import 'features/comic/comic_download_center.dart';
import 'core/session/startup_gate.dart';
import 'core/media/media_library.dart';
import 'core/tmdb/tmdb.dart';
import 'core/cache/media_preload.dart';
import 'core/player/video_disk_cache.dart';
import 'core/session/app_preferences.dart';
import 'core/session/configuration_backup.dart';
import 'core/search/search_settings.dart';
import 'core/source/source_content_visibility.dart';
import 'core/theme/floating_modules.dart';
import 'core/theme/frosted_settings.dart';
import 'core/reading/comic_image_tools.dart';
import 'core/session/privacy_settings.dart';
import 'core/session/retired_module_cache.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/js/sandbox_settings.dart';
import 'core/player/playback_orientation.dart';
import 'core/reading/browse_layout.dart';
import 'core/shell/shell_settings.dart';
import 'core/theme/appearance.dart';
import 'core/theme/user_fonts.dart';
import 'core/net/lume_net.dart';
import 'core/util/developer_mode.dart';
import 'core/util/lume_log.dart';

void main() {
  runZonedGuarded<void>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      if (const bool.fromEnvironment('LUME_PROFILE_STARTUP')) {
        FrameProfile.instance.start(
          '冷启动',
          refreshRate: WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .first
              .display
              .refreshRate,
        );
      }
      await LumeLog.startPersistence()
          .timeout(const Duration(seconds: 3))
          .catchError((Object _) {});
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        LumeLog.error(details.exception, details.stack);
        unawaited(LumeLog.flushPersistence());
      };
      runApp(
        StartupGate(
          initialize: () async {
            await ReadingSectionMigration.run();
            final issues = await initializeAppTasks([
              StartupTask('应用偏好', () => AppPreferences.instance.boot()),
              StartupTask(
                '隐私保护',
                () => PrivacySettings.instance.boot(),
                required: true,
              ),
              StartupTask('媒体库', () => MediaLibrary.instance.boot()),
              StartupTask('网络', () => LumeNet.boot()),
              StartupTask('源运行设置', () => LumeSandboxSettings.boot()),
              StartupTask('开发设置', () => DeveloperMode.boot()),
              StartupTask('浏览布局', () => BrowseLayoutSettings.instance.boot()),
              StartupTask(
                '播放方向',
                () => PlaybackOrientationController.instance.boot(),
              ),
              StartupTask('导航', () => ShellSettingsController.instance.boot()),
              StartupTask(
                '内容分类',
                () => SourceContentVisibility.instance.boot(),
              ),
              StartupTask('搜索', () => SearchSettings.instance.boot()),
              StartupTask('影视资料', () => TmdbSettings.instance.boot()),
              StartupTask('预载缓存', () => MediaPreload.instance.boot()),
              StartupTask('视频磁盘缓存', () => VideoDiskCache.instance.boot()),
              StartupTask('外观', () => AppearanceController.instance.boot()),
              StartupTask('悬浮模块', () => FloatingModules.instance.boot()),
              StartupTask('玻璃材质', () => FrostedSettings.instance.boot()),
              StartupTask(
                '图片工具',
                () => ComicImageToolsSettings.instance.boot(),
              ),
            ]);
            return issues;
          },
          child: const LumeBoxApp(),
          onReady: () {
            if (const bool.fromEnvironment('LUME_PROFILE_STARTUP')) {
              FrameProfile.instance.mark('startupReady');
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => FrameProfile.instance.mark('firstContentFrame'),
              );
              Future<void>.delayed(const Duration(seconds: 3), () {
                if (FrameProfile.instance.recording) {
                  FrameProfile.instance.stop();
                  unawaited(FrameProfile.instance.save());
                }
              });
            }
            unawaited(_deferredStartup());
            unawaited(_startupMaintenance());
          },
        ),
      );
    },
    (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      unawaited(LumeLog.flushPersistence());
    },
  );
}

Future<void> _startupMaintenance() async {
  // Leave first-screen source/cover loading time before disk maintenance.
  await Future<void>.delayed(const Duration(seconds: 20));
  try {
    await clearRetiredModuleCache();
  } catch (error, stack) {
    LumeLog.error(error, stack);
  }
  if (AppPreferences.instance.autoBackup) {
    try {
      await ConfigurationBackup().automatic();
    } catch (error) {
      LumeLog.warn('自动备份失败：$error');
    }
  } else {
    try {
      await ConfigurationBackup().protectExistingSnapshots();
    } catch (error) {
      LumeLog.warn('旧备份加密迁移失败：$error');
    }
  }
}

Future<void> _deferredStartup() async {
  // First content paints with system fonts; custom fonts notify the app when ready.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final issues = await initializeAppTasks([
    StartupTask('下载任务', () => ComicDownloadCenter.instance.boot()),
    StartupTask('自定义字体', () async {
      await UserFonts.instance.boot();
      await UserFonts.instance.ensureLoaded(
        AppearanceController.instance.settings.fontId,
      );
    }),
  ]);
  for (final issue in issues) {
    LumeLog.warn('后台初始化未完成：${issue.name}，可在对应页面重试');
  }
}
