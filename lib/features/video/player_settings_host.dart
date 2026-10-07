import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/notice_card.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import 'danmaku/danmaku_settings.dart';
import 'player_settings_page.dart';
import 'video_player_settings.dart';

/// 播放器设置的独立入口（全局设置 → 播放器设置）。
///
/// 视频板块页面右上角只保留「图源管理」；播放器参数（内核 / 倍速 / 字幕）
/// 在这里改，落库仍写**视频板块自己的**设置库（与其他板块隔离）。
/// 改动在下次进入视频板块时生效（切 Tab 会重建该板块页面）。
class PlayerSettingsHost extends StatefulWidget {
  const PlayerSettingsHost({super.key, this.catalog, this.storeOpener});

  /// 内核可用性目录；为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 设置库打开端口（测试可注入）；为空时打开视频板块自己的库。
  final Future<VideoPlayerSettingsStore> Function()? storeOpener;

  @override
  State<PlayerSettingsHost> createState() => _PlayerSettingsHostState();
}

class _PlayerSettingsHostState extends State<PlayerSettingsHost> {
  VideoPlayerSettingsStore? _store;
  ReadingLibrary? _library;
  DanmakuSettings _danmaku = DanmakuSettings.defaults;
  PlayerSettings? _settings;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _store?.close();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final opener = widget.storeOpener ?? VideoPlayerSettingsStore.open;
      final store = await opener();
      if (!mounted) {
        store.close();
        return;
      }
      // 弹幕设置也在视频板块的库里：全局设置页要能直接改它（用户口径）。
      final library = await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      setState(() {
        _store = store;
        _settings = store.load();
        _library = library;
        _danmaku = DanmakuSettingsStore(library).load();
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _apply(PlayerSettings next) {
    _store?.save(next);
    setState(() => _settings = next);
  }

  /// 弹幕设置变更：上屏 + 落库（与播放页同一套口径）。
  void _applyDanmaku(DanmakuSettings next) {
    setState(() => _danmaku = next);
    final library = _library;
    if (library != null) DanmakuSettingsStore(library).save(next);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Scaffold(
        body: SafeArea(
          child: Center(
            child: NoticeCard(
              title: '播放器设置库不可用',
              subtitle: '视频板块的设置库打不开，请重启应用后重试',
            ),
          ),
        ),
      );
    }
    final settings = _settings;
    if (settings == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    return PlayerSettingsPage(
      settings: settings,
      catalog: widget.catalog ?? const PlatformPlayerKernelCatalog(),
      onChanged: _apply,
      danmaku: _danmaku,
      onDanmakuChanged: _applyDanmaku,
    );
  }
}
