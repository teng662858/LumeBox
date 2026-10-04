import 'package:flutter/material.dart';

import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import 'player_kernel_picker.dart';
import 'video_player_settings.dart';

/// 播放内核区块（**故障逃生入口**）：全局设置页里内嵌的同一份内核选择列表。
///
/// 为什么内嵌而不只是跳页面：视频板块的内核切换在页面右上角，一旦该页因内核
/// 初始化出问题而卡住（或黑屏、菜单点不动），用户需要一个**点得最少**的退路。
/// 这一块直接读写**视频板块自己的**播放器设置库（`sections/video/`，与其他
/// 板块隔离），在设置页里当场就能把内核切回 AVPlayer；列表本身与视频板块的
/// 快捷菜单共用 [PlayerKernelPicker]，两处保证长得一模一样。
///
/// 隔离口径：只碰视频板块的设置库，不接触任何图源、缓存与其他板块数据。
class PlayerKernelSection extends StatefulWidget {
  const PlayerKernelSection({super.key, this.catalog, this.storeOpener});

  /// 内核可用性目录；为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 设置库打开端口（测试可注入）；为空时打开视频板块自己的库。
  final Future<VideoPlayerSettingsStore> Function()? storeOpener;

  @override
  State<PlayerKernelSection> createState() => _PlayerKernelSectionState();
}

class _PlayerKernelSectionState extends State<PlayerKernelSection> {
  late final PlayerKernelCatalog _catalog =
      widget.catalog ?? const PlatformPlayerKernelCatalog();

  VideoPlayerSettingsStore? _store;
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
      setState(() {
        _store = store;
        _settings = store.load();
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _select(PlayerKernel kernel) {
    final current = _settings;
    if (current == null || current.kernel == kernel) return;
    final next = current.copyWith(kernel: kernel);
    // 逃生入口只改内核：写回视频板块自己的库，其他项原样保留。
    _store?.save(next);
    setState(() => _settings = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${kernel.label}，进入视频板块后生效')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const NoticeCard(
        title: '播放器设置库不可用',
        subtitle: '视频板块的设置库打不开，请重启应用后重试',
      );
    }
    final settings = _settings;
    if (settings == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GlassCard(
          radius: 14,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const <Widget>[
              Text(
                '播放器内核 · 故障逃生入口',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '视频板块页面卡住、右上角快捷菜单点不动时，在这里当场切回 AVPlayer。'
                '内核初始化失败会自动回退并提示，失败的内核不会写进配置反复复现。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PlayerKernelPicker(
          selected: settings.kernel,
          catalog: _catalog,
          onChanged: _select,
        ),
      ],
    );
  }
}
