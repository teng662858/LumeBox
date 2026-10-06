import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/js/qjs_bindings.dart';
import '../../core/js/sandbox/sandbox.dart';
import '../../core/net/lume_net.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/debug_request_log.dart';
import '../../core/util/developer_mode.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';

/// 调试面板（文档「调试日志规范」）：JS 执行记录 / 网络抓包 / 上下文统计。
///
/// 三个分区：
/// 1. **开关**——开发者模式与请求抓包（抓包默认关闭，见 [DeveloperMode] 的说明）；
/// 2. **请求抓包**——最近 200 条请求：方法 / 状态 / 耗时 / 来源 / 请求头（脱敏）；
/// 3. **运行环境**——QuickJS 上下文在册数、放弃回收的 runtime 数、全局参数摘要。
///
/// 数据全部只留内存：进程退出即清空，**不落盘、不导出**。面板是排障窗口，
/// 不是数据收集器。
class DebugPanelPage extends StatefulWidget {
  const DebugPanelPage({super.key, this.now});

  /// 时钟（测试可注入，让时间戳可预期）。
  final DateTime Function()? now;

  @override
  State<DebugPanelPage> createState() => _DebugPanelPageState();
}

class _DebugPanelPageState extends State<DebugPanelPage> {
  late DeveloperModeSettings _settings = DeveloperMode.current;

  @override
  void initState() {
    super.initState();
    DebugRequestLog.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _apply(DeveloperModeSettings next) async {
    setState(() => _settings = next);
    try {
      await DeveloperMode.save(next);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = DebugRequestLog.snapshot;
    return GlassScaffold(
      behindBar: true,
      title: '调试面板',
      actions: <Widget>[
        IconButton(
          tooltip: '清空抓包',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: records.isEmpty
              ? null
              : () {
                  DebugRequestLog.clear();
                  setState(() {});
                },
        ),
      ],
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          _buildSwitches(),
          const SizedBox(height: 12),
          _buildCapture(records),
          const SizedBox(height: 12),
          const _RuntimeStatsCard(),
        ],
      ),
    );
  }

  Widget _buildSwitches() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '开关',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '抓包只留内存、不落盘、不导出；关闭开关会立即清空已记录的内容。',
            style: TextStyle(fontSize: 12, height: 1.5, color: LumeTheme.muted),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '开发者模式',
              style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
            ),
            subtitle: Text(
              '打开后才可开启请求抓包',
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            value: _settings.enabled,
            onChanged: (value) => _apply(
              _settings.copyWith(
                enabled: value,
                // 总开关关掉时顺手关抓包：留着「已开但没生效」的开关会误导。
                requestCapture: value ? _settings.requestCapture : false,
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '请求抓包',
              style: TextStyle(fontSize: 14, color: LumeTheme.textPrimary),
            ),
            subtitle: Text(
              '记录每个请求的方法 / 状态 / 耗时 / 来源（凭据类请求头自动隐藏）',
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            value: _settings.requestCapture,
            onChanged: _settings.enabled
                ? (value) => _apply(_settings.copyWith(requestCapture: value))
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildCapture(List<DebugRequestRecord> records) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '请求抓包',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
              ),
              Text(
                records.isEmpty ? '无记录' : '${records.length} 条',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            DebugRequestLog.enabled
                ? '最近 ${DebugRequestLog.limit} 条请求（新 → 旧）'
                : '抓包未开启：打开上面的开关后，这里会显示请求明细',
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          if (records.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            for (final record in records.take(50))
              _RequestTile(record: record, now: widget.now),
            if (records.length > 50)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '只显示最近 50 条（共 ${records.length} 条）',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 一条请求记录：摘要一行，展开看请求头。
class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.record, this.now});

  final DebugRequestRecord record;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final color = record.isFailure ? LumeTheme.danger : LumeTheme.success;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              record.describe(),
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          Text(
            '${record.source} · ${_clock(record.time)}',
            style: TextStyle(fontSize: 11, color: LumeTheme.muted),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          record.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: LumeTheme.muted),
        ),
      ),
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (record.error.isNotEmpty)
                Text(
                  '失败原因：${record.error}',
                  style: TextStyle(fontSize: 12, color: LumeTheme.danger),
                ),
              if (record.note.isNotEmpty)
                Text(
                  record.note,
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              Text(
                '响应体：${record.responseBytes} 字节',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
              const SizedBox(height: 6),
              Text(
                '请求头',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              if (record.requestHeaders.isEmpty)
                Text(
                  '（无）',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              for (final entry in record.requestHeaders.entries)
                Text(
                  '${entry.key}: ${entry.value}',
                  style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: record.url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制请求地址')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制地址', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _clock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// 运行环境：QuickJS 上下文统计与全局参数摘要。
class _RuntimeStatsCard extends StatelessWidget {
  const _RuntimeStatsCard();

  @override
  Widget build(BuildContext context) {
    final settings = LumeNet.settings;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '运行环境',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          _row('在册 JS 上下文', '${SandboxContext.liveCount}'),
          _row('放弃回收的 JSRuntime', '${Qjs.abandonedRuntimes}'),
          _row('日志缓冲', '${LumeLog.snapshot.length} / ${LumeLog.bufferLimit}'),
          _row('全局并发', '${settings.globalConcurrency}（单域名 ${settings.perHostConcurrency}）'),
          _row('请求超时', '${settings.timeout.inSeconds}s（重试 ${settings.maxRetries} 次）'),
          _row('全局 UA', settings.userAgent.isEmpty ? '内置默认' : '自定义'),
          _row('全局代理', settings.proxy.isEmpty ? '直连' : settings.proxy),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: LumeTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
