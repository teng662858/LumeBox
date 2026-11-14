import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/music/lx_catalog.dart';
import '../../core/music/music_library.dart';
import '../../core/music/music_models.dart';
import '../../core/music/music_service.dart';
import '../../core/music/music_session.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/network_owned_state.dart';
import '../../core/net/network_cancellation.dart';
import '../shell/shell_dock.dart';

void _message(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$error')));

Future<String?> _input(
  BuildContext context,
  String title,
  String hint, {
  String initial = '',
}) async {
  return showDialog<String>(
    context: context,
    builder: (_) => _MusicInput(title: title, hint: hint, initial: initial),
  );
}

class _MusicInput extends StatefulWidget {
  const _MusicInput({
    required this.title,
    required this.hint,
    required this.initial,
  });
  final String title, hint, initial;
  @override
  State<_MusicInput> createState() => _MusicInputState();
}

class _MusicInputState extends State<_MusicInput> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('确定')),
    ],
  );
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage>
    with NetworkOwnedState<MusicPage> {
  final _library = MusicLibrary.instance;
  final _query = TextEditingController();
  int _tab = 0, _page = 1, _searchRevision = 0;
  bool _busy = false, _more = false, _ready = false, _searched = false;
  String? _error, _pluginId;
  final _tracks = <MusicTrack>[];
  List<String> _failures = [];
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _library.load();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '音乐库加载失败：$e');
    }
  }

  Future<void> _search({bool next = false}) async {
    if (_query.text.trim().isEmpty) return;
    final revision = ++_searchRevision;
    final page = next ? _page + 1 : 1;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _searched = true;
      _error = null;
      if (!next) _tracks.clear();
    });
    try {
      final result = await networkRequests.run(
        'music-search',
        () => MusicService.instance.search(
          _query.text.trim(),
          page: page,
          pluginId: _pluginId,
        ),
      );
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        final seen = _tracks.map((t) => t.key).toSet();
        _tracks.addAll(result.tracks.where((t) => seen.add(t.key)));
        _page = page;
        _more = result.hasMore;
        _failures = result.failures;
      });
    } catch (e) {
      if (e is! NetworkCancelled && mounted && revision == _searchRevision) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && revision == _searchRevision) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _library,
    builder: (context, _) => GlassScaffold(
      title: '音乐',
      actions: [
        IconButton(
          tooltip: '添加音乐源',
          onPressed: () => showMusicImport(context),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('找音乐'),
                  icon: Icon(Icons.explore_outlined),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('我的'),
                  icon: Icon(Icons.library_music_outlined),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text('音乐源'),
                  icon: Icon(Icons.extension_outlined),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (value) => setState(() => _tab = value.first),
            ),
          ),
          if (!_ready && _error == null) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
            child: switch (_tab) {
              0 => _discover(),
              1 => _mine(),
              _ => _sources(),
            },
          ),
        ],
      ),
    ),
  );
  Widget _discover() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '歌曲、歌手',
            prefixIcon: const Icon(Icons.music_note_outlined),
            suffixIcon: IconButton(
              tooltip: '搜索音乐',
              onPressed: () => _search(),
              icon: const Icon(Icons.search),
            ),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DropdownButton<String?>(
          isExpanded: true,
          value: _library.plugin(_pluginId ?? '') == null ? null : _pluginId,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('全部已启用音乐源'),
            ),
            for (final p in _library.plugins.where((p) => p.enabled))
              DropdownMenuItem(
                value: p.id,
                child: Text('${p.name} · ${p.label}'),
              ),
          ],
          onChanged: (value) => setState(() => _pluginId = value),
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_failures.isNotEmpty)
        ExpansionTile(
          title: Text('${_failures.length} 项搜索失败'),
          children: [
            for (final error in _failures)
              ListTile(dense: true, title: Text(error)),
          ],
        ),
      Expanded(
        child: _tracks.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _library.plugins.isEmpty
                        ? '先添加 MusicFree 或 LX 音乐源，再开始搜索。'
                        : _busy
                        ? '正在搜索…'
                        : _searched
                        ? '未搜索到相关歌曲'
                        : '输入关键词搜索已启用音乐源',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.only(
                  bottom: ShellDockScope.bottomInset(context),
                ),
                itemCount: _tracks.length + (_more ? 1 : 0),
                itemBuilder: (context, index) => index == _tracks.length
                    ? TextButton(
                        onPressed: _busy ? null : () => _search(next: true),
                        child: const Text('加载更多'),
                      )
                    : MusicTrackTile(
                        track: _tracks[index],
                        tracks: _tracks,
                        index: index,
                      ),
              ),
      ),
    ],
  );
  Widget _mine() => ListView(
    padding: EdgeInsets.only(bottom: ShellDockScope.bottomInset(context)),
    children: [
      const ListTile(title: Text('我的收藏')),
      if (_library.favorites.isEmpty)
        const ListTile(subtitle: Text('在歌曲右侧点爱心收藏')),
      for (final row in _library.favorites.indexed)
        MusicTrackTile(
          track: row.$2,
          tracks: _library.favorites,
          index: row.$1,
        ),
      const Divider(),
      const ListTile(title: Text('最近播放')),
      if (_library.recent.isEmpty)
        const ListTile(subtitle: Text('播放过的歌曲会出现在这里')),
      for (final row in _library.recent.indexed)
        MusicTrackTile(track: row.$2, tracks: _library.recent, index: row.$1),
      if (_library.queue.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('恢复上次播放队列'),
          onTap: () async {
            await MusicSession.instance.play(List.of(_library.queue));
            if (mounted) openMusicPlayer(context);
          },
        ),
    ],
  );
  Widget _sources() => ListView(
    padding: EdgeInsets.only(bottom: ShellDockScope.bottomInset(context)),
    children: [
      ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: const Text('添加音乐源'),
        subtitle: const Text('本地 JS / 脚本链接 / MusicFree 订阅'),
        onTap: () => showMusicImport(context),
      ),
      ListTile(
        title: const Text('优先音质'),
        trailing: DropdownButton<String>(
          value: _library.quality,
          items: [
            for (final row in [
              ('low', '流畅'),
              ('standard', '标准'),
              ('high', '无损'),
              ('super', '高解析'),
            ])
              DropdownMenuItem(value: row.$1, child: Text(row.$2)),
          ],
          onChanged: (value) async {
            if (value == null) return;
            _library.quality = value;
            try {
              await _library.save();
            } catch (e) {
              if (mounted) _message(context, e);
            }
          },
        ),
      ),
      if (_library.plugins.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '尚未添加音乐源。MusicFree 插件可以提供搜索、歌词和歌单；LX 脚本负责播放地址解析，搜索由平台曲库提供。',
          ),
        ),
      for (final plugin in _library.plugins)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(plugin.name),
                subtitle: Text(
                  '${plugin.label} · ${plugin.version}\n${plugin.platforms.keys.map(LxCatalog.label).join(' / ')}',
                ),
                value: plugin.enabled,
                onChanged: (value) async {
                  try {
                    MusicService.instance.invalidate(plugin.id);
                    await _library.change(plugin.copyWith(enabled: value));
                  } catch (e) {
                    if (mounted) _message(context, e);
                  }
                },
              ),
              Wrap(
                children: [
                  if (plugin.origin.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('更新'),
                      onPressed: () => _update(plugin),
                    ),
                  if (plugin.variables.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.tune),
                      label: const Text('参数'),
                      onPressed: () => _variables(plugin),
                    ),
                  if (plugin.capabilities.contains('importMusicSheet'))
                    TextButton.icon(
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('导入歌单'),
                      onPressed: () => _sheet(plugin),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                    onPressed: () async {
                      try {
                        MusicService.instance.invalidate(plugin.id);
                        await _library.remove(plugin.id);
                      } catch (e) {
                        if (mounted) _message(context, e);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
  Future<void> _update(MusicPlugin plugin) async {
    try {
      final result = await MusicService.instance.importUrl(plugin.origin);
      if (mounted) {
        _message(
          context,
          '已更新 ${result.imported} 个音乐源${result.failures.isEmpty ? '' : '，失败 ${result.failures.length} 个'}',
        );
      }
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }

  Future<void> _variables(MusicPlugin plugin) async {
    final values = Map<String, String>.of(plugin.values);
    for (final variable in plugin.variables) {
      if (!mounted) return;
      final key = '${variable['key']}';
      final value = await _input(
        context,
        '${variable['name'] ?? key}',
        '插件参数',
        initial: values[key] ?? '',
      );
      if (value == null) return;
      values[key] = value;
    }
    try {
      await _library.change(plugin.copyWith(values: values));
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }

  Future<void> _sheet(MusicPlugin plugin) async {
    final url = await _input(context, '导入歌单', '粘贴此平台的歌单链接');
    if (url == null || url.isEmpty) return;
    try {
      final tracks = await MusicService.instance.importSheet(plugin.id, url);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GlassScaffold(
            title: '导入的歌单',
            child: ListView(
              children: [
                if (tracks.isEmpty) const ListTile(title: Text('歌单为空')),
                for (final row in tracks.indexed)
                  MusicTrackTile(track: row.$2, tracks: tracks, index: row.$1),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) _message(context, e);
    }
  }
}

Future<void> showMusicImport(BuildContext context) async {
  final method = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('添加音乐源'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'url'),
          child: const ListTile(
            leading: Icon(Icons.link),
            title: Text('脚本 / 订阅链接'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'file'),
          child: const ListTile(
            leading: Icon(Icons.file_open_outlined),
            title: Text('本地 JS 文件'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('支持 MusicFree 和 LX 标准脚本；插件可联网，请使用你信任的来源。'),
        ),
      ],
    ),
  );
  if (!context.mounted || method == null) return;
  try {
    if (method == 'file') {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'JavaScript',
            extensions: ['js'],
            uniformTypeIdentifiers: ['public.javascript'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('音乐插件超过 4 MB');
      }
      final plugin = await MusicService.instance.importScript(
        await file.readAsString(),
      );
      if (context.mounted) {
        _message(context, '已添加 ${plugin.name}（${plugin.label}）');
      }
    } else {
      final url = await _input(context, '脚本 / 订阅链接', 'https://…');
      if (url == null || url.isEmpty) return;
      final result = await MusicService.instance.importUrl(url);
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('已导入 ${result.imported} 个音乐源'),
            content: result.failures.isEmpty
                ? null
                : SingleChildScrollView(
                    child: Text(result.failures.join('\n')),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
    }
  } catch (e) {
    if (context.mounted) _message(context, e);
  }
}

class MusicTrackTile extends StatelessWidget {
  const MusicTrackTile({
    super.key,
    required this.track,
    required this.tracks,
    required this.index,
  });
  final MusicTrack track;
  final List<MusicTrack> tracks;
  final int index;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: MusicLibrary.instance,
    builder: (context, _) => ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          track.artist,
          track.album,
          MusicLibrary.instance.plugin(track.pluginId)?.name ?? '音源已删除',
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: MusicLibrary.instance.isFavorite(track) ? '取消收藏' : '收藏',
        icon: Icon(
          MusicLibrary.instance.isFavorite(track)
              ? Icons.favorite
              : Icons.favorite_border,
        ),
        onPressed: () async {
          try {
            await MusicLibrary.instance.toggleFavorite(track);
          } catch (e) {
            if (context.mounted) _message(context, e);
          }
        },
      ),
      onTap: () {
        unawaited(MusicSession.instance.play(List.of(tracks), index: index));
        openMusicPlayer(context);
      },
    ),
  );
}

void openMusicPlayer(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()));

class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: MusicSession.instance,
    builder: (context, _) {
      final session = MusicSession.instance, track = session.current;
      if (track == null) return const SizedBox.shrink();
      return Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openMusicPlayer(context),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.album_outlined),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              session.audio.error ??
                  (session.opening || session.audio.loading
                      ? '正在加载…'
                      : track.artist),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: session.audio.playing ? '暂停' : '播放',
                  onPressed: session.opening || session.audio.loading
                      ? null
                      : session.toggle,
                  icon: Icon(
                    session.audio.playing ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                IconButton(
                  tooltip: '下一首',
                  onPressed: session.audio.current + 1 < session.queue.length
                      ? session.next
                      : null,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});
  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with NetworkOwnedState<MusicPlayerPage> {
  final _session = MusicSession.instance;
  String? _lyricKey, _lyricError;
  List<LyricLine> _lyrics = [];
  double? _drag;
  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _changed();
  }

  void _changed() {
    final track = _session.current;
    if (track == null ||
        _session.opening ||
        _session.audio.loading ||
        _session.audio.seeking ||
        _session.audio.error != null ||
        track.key == _lyricKey) {
      return;
    }
    _lyricKey = track.key;
    _lyrics = [];
    _lyricError = null;
    unawaited(_loadLyrics(track));
  }

  Future<void> _loadLyrics(MusicTrack track) async {
    try {
      final lyrics = await networkRequests.run(
        'lyrics',
        () => MusicService.instance.lyrics(track),
      );
      if (mounted && _lyricKey == track.key) {
        setState(() => _lyrics = LyricLine.parse(lyrics.original));
      }
    } catch (_) {
      if (mounted && _lyricKey == track.key) {
        setState(() => _lyricError = '歌词加载失败');
      }
    }
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    super.dispose();
  }

  static String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  void _queue() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView.builder(
        itemCount: _session.queue.length,
        itemBuilder: (context, index) => ListTile(
          selected: index == _session.audio.current,
          title: Text(_session.queue[index].title),
          subtitle: Text(_session.queue[index].artist),
          onTap: () {
            Navigator.pop(context);
            unawaited(_session.select(index));
          },
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    builder: (context, _) {
      final audio = _session.audio, track = _session.current;
      return GlassScaffold(
        title: '正在播放',
        actions: [
          IconButton(
            tooltip: '播放队列',
            onPressed: _queue,
            icon: const Icon(Icons.queue_music),
          ),
        ],
        child: track == null
            ? Center(child: Text(_session.error ?? '暂无正在播放的音乐'))
            : LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      SizedBox(
                        height: constraints.maxHeight * .32,
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: track.cover?.isNotEmpty == true
                                ? Image.network(
                                    track.cover!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.album, size: 110),
                                  )
                                : const Icon(Icons.album, size: 110),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        track.title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(track.artist, textAlign: TextAlign.center),
                      if (_session.opening || audio.loading)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(),
                        ),
                      if (audio.error != null || _session.error != null)
                        TextButton(
                          onPressed: audio.retry,
                          child: Text('${_session.error ?? audio.error} · 重试'),
                        ),
                      ValueListenableBuilder<(Duration, Duration)>(
                        valueListenable: audio.progress,
                        builder: (context, progress, _) {
                          final duration = progress.$2.inMilliseconds
                              .toDouble();
                          final position =
                              (_drag ?? progress.$1.inMilliseconds.toDouble())
                                  .clamp(0.0, duration > 0 ? duration : 1.0);
                          final lyric = _lyrics
                              .where((line) => line.time <= progress.$1)
                              .lastOrNull
                              ?.text;
                          return Column(
                            children: [
                              SizedBox(
                                height: 58,
                                child: Center(
                                  child: Text(
                                    lyric ?? _lyricError ?? '暂无歌词',
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              Slider(
                                min: 0,
                                max: duration > 0 ? duration : 1,
                                value: position,
                                onChanged: duration <= 0
                                    ? null
                                    : (value) => setState(() => _drag = value),
                                onChangeEnd: (value) {
                                  setState(() => _drag = null);
                                  unawaited(
                                    audio.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  );
                                },
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _time(
                                      Duration(milliseconds: position.round()),
                                    ),
                                  ),
                                  Text(_time(progress.$2)),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip: '上一首',
                            icon: const Icon(Icons.skip_previous_rounded),
                            iconSize: 36,
                            onPressed: audio.current > 0
                                ? _session.previous
                                : null,
                          ),
                          IconButton.filled(
                            tooltip: audio.playing ? '暂停' : '播放',
                            iconSize: 44,
                            onPressed: _session.opening || audio.loading
                                ? null
                                : _session.toggle,
                            icon: Icon(
                              audio.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          IconButton(
                            tooltip: '下一首',
                            icon: const Icon(Icons.skip_next_rounded),
                            iconSize: 36,
                            onPressed: audio.current + 1 < _session.queue.length
                                ? _session.next
                                : null,
                          ),
                        ],
                      ),
                      AnimatedBuilder(
                        animation: MusicLibrary.instance,
                        builder: (context, _) => IconButton(
                          tooltip: '收藏',
                          onPressed: () =>
                              MusicLibrary.instance.toggleFavorite(track),
                          icon: Icon(
                            MusicLibrary.instance.isFavorite(track)
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
