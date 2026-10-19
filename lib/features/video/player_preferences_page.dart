import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/player/playback_logs.dart';
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import 'danmaku/danmaku_settings.dart';
import 'danmaku/danmaku_sources_page.dart';
import 'intro_settings_page.dart';
import 'reference_player_help_page.dart';

/// Reference-style global playback settings. The existing detailed panel is
/// still reachable through [advancedBuilder], using the same settings object.
class PlayerPreferencesPage extends StatefulWidget {
  const PlayerPreferencesPage({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.catalog,
    required this.advancedBuilder,
    this.danmaku,
    this.onDanmakuChanged,
  });
  final PlayerSettings settings;
  final ValueChanged<PlayerSettings> onChanged;
  final PlayerKernelCatalog catalog;
  final Widget Function(
    PlayerSettings settings,
    ValueChanged<PlayerSettings> update,
  )
  advancedBuilder;
  final DanmakuSettings? danmaku;
  final ValueChanged<DanmakuSettings>? onDanmakuChanged;
  @override
  State<PlayerPreferencesPage> createState() => _PlayerPreferencesPageState();
}

class _PlayerPreferencesPageState extends State<PlayerPreferencesPage> {
  PlayerExperienceStore? _store;
  late PlayerSettings _settings = widget.settings;
  late DanmakuSettings? _danmaku = widget.danmaku;
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final store = await PlayerExperienceStore.open();
    if (mounted) setState(() => _store = store);
  }

  @override
  void didUpdateWidget(covariant PlayerPreferencesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _settings = widget.settings;
    _danmaku = widget.danmaku;
  }

  void _update(PlayerSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  void _open(Widget page) =>
      Navigator.push<void>(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ValueListenableBuilder<PlayerExperience>(
      valueListenable: store,
      builder: (context, prefs, _) => _SettingsScreen(
        title: '播放',
        children: [
          _Group(
            children: [
              _SettingRow(
                icon: CupertinoIcons.book_fill,
                color: Colors.blue,
                title: '参考播放器使用说明',
                subtitle: '操作、各识别方案、手动打点、模型与日志',
                onTap: () => _open(const ReferencePlayerHelpPage()),
              ),
              _SettingRow(
                icon: CupertinoIcons.forward_end_fill,
                color: Colors.pink,
                title: '片头片尾自动识别与跳过',
                subtitle: '社区库、元数据、指纹、启发式、AI、手动打点',
                onTap: () => _open(const IntroSettingsPage()),
              ),
            ],
          ),
          const _Caption('播放内核'),
          _Group(
            children: [
              _SettingRow(
                icon: CupertinoIcons.play_circle_fill,
                color: Colors.green,
                title: '默认内核',
                value: _settings.kernel.label,
                onTap: () => _options(
                  context,
                  '默认播放内核',
                  {for (final k in PlayerKernel.values) k.id: k.label},
                  _settings.kernel.id,
                  (id) {
                    // Choosing a default is permitted even while previewing on a
                    // platform without that native kernel; playback still checks availability.
                    _update(
                      _settings.copyWith(kernel: PlayerKernel.fromId(id)),
                    );
                  },
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.gobackward,
                color: Colors.indigo,
                title: '默认解码',
                value: _settings.hardwareDecoding ? '硬件解码' : '软件解码',
                onTap: () => _options(
                  context,
                  '默认解码方式',
                  const {'hardware': '硬件解码', 'software': '软件解码'},
                  _settings.hardwareDecoding ? 'hardware' : 'software',
                  (id) => _update(
                    _settings.copyWith(hardwareDecoding: id == 'hardware'),
                  ),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.slider_horizontal_3,
                color: Colors.blue,
                title: '内核设置',
                subtitle: '各内核的缓冲、渲染器、配置与播放日志',
                onTap: () => _open(PlayerKernelPreferencesPage(store: store)),
              ),
              _SettingRow(
                icon: CupertinoIcons.arrow_2_squarepath,
                color: Colors.orange,
                title: '播放失败自动切换内核',
                subtitle: '只在当前内核报错时尝试其他内核，不切换播放线路',
                toggle: prefs.autoKernelSwitch,
                onToggle: (v) => store.update({'autoKernelSwitch': v}),
              ),
              _SettingRow(
                icon: CupertinoIcons.square_grid_2x2,
                color: Colors.deepPurple,
                title: '播放页按钮样式',
                subtitle: '倍速、字幕、弹幕等按钮显示文字或图标',
                value: _settings.controlStyle == PlayerControlStyle.text
                    ? '文字'
                    : '图标',
                onTap: () => _options(
                  context,
                  '播放页按钮样式',
                  const {'text': '文字', 'icons': '图标'},
                  _settings.controlStyle.name,
                  (id) => _update(
                    _settings.copyWith(
                      controlStyle: PlayerControlStyle.values.byName(id),
                    ),
                  ),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.rectangle_3_offgrid,
                color: Colors.cyan,
                title: '播放页按钮布局',
                subtitle: '拖拽排序，分配到顶部、底部或隐藏',
                onTap: () => _open(PlayerButtonLayoutPage(store: store)),
              ),
              _SettingRow(
                icon: CupertinoIcons.globe,
                color: Colors.indigo,
                title: '浏览器 UA',
                value: prefs.browserUA.isEmpty ? '默认' : '已自定义',
                subtitle: '留空使用图源和内核原有设置；验证会话的 UA 优先保留',
                onTap: () => _editText(
                  context,
                  '浏览器 UA',
                  prefs.browserUA,
                  (value) => store.update({'browserUA': value}),
                  presets: const {
                    'Chrome（电脑）': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
                    'Chrome（安卓）': 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36',
                    'Safari（iPhone）': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
                    'okhttp': 'okhttp/4.12.0',
                  },
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.music_note_2,
                color: Colors.green,
                title: '后台播放',
                subtitle: '离开画面后继续播放；可在系统锁屏控制',
                toggle: prefs.backgroundPlayback,
                onToggle: (v) => store.update({'backgroundPlayback': v}),
              ),
            ],
          ),
          const _Caption('播放设置'),
          _Group(
            children: [
              _SettingRow(
                icon: CupertinoIcons.hand_draw,
                color: Colors.purple,
                title: '播放手势位置',
                subtitle: '两侧上下滑动调整音量和屏幕亮度',
                value: prefs.swapGestureSides ? '左音量 · 右亮度' : '左亮度 · 右音量',
                onTap: () => _options(
                  context,
                  '播放手势位置',
                  const {'normal': '左侧亮度 · 右侧音量', 'swapped': '左侧音量 · 右侧亮度'},
                  prefs.swapGestureSides ? 'swapped' : 'normal',
                  (id) => store.update({'swapGestureSides': id == 'swapped'}),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.arrow_up_arrow_down,
                color: Colors.green,
                title: '上下滑动换集',
                subtitle: '画面中央上滑下一集，下滑上一集',
                toggle: prefs.swipeEpisodes,
                onToggle: (v) => store.update({'swipeEpisodes': v}),
              ),
              _SettingRow(
                icon: CupertinoIcons.hand_raised,
                color: Colors.orange,
                title: '双指滑动换集',
                subtitle: '开启后需要两根手指，单指保留原播放手势',
                toggle: prefs.twoFingerEpisodes,
                onToggle: (v) => store.update({'twoFingerEpisodes': v}),
              ),
              _SettingRow(
                icon: CupertinoIcons.chat_bubble_text_fill,
                color: Colors.cyan,
                title: '弹幕源',
                subtitle: '兼容服务器、弹弹play开放平台与本地弹幕',
                onTap: () => _open(const DanmakuSourcesPage()),
              ),
              _SettingRow(
                icon: CupertinoIcons.chat_bubble_2_fill,
                color: Colors.blue,
                title: '默认显示弹幕',
                toggle: _danmaku?.enabled ?? true,
                onToggle: _danmaku == null
                    ? null
                    : (v) {
                        final next = _danmaku!.copyWith(enabled: v);
                        setState(() => _danmaku = next);
                        widget.onDanmakuChanged?.call(next);
                      },
              ),
              _SettingRow(
                icon: CupertinoIcons.speedometer,
                color: Colors.green,
                title: '默认倍速',
                value:
                    '${_settings.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x',
                onTap: () => _options(
                  context,
                  '默认倍速',
                  {
                    for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                      '$speed': '${speed}x',
                  },
                  '${_settings.speed}',
                  (id) => _update(_settings.copyWith(speed: double.parse(id))),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.forward_fill,
                color: Colors.red,
                title: '长按倍速',
                subtitle: '长按画面临时加速，松手恢复原倍速',
                value: '${prefs.number('longPressSpeed', 2, 1, 10)}x',
                onTap: () => _number(
                  context,
                  '长按倍速',
                  prefs.number('longPressSpeed', 2, 1, 10),
                  1.25,
                  10,
                  'x',
                  (v) => store.update({'longPressSpeed': v}),
                  step: .25,
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.sun_max_fill,
                color: Colors.orange,
                title: '播放亮度',
                subtitle: '打开视频时的亮度；每个资源独立记忆',
                value: prefs.followSystemBrightness ? '跟随系统' : '资源记忆',
                onTap: () => _brightness(context, store),
              ),
              _SettingRow(
                icon: CupertinoIcons.rectangle_on_rectangle,
                color: Colors.green,
                title: '详情页点选集',
                subtitle: '手机竖屏详情页的选集操作',
                value: prefs.selectEpisodeOnly ? '只选中' : '直接播放',
                onTap: () => _options(
                  context,
                  '在详情页点某一集',
                  const {'play': '直接播放', 'select': '只选中，点播放按钮再播'},
                  prefs.selectEpisodeOnly ? 'select' : 'play',
                  (id) => store.update({'selectEpisodeOnly': id == 'select'}),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.captions_bubble_fill,
                color: Colors.orange,
                title: '优先字幕',
                value: _subtitleLabels[prefs.subtitleLanguage],
                onTap: () => _options(
                  context,
                  '打开视频时优先选用的字幕',
                  _subtitleLabels,
                  prefs.subtitleLanguage,
                  (id) => store.update({'subtitleLanguage': id}),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.forward_end_fill,
                color: Colors.pink,
                title: '短剧预载',
                subtitle: '当前集短于设定上限时，提前准备下一集',
                toggle: prefs.shortDramaPreload,
                onToggle: (v) => store.update({'shortDramaPreload': v}),
              ),
              _SettingRow(
                icon: CupertinoIcons.timer,
                color: Colors.orange,
                title: '预载时长上限',
                value: '${prefs.preloadMinutes} 分钟',
                onTap: () => _number(
                  context,
                  '预载时长上限',
                  prefs.preloadMinutes.toDouble(),
                  1,
                  10,
                  '分钟',
                  (v) => store.update({'preloadMinutes': v.round()}),
                ),
              ),
              _SettingRow(
                icon: CupertinoIcons.trash_fill,
                color: Colors.grey,
                title: '清理短剧预载缓存',
                subtitle: '释放已准备的下一集，不影响正在播放的内容',
                onTap: () {
                  // Live players listen for this revision and discard only their preload.
                  store.update({
                    'preloadClearRevision':
                        DateTime.now().microsecondsSinceEpoch,
                  });
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('已清理短剧预载缓存')));
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Group(
            children: [
              _SettingRow(
                icon: CupertinoIcons.slider_horizontal_3,
                color: Colors.blueGrey,
                title: '更多播放设置',
                subtitle: '保留原有画面、字幕样式、音轨、方向和手势灵敏度等设置',
                onTap: () => _open(widget.advancedBuilder(_settings, _update)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

const _subtitleLabels = {
  'source': '跟随片源',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁体中文',
  'yue': '中文（简繁皆可）',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
  'off': '关闭字幕',
};

class PlayerKernelPreferencesPage extends StatelessWidget {
  const PlayerKernelPreferencesPage({super.key, required this.store});
  final PlayerExperienceStore store;
  Future<void> _logs(BuildContext context, String kernel) async {
    final logs = await PlaybackLogs.open();
    if (!context.mounted) return;
    await _options(
      context,
      '${kernel.toUpperCase()} 播放日志',
      const {'export': '导出全部日志（ZIP）', 'clear': '清空日志'},
      '',
      (id) async {
        if (id == 'clear') {
          logs.clear(kernel);
          return;
        }
        if (logs.files(kernel).isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂无播放日志')));
          return;
        }
        final bytes = logs.zip(kernel);
        final name =
            '$kernel-playback-${DateTime.now().millisecondsSinceEpoch}.zip';
        if (Platform.isIOS || Platform.isAndroid) {
          await const MethodChannel('lumebox/configuration')
              .invokeMethod<bool>('export', {'bytes': bytes, 'name': name});
        } else {
          final location = await getSaveLocation(suggestedName: name);
          if (location != null) {
            await XFile.fromData(bytes).saveTo(location.path);
          }
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<PlayerExperience>(
        valueListenable: store,
        builder: (context, prefs, _) => _SettingsScreen(
          title: '内核设置',
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text('改动对之后打开的视频生效，正在播放的内容需要重新打开。'),
            ),
            const _Caption('MPV'),
            _Group(
              children: [
                _SettingRow(
                  icon: CupertinoIcons.gobackward,
                  color: Colors.indigo,
                  title: '最大缓冲大小',
                  subtitle: '提前读进内存的数据量上限',
                  value: '${prefs.mpvBufferMB} MB',
                  onTap: () => _number(
                    context,
                    '最大缓冲大小',
                    prefs.mpvBufferMB.toDouble(),
                    50,
                    1000,
                    'MB',
                    (v) => store.update({'mpvBufferMB': v.round()}),
                  ),
                ),
                _SettingRow(
                  icon: CupertinoIcons.timer,
                  color: Colors.orange,
                  title: '最大缓冲时长',
                  subtitle: '最多提前缓冲多久的内容',
                  value: '${prefs.mpvBufferSeconds} 秒',
                  onTap: () => _number(
                    context,
                    '最大缓冲时长',
                    prefs.mpvBufferSeconds.toDouble(),
                    10,
                    1000,
                    '秒',
                    (v) => store.update({'mpvBufferSeconds': v.round()}),
                  ),
                ),
                _SettingRow(
                  icon: CupertinoIcons.desktopcomputer,
                  color: Colors.purple,
                  title: '视频渲染器',
                  value: prefs.mpvRenderer,
                  onTap: () => _options(
                    context,
                    '视频渲染器',
                    const {'gpu': 'gpu', 'gpu-next': 'gpu-next'},
                    prefs.mpvRenderer,
                    (v) => store.update({'mpvRenderer': v}),
                  ),
                ),
                _SettingRow(
                  icon: CupertinoIcons.chevron_left_slash_chevron_right,
                  color: Colors.grey,
                  title: '自定义 mpv.conf',
                  value: prefs.mpvConf.isEmpty ? '未设置' : '已设置',
                  onTap: () => _editText(
                    context,
                    '自定义 mpv.conf',
                    prefs.mpvConf,
                    (v) {
                      MpvConfOptions.parse(v);
                      store.update({'mpvConf': v});
                    },
                    multiline: true,
                    hint:
                        '一行一个 key=value，例如：\nvideo-sync=display-resample\n# 注释',
                  ),
                ),
                _SettingRow(
                  icon: CupertinoIcons.doc_text_fill,
                  color: Colors.blue,
                  title: '播放日志',
                  subtitle: '每次播放单独保存一个日志文件',
                  toggle: prefs.logging('mpv'),
                  onToggle: (v) => store.update({'mpv.logging': v}),
                ),
                _SettingRow(
                  icon: CupertinoIcons.share,
                  color: Colors.cyan,
                  title: '导出播放日志',
                  onTap: () => _logs(context, 'mpv'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '播放器使用 libmpv 的 Flutter 纹理渲染。gpu-next 是否可用取决于随包内核；'
                '不支持时保留当前渲染路径并记录原因，不把选择值视为生效结果。'
                '自定义配置中不能改变宿主纹理输出。',
              ),
            ),
            const _Caption('MDK'),
            _Group(
              children: [
                _SettingRow(
                  icon: CupertinoIcons.timer,
                  color: Colors.orange,
                  title: '最大缓冲时长',
                  subtitle: '最多提前缓冲多久的内容',
                  value: '${prefs.mdkBufferSeconds} 秒',
                  onTap: () => _number(
                    context,
                    '最大缓冲时长',
                    prefs.mdkBufferSeconds.toDouble(),
                    10,
                    1000,
                    '秒',
                    (v) => store.update({'mdkBufferSeconds': v.round()}),
                  ),
                ),
                _SettingRow(
                  icon: CupertinoIcons.doc_text_fill,
                  color: Colors.blue,
                  title: '播放日志',
                  subtitle: '每次播放单独保存一个日志文件',
                  toggle: prefs.logging('mdk'),
                  onToggle: (v) => store.update({'mdk.logging': v}),
                ),
                _SettingRow(
                  icon: CupertinoIcons.share,
                  color: Colors.cyan,
                  title: '导出播放日志',
                  onTap: () => _logs(context, 'mdk'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '每个内核最多保留最新 20 个日志，总计不超过 50 MB，旧日志自动删除。'
                '记录媒体地址的主机和路径，不记录请求头、账户密码或查询参数。',
              ),
            ),
          ],
        ),
      );
}

class PlayerButtonLayoutPage extends StatelessWidget {
  const PlayerButtonLayoutPage({super.key, required this.store});
  final PlayerExperienceStore store;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<PlayerExperience>(
    valueListenable: store,
    builder: (context, prefs, _) {
      final layout = prefs.layout;
      final groups = {
        'top': layout.top,
        'bottom': layout.bottom,
        'hidden': layout.hidden,
      };
      void save(Map<String, List<String>> next) =>
          store.update({'layout': next});
      void move(String id, String destination) {
        final next = {
          for (final entry in groups.entries)
            entry.key: entry.value.where((v) => v != id).toList(),
        };
        next[destination]!.add(id);
        save(next);
      }

      return _SettingsScreen(
        title: '播放页按钮布局',
        actions: [
          TextButton(
            onPressed: () =>
                store.update({'layout': const PlayerButtonLayout().toJson()}),
            child: const Text('恢复默认'),
          ),
        ],
        children: [
          for (final group in groups.entries) ...[
            _Caption(
              {'top': '顶上一排', 'bottom': '底下一排', 'hidden': '不显示'}[group.key]!,
            ),
            Text(
              {
                'top': '横屏在标题右边，竖屏在标题下面另起一行',
                'bottom': '进度条下面；窄屏自动换行',
                'hidden': '这里的按钮不会出现在播放页',
              }[group.key]!,
            ),
            const SizedBox(height: 10),
            DragTarget<String>(
              onWillAcceptWithDetails: (details) =>
                  PlayerButtonLayout.labels.containsKey(details.data),
              onAcceptWithDetails: (details) => move(details.data, group.key),
              builder: (context, candidate, rejected) => Container(
                constraints: const BoxConstraints(minHeight: 55),
                decoration: BoxDecoration(
                  color: candidate.isEmpty
                      ? null
                      : Theme.of(context).colorScheme.primary
                            .withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: group.value.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final next = {
                      for (final entry in groups.entries)
                        entry.key: List<String>.of(entry.value),
                    };
                    final items = next[group.key]!;
                    items.insert(newIndex, items.removeAt(oldIndex));
                    save(next);
                  },
                  itemBuilder: (context, index) {
                    final id = group.value[index];
                    final tile = ListTile(
                      title: Text(PlayerButtonLayout.labels[id]!),
                      leading: LumeIcon(
                        CupertinoIcons.circle_grid_3x3,
                        slot: 'player_preferences_page.1',
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<String>(
                            tooltip: '移动到',
                            onSelected: (destination) => move(id, destination),
                            itemBuilder: (_) => [
                              for (final entry in const {
                                'top': '顶部',
                                'bottom': '底部',
                                'hidden': '隐藏',
                              }.entries)
                                PopupMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                            ],
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: LumeIcon(
                                CupertinoIcons.line_horizontal_3,
                                slot: 'player_preferences_page.2',
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                    return Padding(
                      key: ValueKey(id),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: LongPressDraggable<String>(
                        data: id,
                        feedback: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(18),
                          child: SizedBox(
                            width: 250,
                            child: ListTile(
                              title: Text(PlayerButtonLayout.labels[id]!),
                            ),
                          ),
                        ),
                        child: _Group(children: [tile]),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen({
    required this.title,
    required this.children,
    this.actions,
  });
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF171719)
        : const Color(0xFFF0F2ED),
    appBar: AppBar(
      title: Text(title),
      centerTitle: false,
      backgroundColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actions: actions,
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: children,
      ),
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 18, 10, 10),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: ColoredBox(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF252528)
          : Colors.white,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 62),
                child: Divider(height: 1),
              ),
            children[i],
          ],
        ],
      ),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.toggle,
    this.onToggle,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle, value;
  final VoidCallback? onTap;
  final bool? toggle;
  final ValueChanged<bool>? onToggle;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    minLeadingWidth: 32,
    leading: Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: LumeIcon(
        icon,
        slot: 'player_preferences_page.3',
        variant: true,
        color: Colors.white,
        size: 20,
      ),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
    onTap: onTap,
    trailing: toggle != null
        ? CupertinoSwitch(
            value: toggle!,
            onChanged: onToggle,
            activeTrackColor: Theme.of(context).colorScheme.primary,
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    value!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
              if (onTap != null)
                const Padding(
                  padding: EdgeInsets.only(left: 5),
                  child: LumeIcon(
                    CupertinoIcons.chevron_right,
                    slot: 'player_preferences_page.4',
                    size: 15,
                    color: Colors.grey,
                  ),
                ),
            ],
          ),
  );
}

Future<void> _modal(BuildContext context, String title, Widget child) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .80,
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const LumeIcon(
                            CupertinoIcons.xmark_circle_fill,
                            slot: 'player_preferences_page.5',
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
Future<void> _options(
  BuildContext context,
  String title,
  Map<String, String> choices,
  String selected,
  ValueChanged<String> select,
) => _modal(
  context,
  title,
  Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final entry in choices.entries)
        ListTile(
          title: Text(entry.value),
          trailing: entry.key == selected
              ? LumeIcon(
                  CupertinoIcons.check_mark,
                  slot: 'player_preferences_page.6',
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
          onTap: () {
            Navigator.pop(context);
            select(entry.key);
          },
        ),
    ],
  ),
);
Future<void> _number(
  BuildContext context,
  String title,
  double initial,
  double min,
  double max,
  String unit,
  ValueChanged<double> save, {
  double step = 1,
}) async {
  var current = initial.clamp(min, max);
  await _modal(
    context,
    title,
    StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          Text(
            '${current.toStringAsFixed(step < 1 ? 2 : 0)} $unit',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          Slider(
            value: current,
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: (v) => setState(() => current = v),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text('$min $unit'), Text('$max $unit')],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                save(current);
                Navigator.pop(context);
              },
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _editText(
  BuildContext context,
  String title,
  String initial,
  ValueChanged<String> save, {
  bool multiline = false,
  String? hint,
  Map<String, String> presets = const {},
}) async {
  final input = TextEditingController(text: initial);
  String? error;
  try {
    await _modal(
      context,
      title,
      StatefulBuilder(
        builder: (context, setState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: input,
              minLines: multiline ? 5 : 1,
              maxLines: multiline ? 9 : 3,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: hint,
                errorText: error,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (presets.isNotEmpty)
              Wrap(
                children: [
                  for (final preset in presets.entries)
                    TextButton(
                      onPressed: () => input.text = preset.value,
                      child: Text(preset.key),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                try {
                  save(input.text.trim());
                  Navigator.pop(context);
                } catch (e) {
                  setState(() => error = '$e');
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  } finally {
    input.dispose();
  }
}

Future<void> _brightness(BuildContext context, PlayerExperienceStore store) =>
    _modal(
      context,
      '播放亮度',
      ValueListenableBuilder<PlayerExperience>(
        valueListenable: store,
        builder: (context, prefs, _) => Column(
          children: [
            _SettingRow(
              icon: CupertinoIcons.device_phone_portrait,
              color: Colors.grey,
              title: '跟随系统',
              subtitle: '打开新视频时优先使用当前系统亮度',
              toggle: prefs.followSystemBrightness,
              onToggle: (v) => store.update({'followSystemBrightness': v}),
            ),
            _SettingRow(
              icon: CupertinoIcons.arrow_2_circlepath,
              color: Colors.green,
              title: '按资源记住亮度',
              subtitle: '重新打开同一资源时恢复手动调节的亮度',
              toggle: prefs.rememberBrightness,
              onToggle: (v) => store.update({'rememberBrightness': v}),
            ),
          ],
        ),
      ),
    );
