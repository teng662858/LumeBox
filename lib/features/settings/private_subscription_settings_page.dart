import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/net/private_github_subscription.dart';
import '../../shared/widgets/glass_card.dart';

/// This credential is independent from the repository management write token.
class PrivateSubscriptionSettingsPage extends StatefulWidget {
  const PrivateSubscriptionSettingsPage({super.key});
  @override
  State<PrivateSubscriptionSettingsPage> createState() =>
      _PrivateSubscriptionSettingsPageState();
}

class _PrivateSubscriptionSettingsPageState
    extends State<PrivateSubscriptionSettingsPage> {
  final _owner = TextEditingController(text: 'teng662858');
  final _repository = TextEditingController(text: 'LumeBox-Sources');
  final _ref = TextEditingController(text: 'main');
  final _token = TextEditingController();
  bool _loading = true, _busy = false, _saved = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await PrivateGithubSubscription.load();
      if (!mounted) return;
      if (value != null) {
        _owner.text = value.owner;
        _repository.text = value.repository;
        _ref.text = value.ref;
        _saved = true;
      }
    } catch (_) {
      _message = '无法读取私有订阅凭据，请重试。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final entered = _token.text.trim();
      final token = entered.isNotEmpty
          ? entered
          : (await PrivateGithubSubscription.load())?.token ?? '';
      final value = PrivateGithubSubscription(
        owner: _owner.text.trim(),
        repository: _repository.text.trim(),
        ref: _ref.text.trim(),
        token: token,
      ).validated();
      await PrivateGithubSubscription.save(value);
      _token.clear();
      if (mounted) {
        setState(() {
          _saved = true;
          _message = '已保存。订阅同步会使用此只读凭据。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is FormatException
              ? error.message
              : '保存失败，请检查设备安全存储。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final entered = _token.text.trim();
      final token = entered.isNotEmpty
          ? entered
          : (await PrivateGithubSubscription.load())?.token ?? '';
      final value = PrivateGithubSubscription(
        owner: _owner.text.trim(),
        repository: _repository.text.trim(),
        ref: _ref.text.trim(),
        token: token,
      ).validated();
      final raw = Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: [
          value.owner,
          value.repository,
          ...value.ref.split('/'),
          'subscriptions',
          'all.json',
        ],
      );
      final api = value.apiFor(raw.toString());
      if (api == null) throw const FormatException('仓库地址无效');
      final bytes = await value.download(api);
      final total = jsonDecode(utf8.decode(bytes));
      if (total is! Map ||
          total['format'] != 'lume.total-subscription' ||
          total['sections'] is! Map) {
        throw const FormatException('总订阅格式无效');
      }
      var checkedSource = false;
      final sections = total['sections'] as Map;
      for (final group in sections.values.whereType<List>()) {
        for (final item in group.whereType<String>()) {
          final manifest = value.apiFor(item);
          if (manifest == null) continue;
          final text = utf8.decode(await value.download(manifest));
          for (final line in const LineSplitter().convert(text)) {
            final source = value.apiFor(line.trim());
            if (source == null) continue;
            if ((await value.download(source)).isEmpty) {
              throw const FormatException('源文件为空');
            }
            checkedSource = true;
            break;
          }
          if (checkedSource) break;
        }
        if (checkedSource) break;
      }
      if (!checkedSource) throw const FormatException('总订阅中没有可验证的同仓库源文件');
      if (mounted) setState(() => _message = '连接成功，已验证总订阅、分类清单和源文件；保存后用于同步。');
    } catch (error) {
      if (mounted) setState(() => _message = '连接失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await PrivateGithubSubscription.clear();
      _token.clear();
      if (mounted) {
        setState(() {
          _saved = false;
          _message = '只读授权已移除。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '移除授权失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _owner.dispose();
    _repository.dispose();
    _ref.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '私有 GitHub 订阅',
    effectModule: GlassModule.sources,
    settingsSurface: true,
    child: SettingsSurfaceList(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('为这个仓库配置单独的只读 Token。清单及同一仓库内的源文件通过 GitHub API 读取。'),
        const SizedBox(height: 16),
        TextField(
          controller: _owner,
          enabled: !_loading && !_busy,
          decoration: const InputDecoration(labelText: 'GitHub 用户名或组织'),
        ),
        TextField(
          controller: _repository,
          enabled: !_loading && !_busy,
          decoration: const InputDecoration(labelText: '仓库名'),
        ),
        TextField(
          controller: _ref,
          enabled: !_loading && !_busy,
          decoration: const InputDecoration(labelText: '分支或标签'),
        ),
        TextField(
          controller: _token,
          enabled: !_loading && !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Contents: read Token',
            helperText: _saved ? '已保存；留空保持原 Token' : '需要有此仓库的读取权限',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _loading || _busy ? null : _test,
              child: const Text('测试连接'),
            ),
            FilledButton(
              onPressed: _loading || _busy ? null : _save,
              child: const Text('保存'),
            ),
            if (_saved)
              TextButton(
                onPressed: _busy ? null : _remove,
                child: const Text('移除授权'),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!),
          ),
        const SizedBox(height: 16),
        const Text(
          '添加订阅时使用该仓库的 raw.githubusercontent.com 地址。同仓库、同分支的 GitHub 和旧线路地址会转为鉴权读取；凭据不会加入链接或备份。',
        ),
      ],
    ),
  );
}
