import 'package:flutter/material.dart';

import '../../core/js/sandbox/sandbox_policy.dart';
import '../../core/js/sandbox_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';

/// 全局沙箱设置页：四个板块的图源脚本共用的执行预算。
///
/// 对应文档第 4 条：「配置所有图源共用的全局参数（全局并发、全局 UA、全局代理、
/// **JS沙箱超时**等，全局互通生效）」。
///
/// ## 本页只开放一项，其余刻意不给
///
/// 可配的只有**墙钟超时**（文档钉死的 3–5 秒区间）。慢站点的正常脚本可能刚好
/// 卡在默认 4 秒，用户需要一个把它放宽到 5 秒的口子——这是本页存在的理由。
///
/// 内存上限、栈上限、指令计数、宿主调用数、微任务轮数**一律不做成可配**：
/// 它们是防死循环 / 防内存失控的安全兜底，调大等于把保护关掉。栈上限尤其危险
/// ——`SandboxPolicy.defaultStackLimitBytes` 的注释里记着实测数据：调到 1MB
/// 会让进程当场死亡（无异常、无日志）。这类值不该出现在设置页上。
class SandboxSettingsPage extends StatefulWidget {
  const SandboxSettingsPage({super.key});

  @override
  State<SandboxSettingsPage> createState() => _SandboxSettingsPageState();
}

class _SandboxSettingsPageState extends State<SandboxSettingsPage> {
  late SandboxSettings _settings = LumeSandboxSettings.current;

  bool _dirty = false;

  void _update(SandboxSettings next) {
    setState(() {
      _settings = next;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    try {
      await LumeSandboxSettings.save(_settings);
      if (!mounted) return;
      setState(() {
        _settings = LumeSandboxSettings.current;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存：新建的源引擎按新超时运行')),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '沙箱设置',
      actions: <Widget>[
        TextButton(
          onPressed: _dirty ? _save : null,
          child: const Text('保存'),
        ),
      ],
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'JS 执行超时',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '单个源脚本一次调用最多跑多久。超时即判定失控、销毁该源的上下文'
                  '并重建——App 不会因此卡死，但那个源的那次调用会失败。',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final seconds in SandboxSettings.timeoutOptionsSeconds)
                      ChoiceChip(
                        label: Text('$seconds 秒'),
                        selected: _settings.timeout.inSeconds == seconds,
                        onSelected: (_) => _update(
                          _settings.copyWith(timeout: Duration(seconds: seconds)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '可配区间为 ${SandboxPolicy.minTimeout.inSeconds}–'
                  '${SandboxPolicy.maxTimeout.inSeconds} 秒（文档规定）。'
                  '调大能给慢站点更多余量，但一个卡住的脚本也会占住更久；'
                  '默认 ${SandboxSettings.defaultTimeout.inSeconds} 秒。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: LumeTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const _FixedLimitsCard(),
          const SizedBox(height: 12),
          NoticeCard(
            title: '当前生效',
            subtitle: LumeSandboxSettings.current.toString(),
          ),
        ],
      ),
    );
  }
}

/// 固定上限说明：说清「为什么这些不能改」，免得用户以为是自己没找到入口。
class _FixedLimitsCard extends StatelessWidget {
  const _FixedLimitsCard();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '固定安全上限（不可调）',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '内存上限、调用栈上限、指令计数、宿主调用次数这些是防死循环与防内存失控的'
            '兜底，调大等于把保护关掉，因此不开放配置。超时是唯一例外——它只影响'
            '「等多久算失控」，不削弱任何防护。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
        ],
      ),
    );
  }
}
