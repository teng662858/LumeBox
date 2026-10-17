import 'package:flutter/material.dart';

import '../../core/net/network_settings.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

class SourceTestResultDialog extends StatelessWidget {
  const SourceTestResultDialog({
    super.key,
    required this.sourceName,
    required this.result,
  });

  /// 图源显示名（只用于展示，不认识图源内部状态）。
  final String sourceName;

  /// 引擎给出的测试结论（三态 + 说明 + 耗时）。
  final SourceTestResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连通性测试'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _InfoRow(label: '源', value: sourceName),
          _InfoRow(
            label: '状态',
            value: result.status.label,
            valueColor: result.status == SourceTestStatus.ok
                ? LumeTheme.success
                : LumeTheme.danger,
          ),
          _InfoRow(label: '耗时', value: _elapsedText(result.elapsed)),
          _InfoRow(label: '日志', value: _logText(result)),
        ],
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 耗时文本：毫秒 → 「0.8s」；失败可能拿不到耗时，如实给「—」不编造。
  static String _elapsedText(Duration? elapsed) {
    if (elapsed == null) return '—';
    return '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  /// 简短日志：引擎给的说明优先（空结果 / 失败原因）；成功时给一句摘要。
  static String _logText(SourceTestResult result) {
    final message = result.message.trim();
    if (message.isNotEmpty) return message;
    final items = result.itemCount ?? 0;
    final categories = result.categoryCount ?? 0;
    return '首屏返回 $items 条${categories > 0 ? ' · $categories 个分类' : ''}';
  }
}

/// 弹窗里的一行「标签 + 值」：标签定宽，值自动换行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;

  /// 值的颜色（默认白色；状态行用它表达三态）。
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                color: LumeTheme.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                height: 1.4,
                color: valueColor ?? LumeTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单图源设置弹窗的保存结果：网络覆盖 + 换网址 / 账号登入。
///
/// 两份配置分别落库（网络覆盖在 `source` 表的网络列上，换网址 / 账号登入在同一
/// 行的 `site_config` 列里），因此结果里分开带回，调用方各写各的。
class SourceSettingsResult {
  const SourceSettingsResult({required this.network, required this.site});

  final NetworkProfile network;
  final SourceSiteConfig site;
}

/// 单图源设置弹窗：网络（UA / Cookie / 代理 / 桥接）、换网址（镜像 / 自定义域名）、
/// 账号登入（账号 / 密码）。
///
/// 三组都是**按源**的配置，落本板块库，互不跨源、不跨板块。换网址与账号登入这两组
/// 是**给脚本看的**（脚本读 `LumeSource.config`）：宿主不替脚本做登录、也不改写
/// 脚本里的地址——脚本拿到的只是「用户选了哪个站、填了谁的账号」。
class SourceNetworkDialog extends StatefulWidget {
  const SourceNetworkDialog({super.key, required this.source});

  final SourceDescriptor source;

  @override
  State<SourceNetworkDialog> createState() => _SourceNetworkDialogState();
}

class _SourceNetworkDialogState extends State<SourceNetworkDialog> {
  late final TextEditingController _ua = TextEditingController(
    text: widget.source.network.userAgent,
  );
  late final TextEditingController _cookie = TextEditingController(
    text: widget.source.network.cookie,
  );
  late final TextEditingController _proxy = TextEditingController(
    text: widget.source.network.proxy,
  );
  late final TextEditingController _bridge = TextEditingController(
    text: widget.source.network.bridge,
  );

  /// 自定义域名：初值取用户填过的原文（归一后的解析结果由模型负责）。
  late final TextEditingController _domain = TextEditingController(
    text: widget.source.siteConfig.domainOverride,
  );

  late final TextEditingController _account = TextEditingController(
    text: widget.source.siteConfig.account,
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.source.siteConfig.password,
  );

  /// 选中的镜像下标（初值取库里那份，越界由模型收敛）。
  late int _mirrorIndex = widget.source.siteConfig.safeMirrorIndex;

  /// 密码是否明文显示（默认遮蔽）。
  bool _showPassword = false;

  /// 「忽略证书错误」：按源开放，默认关闭（值从该源当前配置读，不会自己变开）。
  late bool _allowBadCertificate = widget.source.network.allowBadCertificate;

  /// 自定义域名的校验原因（保存时才提示，避免边打字边报错）。
  String? _domainError;

  List<String> get _mirrors => widget.source.siteConfig.mirrors;

  @override
  void dispose() {
    _ua.dispose();
    _cookie.dispose();
    _proxy.dispose();
    _bridge.dispose();
    _domain.dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 当前弹窗里的换网址 / 账号登入取值（未归一，保存前由调用方 / 模型归一）。
  SourceSiteConfig get _site => SourceSiteConfig(
    mirrors: _mirrors,
    mirrorIndex: _mirrorIndex,
    domainOverride: _domain.text,
    account: _account.text.trim(),
    password: _password.text,
  );

  void _save() {
    final issue = SourceSiteConfig.domainIssue(_domain.text);
    if (issue != null) {
      setState(() => _domainError = issue);
      return;
    }
    Navigator.of(context).pop(
      SourceSettingsResult(
        network: NetworkProfile(
          userAgent: _ua.text,
          cookie: _cookie.text,
          proxy: _proxy.text,
          bridge: _bridge.text,
          allowBadCertificate: _allowBadCertificate,
        ),
        site: _site,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('源设置 · ${widget.source.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _group(
                '网络配置',
                '留空即继承「设置 → 网络设置」里的全局值。这里的配置只作用于本源，'
                    'Cookie 不与其他源共享。',
                <Widget>[
                  TextField(
                    controller: _ua,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'User-Agent',
                      hintText: '留空 = 用全局 UA',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _cookie,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Cookie',
                      hintText: '留空 = 不带 Cookie',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _proxy,
                    decoration: const InputDecoration(
                      labelText: '代理',
                      hintText: 'http://127.0.0.1:7890；留空 = 用全局代理',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 「桥接服务地址」（用户口径 2.2）：个别站点（OKooK-CDN +
                  // reCAPTCHA v3 那类）的放行绑浏览器会话与 IP 信誉，导不出可复用
                  // Cookie、普通代理也没用——只能把请求转给一个「已过验证的无头
                  // 浏览器桥」（Playwright / Puppeteer）。脚本读 LumeSource.bridge。
                  TextField(
                    controller: _bridge,
                    decoration: const InputDecoration(
                      labelText: '桥接服务地址',
                      hintText: 'http://192.168.1.5:8787；留空 = 不用桥接',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 「忽略证书错误」（用户口径）：站点证书过期时系统会直接拒连
                  // （CERTIFICATE_VERIFY_FAILED），这是唯一出路。**按源开放、默认关**，
                  // 并把风险写在旁边——不能让它看起来像个普通开关。
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowBadCertificate,
                    onChanged: (value) =>
                        setState(() => _allowBadCertificate = value == true),
                    title: const Text('忽略证书错误'),
                    subtitle: const Text(
                      '站点证书过期 / 链不完整时才需要开。开启后该源的请求不再校验证书，'
                      '存在被中间人冒充的风险；证书修好后请立刻关闭。',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _group('换网址', '自定义域名 > 选中镜像 > 主站；脚本没声明镜像时用脚本自带的默认地址。', <Widget>[
                if (_mirrors.isEmpty)
                  const _MirrorTile(label: '默认（脚本未声明镜像）', selected: true)
                else
                  for (var index = 0; index < _mirrors.length; index++)
                    _MirrorTile(
                      label: SourceSiteConfig.hostOf(_mirrors[index]),
                      subtitle: _mirrors[index],
                      primary: index == 0,
                      selected: index == _mirrorIndex,
                      onTap: () => setState(() => _mirrorIndex = index),
                    ),
                const SizedBox(height: 8),
                TextField(
                  controller: _domain,
                  decoration: InputDecoration(
                    labelText: '自定义域名（填了优先）',
                    hintText: 'example.com 或 https://m.example.com',
                    border: const OutlineInputBorder(),
                    errorText: _domainError,
                    suffixIcon: _domain.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() {
                              _domain.clear();
                              _domainError = null;
                            }),
                          ),
                  ),
                  onChanged: (_) {
                    // 清除按钮的出现 / 消失跟着输入走，因此这里也要重建。
                    if (_domainError != null) {
                      setState(() => _domainError = null);
                    } else {
                      setState(() {});
                    }
                  },
                ),
              ]),
              const SizedBox(height: 12),
              _group(
                '账号登入',
                '需要站点本身支持登录（有些站点没有登录功能）。凭据只存在本板块'
                    '这份源记录里，不写日志、不随备份导出；登入会话请用 LumeSource.fs 缓存。',
                <Widget>[
                  TextField(
                    controller: _account,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      hintText: '手机号 / 邮箱 / 用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: !_showPassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _showPassword ? '隐藏' : '显示',
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            SourceSettingsResult(network: NetworkProfile.none, site: _site),
          ),
          child: const Text('清除网络覆盖'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  /// 一组设置：卡片 + 组标题 + 一句话说明。
  Widget _group(String title, String? hint, List<Widget> children) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.titleSize,
              color: LumeTheme.textPrimary,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                hint,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.captionSize,
                  height: 1.4,
                  color: LumeTheme.muted,
                ),
              ),
            ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

/// 镜像可选项（选中态用前置圆点表示，不用 RadioListTile——它在这版 Flutter 上
/// 已经弃用 groupValue / onChanged，界面没必要为了一句弃用告警换写法）。
class _MirrorTile extends StatelessWidget {
  const _MirrorTile({
    required this.label,
    required this.selected,
    this.subtitle,
    this.primary = false,
    this.onTap,
  });

  final String label;
  final String? subtitle;

  /// 是否主站（下标 0）。
  final bool primary;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: selected ? LumeTheme.accent : LumeTheme.muted,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                color: LumeTheme.textPrimary,
              ),
            ),
          ),
          if (primary)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '主站',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.captionSize,
                  color: LumeTheme.muted,
                ),
              ),
            ),
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: LumeTypography.captionSize,
                color: LumeTheme.muted,
              ),
            ),
    );
  }
}
