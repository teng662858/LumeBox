import '../../shared/widgets/native_glass_controls.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:flutter/material.dart';

import 'dart:io';

import '../../core/net/site_session_pool.dart';
import '../../core/net/lume_http.dart';

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
  bool _siteDirty = false;

  Future<void> _editSite() async {
    final domain = TextEditingController();
    final ua = TextEditingController();
    final accepted = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('按站点设置 UA'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: domain,
                decoration: const InputDecoration(labelText: '域名或网址'),
                onChanged: (value) {
                  final host = Uri.tryParse(
                    value.contains('://') ? value : 'https://$value',
                  )?.host;
                  ua.text = SiteSessionPool.shared.userAgents[host] ?? '';
                },
              ),
              TextField(
                controller: ua,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'User-Agent，留空恢复默认',
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => ua.text = LumeHttp.defaultUserAgent,
                    child: const Text('移动 Safari'),
                  ),
                  TextButton(
                    onPressed: () => ua.text = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
                    child: const Text('桌面 Safari'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      try {
        SiteSessionPool.shared.setUserAgent(domain.text, ua.text);
        await SiteSessionPool.shared.save();
        LumeNet.queue.clearInvalidLinks();
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }
    // Dialog dismissal animations can still be using these controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    domain.dispose();
    ua.dispose();
  }

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
      if (_siteDirty) await SiteSessionPool.shared.save();
      _siteDirty = false;
      if (!mounted) return;
      setState(() {
        _settings = LumeNet.settings;
        _dirty = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存：新配置立即生效')));
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      effectModule: GlassModule.settings,
      behindBar: true,
      title: '网络设置',
      actions: <Widget>[
        TextButton(onPressed: _dirty ? _save : null, child: const Text('保存')),
      ],
      child: ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: <Widget>[
          _SectionCard(
            title: '并发控制',
            subtitle:
                '所有请求（源 / 订阅 / 图片）共用这一份额度，防止多源批量'
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
            title: '站点会话与网页调试',
            subtitle: 'Cookie 按域名和路径共享；站点 UA 在网页、JS、Python 请求之间保持一致。',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('按站点设置 UA'),
                subtitle: Text(
                  '已配置 ${SiteSessionPool.shared.userAgents.length} 个站点',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _editSite,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Safari 远程网页调试'),
                subtitle: const Text(
                  'iOS 16.4 起可用；开启后可在连接的 Mac Safari 开发菜单检查网页。',
                ),
                value: SiteSessionPool.shared.inspectable,
                onChanged: (value) => setState(() {
                  SiteSessionPool.shared.inspectable = value;
                  _siteDirty = true;
                  _dirty = true;
                }),
              ),
              TextButton(
                onPressed: () {
                  LumeNet.queue.clearInvalidLinks();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('失效链接标记已清除，可重新请求')),
                  );
                },
                child: const Text('清除失效链接标记'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '重试与超时',
            subtitle:
                '遇到请求过多（429）或临时服务错误（500/502/503/504）时自动退避重试；'
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
                onChanged: (value) => _update(
                  _settings.copyWith(timeout: Duration(seconds: value)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '身份与代理',
            subtitle:
                'iOS 统一跟随系统代理／VPN。UA 留空使用内置默认；单个源可以在自己的'
                '管理页里单独覆盖，覆盖优先于这里。',
            children: <Widget>[
              TextField(
                controller: _ua,
                minLines: 1,
                maxLines: 3,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                  fontSize: LumeTypography.bodySize,
                ),
                decoration: const InputDecoration(
                  labelText: '全局 User-Agent',
                  hintText: '留空 = 内置默认 UA',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxy,
                enabled: !Platform.isIOS,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                  fontSize: LumeTypography.bodySize,
                ),
                decoration: const InputDecoration(
                  labelText: '其他平台代理（iOS 跟随系统）',
                  hintText: 'http://127.0.0.1:7890；留空 = 直连',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 8),
              Text(
                'iOS 请在系统 Wi-Fi 或 VPN 中设置网络环境，源脚本不另外建立代理隧道。其他平台支持 HTTP/HTTPS 代理。',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  fontSize: LumeTypography.descriptionSize,
                  height: 1.5,
                  color: LumeTheme.descriptionColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          NoticeCard(title: '当前生效', subtitle: LumeNet.settings.toString()),
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
            style: TextStyle(
              fontSize: LumeTypography.sectionTitleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              height: 1.5,
              color: LumeTheme.descriptionColor,
            ),
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
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.titleSize,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            Text(
              '$value${unit ?? ''}',
              style: TextStyle(
                fontSize: LumeTypography.titleSize,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textPrimary,
              ),
            ),
          ],
        ),
        NativeGlassSlider(
          value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          onChanged: (raw) => onChanged(raw.round()),
        ),
        if (hint != null)
          Text(
            hint!,
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              height: 1.5,
              color: LumeTheme.descriptionColor,
            ),
          ),
      ],
    );
  }
}
