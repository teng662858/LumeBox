import 'package:flutter/material.dart';

import '../../core/net/lume_net.dart';
import '../../core/net/network_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';

/// 全局网络设置页：四个板块共用的并发 / UA / 代理 / 超时 / 重试配置。
///
/// 对应文档第六条（防封禁与并发控制）。这里改的是**全局默认值**；单图源可以在
/// 自己的管理页里覆盖 UA / Cookie / 代理，覆盖优先于本页设置。
///
/// 并发区间由 [NetworkSettings] 收敛（全局 6~12、单域名 2~3）：滑块给的是文档
/// 允许的区间，越界值不会生效——防封参数不能靠用户手滑关掉。
class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  late NetworkSettings _settings = LumeNet.settings;

  final TextEditingController _ua = TextEditingController();
  final TextEditingController _proxy = TextEditingController();

  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _ua.text = _settings.userAgent;
    _proxy.text = _settings.proxy;
  }

  @override
  void dispose() {
    _ua.dispose();
    _proxy.dispose();
    super.dispose();
  }

  void _update(NetworkSettings next) {
    setState(() {
      _settings = next;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final next = _settings.copyWith(
      userAgent: _ua.text.trim(),
      proxy: _proxy.text.trim(),
    );
    try {
      await LumeNet.save(next);
      if (!mounted) return;
      setState(() {
        _settings = LumeNet.settings;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存：新配置立即生效')),
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
      title: '网络设置',
      actions: <Widget>[
        TextButton(
          onPressed: _dirty ? _save : null,
          child: const Text('保存'),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _SectionCard(
            title: '并发控制',
            subtitle: '所有请求（源 / 订阅 / 图片）共用这一份额度，防止多源批量'
                '搜索把同一个网站打爆、导致 IP 被封锁。',
            children: <Widget>[
              _IntSlider(
                label: '全局总并发',
                value: _settings.globalConcurrency,
                min: NetworkSettings.minGlobalConcurrency,
                max: NetworkSettings.maxGlobalConcurrency,
                hint: '同时在跑的请求数上限',
                onChanged: (value) =>
                    _update(_settings.copyWith(globalConcurrency: value)),
              ),
              _IntSlider(
                label: '单域名并发',
                value: _settings.perHostConcurrency,
                min: NetworkSettings.minPerHostConcurrency,
                max: NetworkSettings.maxPerHostConcurrency,
                hint: '同一个网站同时在跑的请求数（防封关键项）',
                onChanged: (value) =>
                    _update(_settings.copyWith(perHostConcurrency: value)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '重试与超时',
            subtitle: '遇到「请求过多（429）」或「服务暂不可用（503）」时自动延时重试；'
                '服务器给了等待时间就听服务器的。',
            children: <Widget>[
              _IntSlider(
                label: '最大重试次数',
                value: _settings.maxRetries,
                min: 0,
                max: 5,
                hint: '不含首次请求；0 表示不重试',
                onChanged: (value) =>
                    _update(_settings.copyWith(maxRetries: value)),
              ),
              _IntSlider(
                label: '单次请求超时',
                value: _settings.timeout.inSeconds,
                min: 3,
                max: 120,
                unit: '秒',
                hint: '超过即视为请求失败',
                onChanged: (value) =>
                    _update(_settings.copyWith(timeout: Duration(seconds: value))),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '身份与代理',
            subtitle: '留空即用内置默认（移动端 Safari UA / 直连）。单个源可以在自己的'
                '管理页里单独覆盖，覆盖优先于这里。',
            children: <Widget>[
              TextField(
                controller: _ua,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '全局 User-Agent',
                  hintText: '留空 = 内置默认 UA',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxy,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '全局代理',
                  hintText: 'http://127.0.0.1:7890；留空 = 直连',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 8),
              const Text(
                '支持 http / https 代理；SOCKS 暂不支持，会如实降级为直连并记入运行日志。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          NoticeCard(
            title: '当前生效',
            subtitle: LumeNet.settings.toString(),
          ),
        ],
      ),
    );
  }
}

/// 一张设置卡片：标题 + 说明 + 若干控件。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// 整数滑块：数值实时显示在标题右侧。
class _IntSlider extends StatelessWidget {
  const _IntSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.hint,
    this.unit,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String? hint;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            Text(
              '$value${unit ?? ''}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          onChanged: (raw) => onChanged(raw.round()),
        ),
        if (hint != null)
          Text(
            hint!,
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
      ],
    );
  }
}
