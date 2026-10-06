import 'package:flutter/material.dart';

import '../../core/js/cat_engines.dart';
import '../../core/js/source_engine.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';

/// 猫源引擎设置页：在可用引擎之间切换（**入口只在 Android 显示**）。
///
/// 选择落在猫源板块自己的图源库里（板块隔离）；切换在下次打开图源时生效。
/// 不可用的引擎（如 Node-Mobile 的原生模块尚未集成时）如实标注并置灰——
/// 不假装可切换。
class CatEngineSettingsPage extends StatefulWidget {
  const CatEngineSettingsPage({super.key, this.settings, this.probe});

  /// 引擎选择存储；为空时打开猫源板块自己的库（测试注入用）。
  final CatEngineSettings? settings;

  /// 就绪探测；为空时用 [CatEngines.probeAvailability]（测试注入用）。
  final Future<Map<CatEngineKind, bool>> Function()? probe;

  @override
  State<CatEngineSettingsPage> createState() => _CatEngineSettingsPageState();
}

class _CatEngineSettingsPageState extends State<CatEngineSettingsPage> {
  CatEngineSettings? _settings;
  CatEngineKind _current = CatEngineKind.quickjs;
  Map<CatEngineKind, bool> _ready = <CatEngineKind, bool>{};
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = widget.settings ?? await CatEngineSettings.open();
      final probe = widget.probe ?? CatEngines.probeAvailability;
      final ready = await probe();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _current = settings.load();
        _ready = ready;
        _failed = false;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _select(CatEngineKind kind) {
    final settings = _settings;
    if (settings == null) return;
    if (_current == kind) return;
    if (_ready[kind] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${kind.label} 在本机不可用')),
      );
      return;
    }
    settings.save(kind);
    setState(() => _current = kind);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换为 ${kind.label}，下次打开源时生效')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '猫源引擎',
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_failed) {
      return const NoticeCard(
        title: '引擎设置不可用',
        subtitle: '猫源板块的源库打不开，请重启应用后重试',
      );
    }
    if (_settings == null) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    final choices = CatEngines.choices;
    return ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: <Widget>[
        const Text(
          '猫源脚本需要 JS 引擎。切换只影响猫源板块，下次打开源时生效；'
          '每个源仍然独占一个独立引擎实例。',
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
        const SizedBox(height: 12),
        for (final kind in choices) ...<Widget>[
          _EngineTile(
            kind: kind,
            selected: _current == kind,
            available: _ready[kind] ?? true,
            onTap: () => _select(kind),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _EngineTile extends StatelessWidget {
  const _EngineTile({
    required this.kind,
    required this.selected,
    required this.available,
    required this.onTap,
  });

  final CatEngineKind kind;
  final bool selected;
  final bool available;
  final VoidCallback onTap;

  String get _description => switch (kind) {
        CatEngineKind.quickjs => '轻量沙箱引擎，一源一独立上下文（iOS / Android）',
        CatEngineKind.nodeMobile => 'Node 运行时（Android 专属；原生模块未集成时不可用）',
      };

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: available ? onTap : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  kind.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: available ? LumeTheme.textPrimary : LumeTheme.muted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _description,
                  style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                if (!available) ...<Widget>[
                  const SizedBox(height: 2),
                  const Text(
                    '本机不可用',
                    style: TextStyle(fontSize: 12, color: LumeTheme.danger),
                  ),
                ],
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check_circle, size: 20, color: LumeTheme.textPrimary)
          else if (available)
            const Icon(
              Icons.radio_button_unchecked,
              size: 20,
              color: LumeTheme.muted,
            ),
        ],
      ),
    );
  }
}
