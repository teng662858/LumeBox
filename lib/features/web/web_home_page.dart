import '../video/direct_video_source.dart';
import '../video/video_detail_page.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/player/player_experience_store.dart';
import '../../core/media/playback_focus.dart';
import '../../core/cat/cat_web_parse.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/web/web_home_sources.dart';
import '../../core/web/html_home_session.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';
import '../cat/cat_web_parse_page.dart';
import '../video/video_player_page.dart';

/// Opens a user-added web home page inside the app.
///
/// This is intentionally a pushed route, not a fourth home surface: leaving the
/// page (back button / edge swipe) returns to the video tab, and the WebView's
/// own history is kept while the page is open.
class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key, required this.source});

  final WebHomeSource source;

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  final WebViewController _controller = WebViewController();
  HtmlHomeSession? _session;
  bool _edge = false;
  bool? _lightStatus;
  bool _playRouteOpen = false;
  Map<String, dynamic> _viewport = {'chromeMode': 'normal'};
  String? _viewportSignature;
  int _progress = 0;
  String? _error;
  String _title = '';
  bool _ready = false;
  bool _booting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (_booting) return;
    _booting = true;
    try {
      final ua = PlayerExperienceStore.current.browserUA;
      if (ua.isNotEmpty) await _controller.setUserAgent(ua);
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _error = null);
          },
          onPageFinished: (_) async {
            try {
              final title = await _controller.getTitle();
              if (mounted && title != null && title.trim().isNotEmpty) {
                setState(() => _title = title.trim());
              }
              _publishViewport(force: true);
            } catch (_) {}
          },
          onWebResourceError: (failure) {
            if (mounted && failure.isForMainFrame == true) {
              setState(() => _error = '网页加载失败，请检查网络或地址后重试');
            }
          },
          onNavigationRequest: (request) async {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (const {
              'http',
              'https',
              'about',
              'data',
              'blob',
            }.contains(uri.scheme)) {
              return NavigationDecision.navigate;
            }
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('这个链接需要在其他应用里打开')));
            }
            return NavigationDecision.prevent;
          },
        ),
      );
      Uri? uri;
      if (widget.source.isLocal) {
        final store = await WebHomeStore.open();
        if (!mounted) return;
        final session = await HtmlHomeSession.start(
          source: widget.source,
          store: store,
          onPlay: _openPlayback,
          onChrome: _setChrome,
          viewport: _viewport,
        );
        if (!mounted) {
          await session.close();
          return;
        }
        _session = session;
        uri = session.page;
      } else {
        uri = widget.source.uri;
      }
      if (uri == null) {
        if (mounted) setState(() => _error = '主页地址无效');
        return;
      }
      await _controller.loadRequest(uri);
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '网页打开失败：$error';
          _progress = 100;
        });
      }
    } finally {
      _booting = false;
    }
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.close());
    super.dispose();
  }

  Future<Map<String, dynamic>> _setChrome(Map options) async {
    if (!mounted) throw StateError('网页已关闭');
    setState(() {
      _edge = options['mode'] == 'edge' || options['mode'] == 'immersive';
      _lightStatus = options['statusBarStyle'] == 'light'
          ? true
          : options['statusBarStyle'] == 'dark'
          ? false
          : null;
    });
    _measureViewport(
      Size(
        (_viewport['width'] as num?)?.toDouble() ?? 0,
        (_viewport['height'] as num?)?.toDouble() ?? 0,
      ),
    );
    return _viewport;
  }

  void _measureViewport(Size size) {
    final safe = MediaQuery.viewPaddingOf(context);
    _viewport = {
      'width': size.width,
      'height': size.height,
      'safeTop': _edge ? safe.top : 0.0,
      'safeBottom': _edge ? safe.bottom : 0.0,
      'safeLeft': safe.left,
      'safeRight': safe.right,
      'statusBarHeight': _edge ? safe.top : 0.0,
      'chromeMode': _edge ? 'edge' : 'normal',
    };
    _session?.viewport = _viewport;
  }

  void _publishViewport({bool force = false}) {
    if (!_ready || _session == null || !mounted) return;
    final signature = jsonEncode(_viewport);
    if (!force && signature == _viewportSignature) return;
    _viewportSignature = signature;
    unawaited(
      _controller
          .runJavaScript(
            'window.__lumeHomeViewport&&window.__lumeHomeViewport($signature);',
          )
          .catchError((_) {}),
    );
  }

  Future<void> _openPlayback(HtmlHomePlayback request) async {
    if (!mounted) throw StateError('网页已关闭');
    if (_playRouteOpen) throw StateError('请先关闭当前播放或解析页面');
    _playRouteOpen = true;
    // Resolve RPC when the route is handed off, not when a whole movie ends.
    unawaited(
      _play(request)
          .catchError((Object error) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('打开失败：$error')));
            }
          })
          .whenComplete(() => _playRouteOpen = false),
    );
  }

  Future<void> _play(HtmlHomePlayback request) async {
    var uri = request.uri;
    if (uri.scheme == 'magnet') {
      await showGlassDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('磁力链接'),
          content: const Text('当前播放器不能直接播放磁力链接，可复制到支持下载或离线播放的应用。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制链接'),
            ),
          ],
        ),
      );
      return;
    }
    if (request.shareLink && !CatMediaSniffer.isMediaUrl(uri.toString())) {
      if (request.password.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('提取码：${request.password}'),
            action: SnackBarAction(
              label: '复制',
              onPressed: () {
                unawaited(
                  Clipboard.setData(ClipboardData(text: request.password)),
                );
              },
            ),
          ),
        );
      }
      final result = await showCatWebParsePage(
        context,
        CatWebParseRequired(uri, request.headers),
      );
      if (result == null || !mounted) return;
      uri = result;
    }
    final library = await ReadingLibrary.open(Section.video);
    if (!mounted) return;
    final source = DirectVideoSource(
      id: 'web-${widget.source.id}',
      name: widget.source.name,
      title: request.title,
      uri: uri,
      headers: request.headers,
      episodes: [
        for (var i = 0; i < request.episodes.length; i++)
          SourceChapter(
            id: 'web-episode-$i',
            title: request.episodes[i].title,
            line: request.episodes[i].line,
          ),
      ],
      selected: request.selected,
      cover: request.cover,
      description: request.description,
      resolveEpisode: (index) async {
        final session = _session;
        if (session == null) throw StateError('网页会话已关闭');
        final resolved = await session.resolveEpisode(
          request.playlistId,
          index,
          _controller.runJavaScript,
        );
        if (resolved.shareLink && !CatMediaSniffer.isMediaUrl(resolved.uri.toString())) {
          throw const FormatException('该剧集需要回到网页打开网盘解析');
        }
        return VideoContent(url: resolved.uri, headers: resolved.headers);
      },
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoDetailPage(
          source: source,
          item: SourceItem(
            id: DirectVideoSource.captureItemId(request.itemId, request.uri),
            title: request.title,
            cover: request.cover,
          ),
          initialChapterId: request.episodes.isEmpty
              ? null
              : 'web-episode-${request.selected}',
          library: library,
          recordHistory: false,
          onPlay: (origin, media, target, qualities, prelaunch) async {
            final context = origin.context;
            final route = ModalRoute.of(context);
            await PlaybackFocus.acquire(
              'video',
              stillWanted: () => context.mounted && route?.isCurrent != false,
            );
            if (!context.mounted || route?.isCurrent == false) {
              await prelaunch?.discard();
              return;
            }
            final captured = identical(origin.source, source);
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => VideoPlayerPage(
                  media: media,
                  title: target.title,
                  source: origin.source,
                  target: captured && request.episodes.isEmpty ? null : target,
                  library: library,
                  qualities: qualities,
                  prelaunch: prelaunch,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _back() async {
    if (_ready && await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _reload() async {
    try {
      if (!_ready) {
        if (_session == null) {
          await _boot();
          return;
        }
        await _controller.loadRequest(_session!.page);
        if (mounted) setState(() => _ready = true);
      } else {
        await _controller.reload();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '网页重试失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.viewPaddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (_lightStatus ?? Theme.of(context).brightness == Brightness.dark)
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        appBar: _edge
            ? null
            : GlassAppBar(
                title: Text(_title.isEmpty ? widget.source.name : _title),
                leading: IconButton(
                  tooltip: '返回',
                  icon: const LumeIcon(Icons.arrow_back, slot: 'web_home.back'),
                  onPressed: _back,
                ),
                actions: [
                  IconButton(
                    tooltip: '刷新',
                    icon: const LumeIcon(
                      Icons.refresh,
                      slot: 'web_home.refresh',
                    ),
                    onPressed: _reload,
                  ),
                  IconButton(
                    tooltip: '关闭网页',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
        // Keep the WebView at the same element position when chrome changes.
        // Reparenting it between different Scaffold implementations can dispose
        // and recreate the native platform view while its controller is in use.
        body: SafeArea(
          top: false,
          bottom: !_edge,
          left: false,
          right: false,
          child: Stack(
            children: [
              Positioned.fill(child: _content()),
              if (_edge)
                Positioned(
                  top: safe.top + 6,
                  right: safe.right + 10,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface
                        .withValues(alpha: .85),
                    shape: const CircleBorder(),
                    child: PopupMenuButton<String>(
                      tooltip: '网页工具',
                      icon: const Icon(Icons.more_horiz),
                      onSelected: (value) {
                        if (value == 'back') {
                          unawaited(_back());
                        } else if (value == 'close') {
                          Navigator.of(context).maybePop();
                        } else {
                          unawaited(_setChrome({'mode': 'normal'}));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'back', child: Text('返回上一页')),
                        PopupMenuItem(value: 'toolbar', child: Text('显示工具栏')),
                        PopupMenuItem(value: 'close', child: Text('关闭网页')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() => Column(
    children: [
      if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                _error!,
                style: TextStyle(color: LumeTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      Expanded(
        child: _ready
            ? LayoutBuilder(
                builder: (context, constraints) {
                  _measureViewport(constraints.biggest);
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _publishViewport(),
                  );
                  return WebViewWidget(controller: _controller);
                },
              )
            : _error == null
            ? const Center(child: CircularProgressIndicator())
            : const SizedBox.shrink(),
      ),
    ],
  );
}
