import '../../core/source/source_settings_policy.dart';
import '../../core/cache/section_memory_cache.dart';
import 'source_extension_editor.dart';
import '../../core/source/source_extension_settings.dart';
import 'source_login_page.dart';
import '../../core/session/section.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/net/network_settings.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

enum SourceQuickAction { pin, preferences, browse, test, update, delete }

Future<SourceQuickAction?> showSourceQuickActions({
  required BuildContext context,
  required String name,
  bool pinned = false,
  bool subscribed = false,
  bool maintenance = true,
}) {
  return showGlassDialog<SourceQuickAction>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .28),
    builder: (dialogContext) => Dialog(
      constraints: const BoxConstraints(maxWidth: 320),
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: FrostedGlassWidget(
          nativeGlass: false,
          neutralTint: true,
          color: LumeTheme.surface,
          opacity: .96,
          radius: 24,
          child: Material(
            color: LumeTheme.surface,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final entry in [
                      if (maintenance)
                        (
                          SourceQuickAction.pin,
                          Icons.push_pin_outlined,
                          pinned ? '取消置顶' : '置顶此源',
                        ),
                      (SourceQuickAction.preferences, Icons.tune, '源设置'),
                      (SourceQuickAction.browse, Icons.open_in_new, '浏览'),
                      if (maintenance)
                        (SourceQuickAction.test, Icons.network_check, '测试连通性'),
                      if (maintenance)
                        (SourceQuickAction.update, Icons.refresh, '更新订阅源'),
                      (SourceQuickAction.delete, Icons.delete_outline, '删除源'),
                    ])
                      ListTile(
                        leading: LumeIcon(
                          entry.$2,
                          slot: 'source_picker_sheet.1',
                          variant: true,
                          color: entry.$1 == SourceQuickAction.delete
                              ? LumeTheme.danger
                              : LumeTheme.accent,
                        ),
                        title: Text(entry.$3),
                        enabled:
                            entry.$1 != SourceQuickAction.update || subscribed,
                        onTap: () => Navigator.pop(dialogContext, entry.$1),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

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
/// 由脚本读取 `LumeSource.config`；宿主按源声明映射站点与资源线路，
/// 账号登录业务仍由源实现，网页登录使用当前生效站点。
class SourceNetworkDialog extends StatefulWidget {
  const SourceNetworkDialog({
    super.key,
    required this.source,
    this.onSettingAction,
    this.embedded = false,
  });

  final SourceDescriptor source;
  final bool embedded;
  final Future<String> Function(
    SourceSetting,
    Map<String, Object?>,
    SourceSiteConfig,
    Map<String, Object?>,
  )?
  onSettingAction;

  @override
  State<SourceNetworkDialog> createState() => SourceNetworkDialogState();
}

class SourceNetworkDialogState extends State<SourceNetworkDialog>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.embedded;
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
  late SourceRoute _images = widget.source.siteConfig.images,
      _video = widget.source.siteConfig.video;
  late Map<String, Object?> _extra = Map.of(
    widget.source.siteConfig.resolvedSourceSettings,
  );
  late Map<String, Object?> _common = Map.of(
    widget.source.siteConfig.resolvedCommonSettings,
  );
  String? _imageError, _videoError, _extraError;

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
  SourceSiteConfig get draftSite => _site;
  SourceSiteConfig get _site => widget.source.siteConfig.copyWith(
    mirrors: _mirrors,
    mirrorIndex: _mirrorIndex,
    domainOverride: _domain.text,
    account: _account.text.trim(),
    password: _password.text,
    images: _images,
    video: _video,
    settingValues: {...widget.source.siteConfig.settingValues, ..._extra},
    appSettingValues: {
      ...widget.source.siteConfig.appSettingValues,
      ..._common,
    },
  );

  Future<String> _runSettingAction(
    SourceSetting field,
    Map<String, Object?> values,
    Map<String, Object?> inputs,
  ) async {
    values = {..._extra, ...values, ..._common};
    for (final definition in [
      ...widget.source.siteConfig.commonDefinitions,
      ...widget.source.siteConfig.sourceDefinitions,
    ]) {
      final error = definition.valueIssue(
        values[definition.key] ?? definition.fallback,
      );
      if (error != null) return '${definition.title}：$error';
    }
    if (widget.onSettingAction != null) {
      return widget.onSettingAction!(field, values, _site, inputs);
    }
    final section = widget.source.section;
    if (section == null) return '当前源没有可用板块';
    final manager = LumeSources.manager(section);
    switch (field.action) {
      case 'login':
      case 'openWebsite':
        // 源给这个操作带了 url 就打开那个页面（例如发布页/公告页），否则仍打开当前站点。
        final external = field.url.isNotEmpty;
        final address = external
            ? field.url
            : _site.resolvedDomain.isEmpty
            ? widget.source.siteUrl
            : _site.resolvedDomain;
        if (SourceRoute.normalizeBase(address) == null) return '请先填写有效的站点地址';
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => SourceLoginPage(
              section: section,
              sourceId: widget.source.id,
              name: widget.source.name,
              url: address,
              userAgent: _ua.text,
              loginMode: !external,
              title: external ? field.title : null,
            ),
          ),
        );
        return '已返回源设置';
      case 'testConnection':
        return (await manager.testConnectivity(widget.source.id)).message;
      case 'clearCache':
        return '已清理 ${SectionMemoryCache.instance.removeSource(section, widget.source.id)} 条浏览缓存';
      default:
        final source = await manager.open(widget.source.id);
        if (source is! JsDataSource) return '当前源不支持自定义设置操作';
        final result = await source.settingsAction(
          field.key,
          settings: values,
          inputs: inputs,
          config: _site.toScriptJson(cookie: _cookie.text),
        );
        final message = result is String
            ? result
            : result is Map
            ? '${result['message'] ?? '操作已完成'}'
            : '操作已完成';
        return message.substring(0, message.length.clamp(0, 2000));
    }
  }

  SourceSettingsResult? readResult() {
    final issue = SourceSiteConfig.domainIssue(_domain.text);
    if (issue != null) {
      setState(() => _domainError = issue);
      return null;
    }
    _imageError =
        _images.custom.trim().isNotEmpty &&
            SourceRoute.normalizeBase(_images.custom) == null
        ? '请填写有效的 HTTP(S) 图床地址'
        : null;
    _videoError =
        _video.custom.trim().isNotEmpty &&
            SourceRoute.normalizeBase(_video.custom) == null
        ? '请填写有效的 HTTP(S) 视频 CDN 地址'
        : null;
    _extraError = null;
    for (final field in [
      ...widget.source.siteConfig.sourceDefinitions,
      ...widget.source.siteConfig.commonDefinitions,
    ]) {
      final raw = field.appOwned ? _common[field.key] : _extra[field.key];
      final actual = field.valueIssue(raw ?? field.fallback);
      if (actual != null) {
        _extraError = '${field.title}：$actual';
        break;
      }
    }
    if (_imageError != null || _videoError != null || _extraError != null) {
      setState(() {});
      return null;
    }
    return SourceSettingsResult(
      network: NetworkProfile(
        userAgent: _ua.text,
        cookie: _cookie.text,
        proxy: _proxy.text,
        bridge: _bridge.text,
        allowBadCertificate: _allowBadCertificate,
      ),
      site: _site,
    );
  }

  int _resetRevision = 0;
  void reset() {
    setState(() {
      for (final controller in [
        _ua,
        _cookie,
        _proxy,
        _bridge,
        _domain,
        _account,
        _password,
      ]) {
        controller.clear();
      }
      _allowBadCertificate = false;
      _mirrorIndex = 0;
      _images = _images.copyWith(custom: '', selected: '');
      _video = _video.copyWith(custom: '', selected: '');
      _extra = {
        for (final f in widget.source.siteConfig.sourceDefinitions)
          f.key: f.fallback,
      };
      _common = {
        for (final f in widget.source.siteConfig.commonDefinitions)
          f.key: f.fallback,
      };
      _domainError = _imageError = _videoError = _extraError = null;
      _resetRevision++;
    });
  }

  void _save() {
    final result = readResult();
    if (result != null) Navigator.of(context).pop(result);
  }

  Future<void> _openLogin() async {
    final issue = SourceSiteConfig.domainIssue(_domain.text);
    if (issue != null) {
      setState(() => _domainError = issue);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(issue)));
      return;
    }
    final address = _site.resolvedDomain.isEmpty
        ? widget.source.siteUrl
        : _site.resolvedDomain;
    if (SourceRoute.normalizeBase(address) == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先填写有效的站点地址')));
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourceLoginPage(
          section: widget.source.section ?? Section.comic,
          sourceId: widget.source.id,
          name: widget.source.name,
          url: address,
          userAgent: _ua.text,
          credentials: SourceLoginCredentials(_account.text, _password.text),
          onCredentialsChanged: (value) {
            if (!mounted) return;
            setState(() {
              _account.text = value.account;
              _password.text = value.password;
            });
          },
        ),
      ),
    );
  }

  List<SourceSetting> get _extensionFields =>
      SourceSettingsPolicy.visibleExtensions(
        widget.source.siteConfig.sourceDefinitions,
        embedded: widget.embedded,
      );

  Future<void> _openExtensions() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('源扩展功能')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.source.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (_extensionFields.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('此源暂无扩展功能。源作者提供的额外开关和操作会显示在这里。'),
                )
              else
                SourceExtensionEditor(
                  definitions: _extensionFields,
                  initialValues: _extra,
                  onChanged: (values) {
                    if (mounted) setState(() => _extra = values);
                  },
                  onAction: _runSettingAction,
                ),
              if (_extensionFields.isNotEmpty) const Text('修改后返回源设置，点“保存”生效。'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _group('站点账号', null, <Widget>[
          Row(
            children: [
              if (widget.embedded)
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '站点账号',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('登录后自动同步', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              if (widget.source.siteUrl.isNotEmpty ||
                  _site.resolvedDomain.isNotEmpty)
                FilledButton.tonalIcon(
                  key: const ValueKey('source-account-web-login'),
                  icon: const Icon(Icons.login),
                  label: const Text('登录站点'),
                  onPressed: _openLogin,
                ),
            ],
          ),
          if (!widget.embedded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('登录后自动同步，完成后直接返回即可。'),
            ),
        ]),
        const SizedBox(height: 12),
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
        _group('换网址', '源提供多个地址时可在此切换；填写自定义域名后优先使用自定义地址。', <Widget>[
          if (widget.embedded && _mirrors.length > 1)
            DropdownButtonFormField<int>(
              key: ValueKey('mirror-$_resetRevision'),
              initialValue: _mirrorIndex,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '站点线路'),
              items: [
                for (var i = 0; i < _mirrors.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i == 0 ? "主站 · " : ""}${SourceSiteConfig.hostOf(_mirrors[i])}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _mirrorIndex = value);
              },
            )
          else if (widget.embedded && _mirrors.length == 1)
            Text('主站 · ${SourceSiteConfig.hostOf(_mirrors.first)}')
          else if (_mirrors.isEmpty)
            const _MirrorTile(label: '使用源默认站点', selected: true)
          else
            for (var index = 0; index < _mirrors.length && index < 3; index++)
              _MirrorTile(
                label: SourceSiteConfig.hostOf(_mirrors[index]),
                subtitle: _mirrors[index],
                primary: index == 0,
                selected: index == _mirrorIndex,
                onTap: () => setState(() => _mirrorIndex = index),
              ),
          if (!widget.embedded && _mirrors.length > 3)
            ExpansionTile(
              title: Text('更多镜像（${_mirrors.length - 3}）'),
              initiallyExpanded: _mirrorIndex >= 3,
              children: [
                for (var index = 3; index < _mirrors.length; index++)
                  _MirrorTile(
                    label: SourceSiteConfig.hostOf(_mirrors[index]),
                    subtitle: _mirrors[index],
                    selected: index == _mirrorIndex,
                    onTap: () => setState(() => _mirrorIndex = index),
                  ),
              ],
            ),
          if (_mirrors.length <= 1)
            Text(
              _mirrors.isEmpty ? '此源未提供镜像列表，可在下方填写已知的备用地址。' : '此源只提供主站，暂无备用镜像。',
            ),
          Text(
            '当前生效：${_site.resolvedDomain.isNotEmpty
                ? _site.resolvedDomain
                : widget.source.siteUrl.isNotEmpty
                ? widget.source.siteUrl
                : '沿用源默认地址'}',
          ),
          if (_domain.text.trim().isNotEmpty)
            const Text('自定义站点优先；保留自定义地址时，镜像选择暂不生效。'),
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
                      icon: const LumeIcon(
                        Icons.clear,
                        slot: 'source_action_dialogs.1',
                      ),
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
        _group('资源线路', '图床与视频 CDN 独立选择，只替换源明确声明可互换的地址。', [
          SourceRouteEditor(
            key: ValueKey('images-$_resetRevision'),
            compact: widget.embedded,
            title: '图床',
            route: _images,
            error: _imageError,
            onChanged: (v) => setState(() => _images = v),
          ),
          const SizedBox(height: 16),
          SourceRouteEditor(
            key: ValueKey('video-$_resetRevision'),
            compact: widget.embedded,
            title: '视频 CDN',
            route: _video,
            error: _videoError,
            onChanged: (v) => setState(() => _video = v),
          ),
        ]),
        const SizedBox(height: 12),
        _group('App 通用设置', 'App 定义规则和优先级；用户选择优先于源建议。', [
          SourceExtensionEditor(
            key: ValueKey('common-$_resetRevision'),
            actionHeading:
                widget.embedded &&
                    widget.source.siteConfig.commonDefinitions.isEmpty
                ? '常用参数'
                : null,
            definitions: [
              ...widget.source.siteConfig.commonDefinitions,
              ...SourceSettingsPolicy.hostActions.where(
                (f) => !widget.embedded || f.action == 'testConnection',
              ),
            ],
            initialValues: _common,
            onChanged: (v) => _common = v,
            onAction: _runSettingAction,
          ),
          if (_extraError != null)
            Text(
              _extraError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ]),
        if (widget.embedded || _extensionFields.isNotEmpty) ...[
          const SizedBox(height: 12),
          if (widget.embedded)
            GlassCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('source-extensions-entry'),
                leading: const Icon(Icons.extension_outlined),
                title: const Text('源扩展功能'),
                subtitle: Text(
                  _extensionFields.isEmpty
                      ? '本源暂未提供额外功能'
                      : '${_extensionFields.length} 项 · ${_extensionFields.take(2).map((field) => field.title).join('、')}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openExtensions,
              ),
            )
          else
            _group('源扩展功能', '由此源提供；只对当前源生效。', [
              SourceExtensionEditor(
                key: ValueKey('extra-$_resetRevision'),
                definitions: _extensionFields,
                initialValues: _extra,
                onChanged: (v) => _extra = v,
                onAction: _runSettingAction,
              ),
            ]),
        ],
        const SizedBox(height: 12),
      ],
    );
    if (widget.embedded) {
      final items = content.children.where((w) => w is! SizedBox).toList();
      // Keep one account area first, with advanced network fields last.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [items.first, ...items.skip(2), items[1]],
      );
    }
    return AlertDialog(
      title: Text('源设置 · ${widget.source.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: content),
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
    if (widget.embedded) {
      final advanced = title == '网络配置';
      final inlineAction =
          title == 'App 通用设置' &&
          widget.source.siteConfig.commonDefinitions.isEmpty;
      final inlineHeading = inlineAction || title == '站点账号';
      final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final child in children.where((item) => item is! SizedBox))
            Padding(
              padding: EdgeInsets.only(bottom: inlineAction ? 0 : 6),
              child: child,
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassCard(
          padding: const EdgeInsets.all(12),
          child: advanced
              ? ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('高级网络设置'),
                  children: [body],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!inlineHeading)
                      Text(
                        title == 'App 通用设置' ? '常用参数' : title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (!inlineHeading) const SizedBox(height: 8),
                    body,
                  ],
                ),
        ),
      );
    }
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
      leading: LumeIcon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        slot: 'source_action_dialogs.3',
        variant: true,
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
