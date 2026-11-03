import '../../shared/widgets/video_glass_surface.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';
import '../../core/reading/reading.dart';
import '../reading/section_image.dart';

class TmdbDetailController extends ChangeNotifier {
  TmdbDetailController(
    this.title, {
    TmdbSettings? settings,
    TmdbClient? client,
    bool autoLoad = true,
    this.cacheIdentity,
    this.automaticRetryDelay = const Duration(seconds: 2),
  }) : settings = settings ?? TmdbSettings.instance {
    this.client = client ?? TmdbClient(this.settings);
    this.settings.addListener(refresh);
    if (autoLoad) unawaited(refresh());
    if (!autoLoad && cacheIdentity != null) unawaited(restoreCached());
  }

  /// Includes the source, item ID and listing title, never just a work title.
  final String? cacheIdentity;
  final Duration automaticRetryDelay;
  Timer? _retryTimer;
  int _automaticRetries = 0;
  String? get _identityKey => cacheIdentity == null
      ? null
      : jsonEncode(['source-item-v1', settings.cacheKey(''), cacheIdentity]);

  Future<void> restoreCached() async {
    final key = _identityKey;
    if (key == null || _closed || _started || !settings.configured) return;
    final revision = settings.revision;
    final result = await settings.cached(key);
    if (_closed ||
        _started ||
        settings.revision != revision ||
        !settings.configured ||
        result == null) {
      return;
    }
    metadata = result;
    final preferred = result.posters.indexOf(result.preferredPoster ?? '');
    index = preferred < 0 ? 0 : preferred;
    notifyListeners();
  }

  Future<void> _cacheIdentity(TmdbMetadata? result) async {
    final key = _identityKey;
    if (key != null) await settings.cache(key, result, waitForDisk: false);
  }

  String title;

  /// 列表标题与详情标题可能不一致（猫源尤其常见）；按顺序回退查询。
  List<String> _alternateTitles = const <String>[];

  final TmdbSettings settings;
  late final TmdbClient client;
  TmdbMetadata? metadata;
  int index = 0, _sequence = 0;
  bool _closed = false;
  bool loading = false;
  bool _started = false;
  String? _year, _mediaType;
  String? status;
  Future<void> rematch() => refresh(force: true);

  Future<void> selectPoster(String url) async {
    final current = metadata;
    if (_closed || current == null || !current.posters.contains(url)) return;
    _timer?.cancel();
    metadata = TmdbMetadata.fromJson({
      ...current.toJson(),
      'posters': [url, ...current.posters.where((poster) => poster != url)],
      'preferredPoster': url,
    });
    index = 0;
    notifyListeners();
    await settings.cache(
      settings.cacheKey(title, year: _year, mediaType: _mediaType),
      metadata,
    );
    await _cacheIdentity(metadata);
  }

  Future<bool> selectMatch(TmdbMatchCandidate candidate) async {
    if (_closed || !settings.configured) return false;
    _retryTimer?.cancel();
    final sequence = ++_sequence;
    _timer?.cancel();
    loading = true;
    status = null;
    notifyListeners();
    final result = await client.selectMatch(
      title,
      candidate,
      year: _year,
      mediaType: _mediaType,
    );
    if (_closed || sequence != _sequence || !settings.configured) return false;
    loading = false;
    if (result == null) {
      status = client.lastError ?? '未能获取所选条目，请重试';
      notifyListeners();
      return false;
    }
    metadata = result;
    index = 0;
    final count = result.posters.length;
    final preferred = result.posters.indexOf(result.preferredPoster ?? '');
    if (preferred >= 0) {
      index = preferred;
    } else if (count > 0 && settings.posterStyle == TmdbPosterStyle.random) {
      index = Random().nextInt(count);
    }
    if (preferred < 0 &&
        count > 1 &&
        settings.posterStyle == TmdbPosterStyle.carousel) {
      _timer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => show((index + 1) % count),
      );
    }
    notifyListeners();
    unawaited(_cacheIdentity(result));
    return true;
  }

  /// 用详情页拿到的标题再次匹配：列表标题可能带站点前缀/别名，而详情标题
  /// 才是视频模块里能命中的那个干净标题。多个候选按顺序回退，全部失败才
  /// 显示「未匹配」。
  void updateTitles(
    Iterable<String> values, {
    String? year,
    String? mediaType,
  }) {
    final unique = <String>[];
    for (final value in values) {
      final text = value.trim();
      if (text.isEmpty ||
          unique.any(
            (v) =>
                TmdbClient.normalized(TmdbClient.cleanTitle(v)) ==
                TmdbClient.normalized(TmdbClient.cleanTitle(text)),
          )) {
        continue;
      }
      unique.add(text);
    }
    if (_closed || unique.isEmpty) return;
    final samePrimary =
        TmdbClient.normalized(TmdbClient.cleanTitle(unique.first)) ==
        TmdbClient.normalized(TmdbClient.cleanTitle(title));
    final sameAlternates =
        unique.length - 1 == _alternateTitles.length &&
        <int>[
              for (var i = 1; i < unique.length; i++)
                if (unique[i] == _alternateTitles[i - 1]) i,
            ].length ==
            _alternateTitles.length;
    if (_started &&
        samePrimary &&
        sameAlternates &&
        _year == year &&
        _mediaType == mediaType) {
      return;
    }
    _year = year;
    _mediaType = mediaType;
    title = unique.first;
    _alternateTitles = unique.skip(1).toList(growable: false);
    unawaited(refresh());
  }

  Timer? _timer;
  Future<void> refresh({
    bool force = false,
    bool automaticRetry = false,
  }) async {
    _retryTimer?.cancel();
    if (!automaticRetry) _automaticRetries = 0;
    _started = true;
    final sequence = ++_sequence;
    _timer?.cancel();
    metadata = null;
    loading = settings.configured;
    status = null;
    index = 0;
    if (!_closed) notifyListeners();
    if (!settings.configured) return;
    if (force) await _cacheIdentity(null);
    if (_closed || sequence != _sequence || !settings.configured) return;
    TmdbMetadata? result;
    for (final candidate in <String>[title, ..._alternateTitles]) {
      result = await client.lookup(
        candidate,
        force: force,
        year: _year,
        mediaType: _mediaType,
      );
      if (_closed || sequence != _sequence || !settings.configured) return;
      if (result != null) break;
    }
    metadata = result;
    loading = false;
    status = result == null ? (client.lastError ?? '未匹配到 TMDB 资料，保留源信息') : null;
    final count = result?.posters.length ?? 0;
    final preferred =
        result?.posters.indexOf(result.preferredPoster ?? '') ?? -1;
    if (preferred >= 0) {
      index = preferred;
    } else if (count > 0 && settings.posterStyle == TmdbPosterStyle.random) {
      index = Random().nextInt(count);
    }
    if (preferred < 0 &&
        count > 1 &&
        settings.posterStyle == TmdbPosterStyle.carousel) {
      _timer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => show((index + 1) % count),
      );
    }
    notifyListeners();
    unawaited(_cacheIdentity(result));
    if (result == null && client.lastLookupRetryable && _automaticRetries < 1) {
      _automaticRetries++;
      status = '暂未取得 TMDB 资料，将自动重试一次';
      notifyListeners();
      _retryTimer = Timer(automaticRetryDelay, () {
        if (!_closed && sequence == _sequence && settings.configured) {
          unawaited(refresh(automaticRetry: true));
        }
      });
    }
  }

  void show(int value) {
    if (_closed || index == value) return;
    index = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _sequence++;
    _timer?.cancel();
    settings.removeListener(refresh);
    _retryTimer?.cancel();
    client.dispose();
    super.dispose();
  }
}

Future<void> showTmdbMatchPicker(
  BuildContext context,
  TmdbDetailController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _TmdbMatchPicker(controller: controller),
);

Future<void> showTmdbPosterPicker(
  BuildContext context,
  TmdbDetailController controller,
) async {
  final urls = controller.metadata?.posters ?? const <String>[];
  if (urls.isEmpty) return;
  final selected = await showGlassDialog<String>(
    context: context,
    videoGlass: true,
    builder: (context) => AlertDialog(
      title: const Text('选择海报'),
      content: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .6,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 2 / 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: urls.length,
          itemBuilder: (_, index) => InkWell(
            key: ValueKey('tmdb-poster-choice-$index'),
            onTap: () => Navigator.of(context).pop(urls[index]),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  urls[index],
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                ),
                if (index == controller.index)
                  const Positioned(
                    right: 4,
                    top: 4,
                    child: CircleAvatar(
                      radius: 14,
                      child: Icon(Icons.check, size: 18),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  if (selected != null) await controller.selectPoster(selected);
}

class _TmdbMatchPicker extends StatefulWidget {
  const _TmdbMatchPicker({required this.controller});
  final TmdbDetailController controller;
  @override
  State<_TmdbMatchPicker> createState() => _TmdbMatchPickerState();
}

class _TmdbMatchPickerState extends State<_TmdbMatchPicker> {
  late final query = TextEditingController(
    text: TmdbClient.cleanTitle(widget.controller.title),
  );
  List<TmdbMatchCandidate> candidates = [];
  bool busy = true;
  String? error;
  int sequence = 0;

  @override
  void initState() {
    super.initState();
    unawaited(search());
  }

  Future<void> search() async {
    final current = ++sequence;
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.controller.client.searchMatches(query.text);
    if (!mounted || current != sequence) return;
    setState(() {
      candidates = result;
      busy = false;
      error = widget.controller.client.lastError;
    });
  }

  Future<void> select(TmdbMatchCandidate candidate) async {
    setState(() {
      busy = true;
      error = null;
    });
    final applied = await widget.controller.selectMatch(candidate);
    if (!mounted) return;
    if (applied) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      busy = false;
      error = widget.controller.status ?? '配置已改变，请检查 TMDB 设置后重试';
    });
  }

  @override
  void dispose() {
    sequence++;
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => videoGlassDialogSurface(
    context,
    AlertDialog(
      title: const Text('选择 TMDB 条目'),
      content: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('按年份、类型和简介确认同名作品；也可以修改片名重新搜索。'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('tmdb-match-query'),
              controller: query,
              enabled: !busy,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => search(),
              decoration: InputDecoration(
                labelText: '片名',
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: busy ? null : search,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: busy
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                  ? Center(child: Text(error!))
                  : candidates.isEmpty
                  ? const Center(child: Text('未找到条目，请修改片名后搜索'))
                  : ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (_, index) {
                        final candidate = candidates[index];
                        return ListTile(
                          key: ValueKey(
                            'tmdb-match-${candidate.mediaType}-${candidate.id}',
                          ),
                          title: Text(candidate.title),
                          subtitle: Text(
                            '${candidate.label}${candidate.overview.isEmpty ? '' : '\n${candidate.overview}'}',
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => select(candidate),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

class TmdbPosterGallery extends StatefulWidget {
  const TmdbPosterGallery({
    super.key,
    required this.controller,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.onArtworkDisplayed,
    this.imagePipeline,
  });
  final TmdbDetailController controller;
  final Widget fallback;
  final BoxFit fit;
  final ValueChanged<String?>? onArtworkDisplayed;
  final SectionImagePipeline? imagePipeline;
  @override
  State<TmdbPosterGallery> createState() => _TmdbPosterGalleryState();
}

class _TmdbPosterGalleryState extends State<TmdbPosterGallery> {
  final pages = PageController();
  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  String? _reportedArtwork;
  bool _hasReported = false;
  void reportArtwork(String? url) {
    if (_hasReported && _reportedArtwork == url) return;
    _hasReported = true;
    _reportedArtwork = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedArtwork == url) {
        widget.onArtworkDisplayed?.call(url);
      }
    });
  }

  bool isCurrent(String url) {
    final urls = widget.controller.metadata?.posters ?? const <String>[];
    return urls.isNotEmpty &&
        urls[widget.controller.index.clamp(0, urls.length - 1)] == url;
  }

  Widget poster(String url) {
    final pipeline = widget.imagePipeline;
    if (pipeline != null) {
      return SectionImage(
        pipeline: pipeline,
        url: url,
        fit: widget.fit,
        targetWidth: 1600,
        placeholder: widget.fallback,
        onLoaded: () {
          if (isCurrent(url)) reportArtwork(url);
        },
        onFailed: () {
          if (isCurrent(url)) reportArtwork(null);
        },
      );
    }
    return Image.network(
      url,
      fit: widget.fit,
      filterQuality: FilterQuality.high,
      frameBuilder: (_, child, frame, synchronouslyLoaded) {
        if ((frame != null || synchronouslyLoaded) && isCurrent(url)) {
          reportArtwork(url);
        }
        return frame == null && !synchronouslyLoaded ? widget.fallback : child;
      },
      errorBuilder: (_, _, _) {
        if (isCurrent(url)) reportArtwork(null);
        return widget.fallback;
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final urls = state.metadata?.posters ?? const <String>[];
      if (!state.settings.enabled || urls.isEmpty) {
        reportArtwork(null);
        return widget.fallback;
      }
      if (state.settings.posterStyle != TmdbPosterStyle.carousel ||
          urls.length < 2) {
        return poster(urls[state.index.clamp(0, urls.length - 1)]);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            pages.hasClients &&
            (pages.page ?? 0).round() != state.index) {
          pages.animateToPage(
            state.index,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
          );
        }
      });
      return PageView.builder(
        key: const Key('tmdb-poster-carousel'),
        controller: pages,
        itemCount: urls.length,
        onPageChanged: state.show,
        itemBuilder: (_, index) => poster(urls[index]),
      );
    },
  );
}

class TmdbInformation extends StatelessWidget {
  const TmdbInformation({super.key, required this.controller});
  final TmdbDetailController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.settings.configured) return const SizedBox.shrink();
      final data = controller.metadata;
      Widget inset(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: child,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            inset(
              Text('TMDB 影片资料', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (controller.loading)
              inset(
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
              ),
            if (controller.status != null) inset(Text(controller.status!)),
            if (data != null) ...[
              inset(
                Text(
                  data.voteCount > 0
                      ? 'TMDB 评分 ${data.rating.toStringAsFixed(1)} / 10 · ${data.voteCount} 人评价'
                      : 'TMDB 暂无评分',
                ),
              ),
              if (data.cast.isNotEmpty) ...[
                const SizedBox(height: 8),
                inset(const Text('演员')),
                inset(
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: data.cast
                        .map((name) => Chip(label: Text(name)))
                        .toList(),
                  ),
                ),
              ],
              if (data.backdrops.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  key: const Key('tmdb-backdrop'),
                  height: 220,
                  width: double.infinity,
                  child: PageView(
                    children: [
                      for (final url in data.backdrops)
                        Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const Center(child: Text('背景图暂时无法加载')),
                        ),
                    ],
                  ),
                ),
              ],
              if (data.overview.isNotEmpty) ...[
                const SizedBox(height: 12),
                inset(const Text('TMDB 官方剧情简介')),
                inset(Text(data.overview)),
              ],
            ],
          ],
        ),
      );
    },
  );
}

class TmdbRematchMenu extends StatelessWidget {
  const TmdbRematchMenu({super.key, required this.controller});
  final TmdbDetailController controller;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '更多',
    onSelected: (_) => controller.rematch(),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'tmdb',
        enabled: controller.settings.configured && !controller.loading,
        child: const Text('重新匹配TMDB'),
      ),
    ],
  );
}

/// TMDB title artwork is separate from the poster; missing/failed logos keep the
/// real text title. Do not recolour the supplied PNG (green lettering stays green).
class TmdbTitleArtwork extends StatelessWidget {
  const TmdbTitleArtwork({
    super.key,
    required this.controller,
    required this.fallback,
  });
  final TmdbDetailController controller;
  final Widget fallback;
  @override
  Widget build(BuildContext context) {
    final logo = controller.settings.enabled
        ? controller.metadata?.logos
              .where(
                (url) => !Uri.parse(url).path.toLowerCase().endsWith('.svg'),
              )
              .firstOrNull
        : null;
    if (logo == null) return fallback;
    return Center(
      child: SizedBox(
        key: const Key('tmdb-title-artwork'),
        width: MediaQuery.sizeOf(context).width * .62,
        height: 76,
        child: Image.network(
          logo,
          fit: BoxFit.contain,
          cacheWidth: 900,
          filterQuality: FilterQuality.high,
          frameBuilder: (_, child, frame, sync) =>
              frame != null || sync ? child : Center(child: fallback),
          errorBuilder: (_, _, _) => Center(child: fallback),
        ),
      ),
    );
  }
}
