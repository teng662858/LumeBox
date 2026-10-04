import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/pip.dart';
import '../../core/player/pip_channel.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'player_settings_page.dart';
import 'video_player_settings.dart';

/// 自定义视频板块：播放本地或网络视频。
///
/// 播放内核只有 AVPlayer 可用（iOS，video_player 驱动）；MPV / MDK 尚未接入，
/// 设置页如实把它们标成不可选。Android / Windows 按宪法只保留 UI 骨架占位，
/// 画中画业务逻辑只在 iOS 侧接线（原生实现落地前，设置页与画中画按钮显示为占位）。
///
/// 播放设置（内核 / 倍速 / 字幕）落在本板块自己的库里；页面退出时按顺序释放：
/// 退出画中画 → 释放播放器 → 关闭库句柄。
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    this.playerFactory,
    this.catalog,
    this.pipBackend,
  });

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端。为空时按平台选择（iOS 走原生通道，其余平台如实降级）。
  final PipBackend? pipBackend;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final TextEditingController _input = TextEditingController();

  late final PlayerKernelCatalog _catalog =
      widget.catalog ?? const PlatformPlayerKernelCatalog();

  late final AbstractPlayer? Function(PlayerKernel) _createPlayer =
      widget.playerFactory ??
          (kernel) => PlayerFactory.create(kernel: kernel);

  VideoPlayerSettingsStore? _store;
  PlayerSettings _settings = const PlayerSettings();
  AbstractPlayer? _player;
  PipSession? _session;
  PlayerMedia? _media;

  /// 媒体是否已加载成功（画中画的就绪边界检查用它）。
  bool _loaded = false;

  String? _error;

  /// 设置库打不开：设置读写不可用，但播放链路继续（用默认设置）。
  bool _storeFailed = false;

  /// 本平台是否提供任一播放内核（没有就是骨架占位）。
  bool get _anyKernelAvailable =>
      PlayerKernel.values.any(_catalog.isAvailable);

  /// 设置里选的内核不可用时回退到第一个可用内核（库被改坏也不至于打不开）。
  PlayerKernel get _effectiveKernel {
    if (_catalog.isAvailable(_settings.kernel)) return _settings.kernel;
    return PlayerKernel.values.firstWhere(_catalog.isAvailable);
  }

  @override
  void initState() {
    super.initState();
    if (_anyKernelAvailable) _boot();
  }

  @override
  void dispose() {
    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    // 资源边界：先退画中画再释放播放器，最后关库（顺序不能反）。
    unawaited(() async {
      await session?.dispose();
      await player?.dispose();
    }());
    _store?.close();
    _input.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final store = await VideoPlayerSettingsStore.open();
      if (!mounted) {
        store.close();
        return;
      }
      _store = store;
      _settings = store.load();
    } catch (error, stackTrace) {
      // 本板块的库打不开：不起播放器，页面给出可读提示（与图源页同一口径）。
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _storeFailed = true);
      return;
    }
    if (!mounted) return;
    _session = PipSession(
      backend: widget.pipBackend ?? createPlatformPipBackend(),
      canEnter: () => _loaded && _player != null,
      onEvent: _onPipEvent,
    );
    await _rebuildPlayer();
  }

  /// 按当前设置创建播放器，并把媒体与播放位置接回去。
  ///
  /// 运行时切换内核与首次启动走同一条路：拆旧内核 → 建新内核 → 补挂设置 →
  /// 重新加载媒体 → 恢复位置与播放状态。
  Future<void> _rebuildPlayer() async {
    final previous = _player;
    final resume = previous == null ? null : _ResumePoint.of(previous);
    _player = null;
    if (previous != null) await previous.dispose();

    final player = _createPlayer(_effectiveKernel);
    if (!mounted) {
      await player?.dispose();
      return;
    }
    setState(() {
      _player = player;
      _loaded = false;
    });
    if (player == null) return;

    await player.applySettings(_settings);
    final media = _media;
    if (media == null) return;
    await _loadMedia(media);
    if (resume != null && !resume.isAtStart) {
      await player.seek(resume.position);
      if (resume.playing) await player.play();
    }
  }

  Future<void> _loadMedia(PlayerMedia media) async {
    final player = _player;
    if (player == null) return;
    _media = media;
    if (mounted) setState(() => _loaded = false);
    await player.load(media);
    if (!mounted) return;
    final failure = player.snapshot.value.error;
    setState(() {
      _loaded = failure == null;
      _error = failure;
    });
  }

  /// 设置变更：落库并立即生效；换内核走重建，其余项直接应用到当前内核。
  Future<void> _applySettings(PlayerSettings next) async {
    final kernelChanged = next.kernel != _settings.kernel;
    _store?.save(next);
    if (!mounted) return;
    setState(() => _settings = next);
    if (kernelChanged) {
      await _rebuildPlayer();
    } else {
      await _player?.applySettings(next);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerSettingsPage(
          settings: _settings,
          catalog: _catalog,
          onChanged: _applySettings,
        ),
      ),
    );
  }

  Uri? _resolve(String text) {
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    const networkSchemes = <String>{'http', 'https', 'file'};
    return networkSchemes.contains(parsed.scheme) ? parsed : Uri.file(text);
  }

  Future<void> _open() async {
    final player = _player;
    final text = _input.text.trim();
    if (player == null || text.isEmpty) return;
    final uri = _resolve(text);
    if (uri == null) {
      setState(() => _error = '地址无效');
      return;
    }
    setState(() => _error = null);
    await _loadMedia(PlayerMedia(uri: uri));
  }

  // ---------------------------------------------------------------- 画中画

  Future<void> _togglePip() async {
    final session = _session;
    if (session == null) return;
    final outcome = session.state == PipState.active
        ? await session.exit()
        : await session.enter();
    if (!mounted) return;
    final rejection = outcome.rejection;
    if (rejection != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rejection)),
      );
    }
  }

  /// 画中画事件回调：原生失败给可读提示，其余事件只记录。
  void _onPipEvent(PipEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case PipEventKind.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(event.message ?? '画中画失败')),
        );
      case PipEventKind.entered:
      case PipEventKind.exited:
      case PipEventKind.restored:
        LumeLog.info('[video] 画中画事件: ${event.kind.id}');
    }
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    if (!_anyKernelAvailable) {
      return GlassScaffold(
        title: Section.video.label,
        child: const _VideoSkeleton(),
      );
    }
    if (_storeFailed) {
      return GlassScaffold(
        title: Section.video.label,
        child: const Center(
          child: Text(
            '播放器设置库不可用',
            style: TextStyle(color: LumeTheme.muted),
          ),
        ),
      );
    }
    final player = _player;
    if (player == null) {
      return GlassScaffold(
        title: Section.video.label,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    return GlassScaffold(
      title: Section.video.label,
      actions: <Widget>[
        IconButton(
          tooltip: '播放器设置',
          icon: const Icon(Icons.tune),
          onPressed: _openSettings,
        ),
      ],
      child: Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: ValueListenableBuilder<PlayerSnapshot>(
                valueListenable: player.snapshot,
                builder: (context, snapshot, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: snapshot.error == null
                      ? player.buildView()
                      : Text(
                          snapshot.error!,
                          style: const TextStyle(color: LumeTheme.muted),
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: GlassCard(
              child: Column(
                children: <Widget>[
                  TextField(
                    controller: _input,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '视频地址或本地路径',
                      hintStyle: TextStyle(color: LumeTheme.muted),
                      icon: Icon(Icons.link, color: LumeTheme.muted),
                    ),
                    onSubmitted: (_) => _open(),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFF8A80),
                      ),
                    ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<PlayerSnapshot>(
                    valueListenable: player.snapshot,
                    builder: (context, snapshot, _) => Column(
                      children: <Widget>[
                        Slider(
                          value: _fraction(snapshot),
                          onChanged: snapshot.duration.inMilliseconds == 0
                              ? null
                              : (value) => player.seek(
                                    Duration(
                                      milliseconds:
                                          (snapshot.duration.inMilliseconds *
                                                  value)
                                              .round(),
                                    ),
                                  ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Text(
                              _format(snapshot.position),
                              style: const TextStyle(
                                fontSize: 12,
                                color: LumeTheme.muted,
                              ),
                            ),
                            Text(
                              _format(snapshot.duration),
                              style: const TextStyle(
                                fontSize: 12,
                                color: LumeTheme.muted,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            IconButton(
                              iconSize: 34,
                              color: Colors.white,
                              icon: Icon(
                                snapshot.playing
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                              ),
                              onPressed: () => snapshot.playing
                                  ? player.pause()
                                  : player.play(),
                            ),
                            IconButton(
                              iconSize: 28,
                              color: Colors.white,
                              icon: const Icon(Icons.stop_circle),
                              onPressed: player.stop,
                            ),
                            _buildPipButton(),
                            IconButton(
                              iconSize: 28,
                              color: Colors.white,
                              icon: const Icon(Icons.download),
                              onPressed: _open,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 画中画按钮：不可用时是禁用占位（平台不支持或原生实现未接入）。
  Widget _buildPipButton() {
    final session = _session;
    if (session == null) {
      return const IconButton(
        iconSize: 28,
        icon: Icon(Icons.picture_in_picture_alt),
        onPressed: null,
        tooltip: '画中画：正在准备',
      );
    }
    return ValueListenableBuilder<PipSnapshot>(
      valueListenable: session.snapshot,
      builder: (context, snapshot, _) {
        if (snapshot.state == PipState.unavailable) {
          return const IconButton(
            iconSize: 28,
            icon: Icon(Icons.picture_in_picture_alt),
            onPressed: null,
            tooltip: '画中画：iOS 专属（原生接入前仅占位）',
          );
        }
        final busy = snapshot.state == PipState.entering ||
            snapshot.state == PipState.exiting;
        return IconButton(
          iconSize: 28,
          color: Colors.white,
          icon: Icon(
            snapshot.isActive
                ? Icons.picture_in_picture
                : Icons.picture_in_picture_alt,
          ),
          onPressed: busy ? null : _togglePip,
          tooltip: snapshot.isActive ? '退出画中画' : '进入画中画',
        );
      },
    );
  }

  double _fraction(PlayerSnapshot snapshot) {
    final total = snapshot.duration.inMilliseconds;
    if (total <= 0) return 0;
    final value = snapshot.position.inMilliseconds / total;
    return value.clamp(0.0, 1.0);
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// 内核切换前记录的位置与播放状态（新内核加载完成后接回去）。
class _ResumePoint {
  const _ResumePoint({required this.position, required this.playing});

  final Duration position;
  final bool playing;

  bool get isAtStart => position == Duration.zero;

  static _ResumePoint of(AbstractPlayer player) {
    final snapshot = player.snapshot.value;
    return _ResumePoint(position: snapshot.position, playing: snapshot.playing);
  }
}

/// Android / Windows 的 UI 骨架占位：播放与画中画都不实现，只说明边界。
class _VideoSkeleton extends StatelessWidget {
  const _VideoSkeleton();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                LumeTheme.appName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '当前平台在 Phase1 仅保留页面骨架',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: LumeTheme.muted),
              ),
              const SizedBox(height: 8),
              const Text(
                '播放器设置与画中画为 iOS 专属模块：本平台仅 UI 骨架占位',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: LumeTheme.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
