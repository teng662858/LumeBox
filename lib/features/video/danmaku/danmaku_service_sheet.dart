import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import 'dandanplay_client.dart';

/// Accepts a full service prefix, including deployment tokens in its path.
class DanmakuServiceSheet extends StatefulWidget {
  const DanmakuServiceSheet({super.key, required this.initial});
  final DandanplayCredentials initial;
  @override
  State<DanmakuServiceSheet> createState() => _DanmakuServiceSheetState();
}

class _DanmakuServiceSheetState extends State<DanmakuServiceSheet> {
  late final _url = TextEditingController(text: widget.initial.baseUrl);
  late final _id = TextEditingController(text: widget.initial.appId);
  late final _secret = TextEditingController(text: widget.initial.appSecret);
  String? _error;
  bool _saving = false;
  @override
  void dispose() {
    _url.dispose();
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      setState(() => _error = '请填写 HTTPS 服务地址，保留路径前缀，不附查询参数');
      return;
    }
    final config = DandanplayCredentials(
      _id.text.trim(),
      _secret.text.trim(),
      baseUrl: _url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
    );
    if (config.official && !config.configured) {
      setState(() => _error = '官方服务需要已审核的 AppId / AppSecret；兼容服务无需填写');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await config.save();
      if (mounted) Navigator.pop(context, config);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '弹幕服务',
              style: TextStyle(
                fontSize: LumeTypography.pageTitleSize,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text('源弹幕与公共服务弹幕同时加载。服务地址可使用兼容弹弹play的 danmu_api 部署，路径前缀会保留。'),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '服务地址'),
              autocorrect: false,
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _url.text = DandanplayCredentials.defaultBase,
                  ),
                  child: const Text('Cynn'),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _url.text = 'https://dandan.wenjian.de/wenjian',
                  ),
                  child: const Text('Wenjian'),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _url.text = DandanplayCredentials.officialBase,
                  ),
                  child: const Text('弹弹play官方'),
                ),
              ],
            ),
            if (Uri.tryParse(_url.text)?.host == 'api.dandanplay.net') ...[
              TextField(
                controller: _id,
                decoration: const InputDecoration(labelText: 'AppId'),
              ),
              TextField(
                controller: _secret,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'AppSecret'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('官方服务需申请凭证。凭证保存在此设备的钥匙串中。'),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.red,
                  ),
                ),
              ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存并重新加载弹幕'),
            ),
          ],
        ),
      ),
    ),
  );
}
