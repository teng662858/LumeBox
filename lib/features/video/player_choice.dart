import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/player/reference_player_factory.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../shared/widgets/glass_card.dart';
import 'player_preferences_page.dart';
import 'player_settings_host.dart';
import 'player_settings_sheet.dart';
import 'reference_player_page.dart';
import 'reference_player_settings.dart';
import 'video_player_page.dart';
import '../../core/player/player_settings.dart';
import '../../core/player/player_capabilities.dart';
import 'danmaku/danmaku_settings.dart';

enum PlayerImplementation { original, reference }

class PlayerChoice extends ValueNotifier<PlayerImplementation> {
  PlayerChoice._() : super(PlayerImplementation.original);
  static final instance = PlayerChoice._();
  Future<void>? _boot;
  bool _loaded = false;
  bool get isLoaded => _loaded;
  File? _file;
  Future<void> boot() => _boot ??= _load();
  Future<void> _load() async {
    try {
      _file = File(
        '${(await getApplicationSupportDirectory()).path}/player_implementation.json',
      );
      if (_file!.existsSync()) {
        final raw = jsonDecode(_file!.readAsStringSync());
        if (raw is Map && raw['implementation'] == 'reference') {
          value = PlayerImplementation.reference;
        }
      }
    } catch (_) {
      value = PlayerImplementation.original;
    } finally {
      _loaded = true;
    }
  }

  Future<void> select(PlayerImplementation next) async {
    await boot();
    final file = _file!;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({'implementation': next.name}),
      flush: true,
    );
    value = next;
  }
}

/// Only routing changes: the original widget, source, settings, and native
/// behavior are passed through untouched whenever Original is selected.
class PlayerChoiceRoute extends StatefulWidget {
  const PlayerChoiceRoute({super.key, required this.original});
  final VideoPlayerPage original;
  @override
  State<PlayerChoiceRoute> createState() => _PlayerChoiceRouteState();
}

class _PlayerChoiceRouteState extends State<PlayerChoiceRoute> {
  late final Future<PlayerImplementation> _selection = _choose();
  Future<PlayerImplementation> _choose() async {
    // Main boots this preference before runApp. Do not await a cached future
    // again on the existing-player fast path (also preserves fake-clock tests).
    if (!PlayerChoice.instance.isLoaded) await PlayerChoice.instance.boot();
    final selection = PlayerChoice.instance.value;
    if (selection == PlayerImplementation.reference) {
      // A prelaunch belongs to the old player settings; do not transfer it
      // into the independently configured reference implementation.
      await widget.original.prelaunch?.discard();
    }
    return selection;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayerImplementation>(
    future: _selection,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.data == PlayerImplementation.original) {
        return widget.original;
      }
      final old = widget.original;
      return ReferencePlayerPage(
        media: old.media,
        title: old.title,
        target: old.target,
        sourceId: old.sourceId,
        qualities: old.qualities,
        sourceManager: old.sourceManager,
        library: old.library,
        playerFactory: old.playerFactory,
        catalog: old.catalog,
        pipBackend: old.pipBackend,
        brightnessBackend: old.brightnessBackend,
        playbackBackend: old.playbackBackend,
        speedMeter: old.speedMeter,
        sourceValidator: old.sourceValidator,
        fullscreenOnly:
            MediaQuery.orientationOf(context) == Orientation.landscape,
      );
    },
  );
}

class PlayerChoiceSettingsPage extends StatefulWidget {
  const PlayerChoiceSettingsPage({super.key});
  @override
  State<PlayerChoiceSettingsPage> createState() =>
      _PlayerChoiceSettingsPageState();
}

class _PlayerChoiceSettingsPageState extends State<PlayerChoiceSettingsPage> {
  late final Future<void> _ready = PlayerChoice.instance.boot();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放器方案')),
    body: FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return ValueListenableBuilder<PlayerImplementation>(
          valueListenable: PlayerChoice.instance,
          builder: (context, selected, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('两套播放器并存，切换后对下一次打开的视频生效。原播放器默认保留，新播放器的设置独立保存。'),
              const SizedBox(height: 18),
              for (final choice in PlayerImplementation.values)
                Card(
                  child: ListTile(
                    title: Text(
                      choice == PlayerImplementation.original
                          ? '现有播放器'
                          : '参考播放器（新）',
                    ),
                    subtitle: Text(
                      choice == PlayerImplementation.original
                          ? '沿用当前布局与全部原有设置'
                          : '按参考视频与截图制作；设置、布局和内核偏好独立',
                    ),
                    trailing: LumeIcon(
                      selected == choice
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      slot: 'player_choice.1',
                      variant: true,
                    ),
                    onTap: () async {
                      try {
                        await PlayerChoice.instance.select(choice);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('方案保存失败，请重试')),
                          );
                        }
                      }
                    },
                  ),
                ),
              const SizedBox(height: 18),
              ListTile(
                leading: const LumeIcon(
                  Icons.settings,
                  slot: 'player_choice.2',
                ),
                title: const Text('现有播放器设置'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PlayerSettingsHost()),
                ),
              ),
              ListTile(
                leading: const LumeIcon(
                  Icons.auto_awesome,
                  slot: 'player_choice.3',
                ),
                title: const Text('参考播放器设置'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReferencePlayerSettingsHost(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class ReferencePlayerSettingsHost extends StatefulWidget {
  const ReferencePlayerSettingsHost({super.key});
  @override
  State<ReferencePlayerSettingsHost> createState() =>
      _ReferencePlayerSettingsHostState();
}

class _ReferencePlayerSettingsHostState
    extends State<ReferencePlayerSettingsHost> {
  ReferencePlayerSettingsStore? _store;
  ReferenceDanmakuSettingsStore? _danmakuStore;
  PlayerSettings? _settings;
  DanmakuSettings? _danmaku;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = await ReferencePlayerSettingsStore.open();
      final library = await ReadingLibrary.open(Section.video);
      final danmaku = ReferenceDanmakuSettingsStore(library);
      if (mounted) {
        setState(() {
          _store = store;
          _settings = store.load();
          _danmakuStore = danmaku;
          _danmaku = danmaku.load();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '参考播放器设置暂不可用');
    }
  }

  void _update(PlayerSettings next) {
    _store!.save(next);
    setState(() => _settings = next);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(_error!),
        ),
      );
    }
    return PlayerPreferencesPage(
      settings: settings,
      onChanged: _update,
      catalog: const ReferencePlayerKernelCatalog(),
      danmaku: _danmaku,
      onDanmakuChanged: (value) {
        _danmakuStore!.save(value);
        setState(() => _danmaku = value);
      },
      advancedBuilder: (current, update) => GlassScaffold(
        effectModule: GlassModule.video,
        title: '参考播放器 · 更多设置',
        child: SingleChildScrollView(
          child: PlayerSettingsSheet(
            settings: current,
            capabilities: PlayerCapabilities.of(current.kernel),
            catalog: const ReferencePlayerKernelCatalog(),
            onChanged: update,
            embedded: true,
            danmaku: _danmaku,
            onDanmakuChanged: (value) {
              _danmakuStore!.save(value);
              setState(() => _danmaku = value);
            },
          ),
        ),
      ),
    );
  }
}
