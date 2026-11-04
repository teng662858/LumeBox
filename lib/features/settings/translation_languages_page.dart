import '../comic/comic_image_tools_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/translation/translation_languages.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class TranslationLanguagesPage extends StatefulWidget {
  const TranslationLanguagesPage({super.key});
  @override
  State<TranslationLanguagesPage> createState() =>
      _TranslationLanguagesPageState();
}

class _TranslationLanguagesPageState extends State<TranslationLanguagesPage>
    with WidgetsBindingObserver {
  final _service = const TranslationLanguages();
  List<TranslationLanguagePack> _languages = [];
  bool _loading = true, _busy = false;
  String? _error, _job;
  static int _sequence = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reload());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy && !_loading) {
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final job = _job;
    if (job != null) unawaited(_service.cancel(job).catchError((Object _) {}));
    super.dispose();
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? '语言包操作失败，请重试'
      : error is MissingPluginException
      ? '系统翻译语言包需要 iOS 18 或以上'
      : '无法读取语言包状态，请重试';

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final languages = await _service.load();
      if (mounted) setState(() => _languages = languages);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(List<TranslationLanguagePack> languages) async {
    if (_busy || languages.isEmpty) return;
    final id = 'language-packs-${_sequence++}';
    setState(() {
      _busy = true;
      _job = id;
    });
    String message = '语言包准备完成，所有源均可共用';
    try {
      await _service.download(
        languages.map((language) => language.code).toList(),
        id: id,
      );
    } catch (error) {
      message = _message(error);
    } finally {
      _job = null;
      if (mounted) {
        setState(() => _busy = false);
        await _reload();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = _languages
        .where((language) => !language.installed)
        .toList();
    return GlassScaffold(
      title: '翻译语言包',
      effectModule: GlassModule.settings,
      actions: [
        IconButton(
          tooltip: '刷新语言包状态',
          onPressed: _loading || _busy ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SettingsPageIntro(
            title: '一次下载，各个源共用',
            description: '这些语言包供标题和漫画的系统本地翻译共用；AI 翻译不需要下载语言包。下载时 iOS 可能逐项要求确认，建议连接 Wi-Fi。',
          ),
          SettingsEntryCard(
            icon: Icons.translate_rounded,
            iconColor: const Color(0xFF366AAE),
            title: '全局翻译设置',
            subtitle: '系统翻译、AI 翻译与失败自动补译',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const ComicImageToolsSettingsPage(translation: true),
              ),
            ),
          ),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null) ...[
            Text(_error!),
            TextButton(onPressed: _reload, child: const Text('重新读取')),
          ] else ...[
            const SettingsGroupTitle('语言包'),
            Text(
              '已就绪 ${_languages.length - missing.length} / ${_languages.length}',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('download-all-translation-languages'),
              onPressed: _busy || missing.isEmpty
                  ? null
                  : () => _download(missing),
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text(
                _busy
                    ? '正在准备语言包…'
                    : _languages.isEmpty
                    ? '当前无可下载语言包'
                    : missing.isEmpty
                    ? '所有可用语言包已就绪'
                    : '下载全部未安装语言包（${missing.length}）',
              ),
            ),
            const SizedBox(height: 12),
            if (_languages.isNotEmpty)
              SettingsGroupCard(
                children: [
                  for (final language in _languages)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF366AAE)
                            .withValues(alpha: .12),
                        child: const Icon(
                          Icons.language_rounded,
                          color: Color(0xFF366AAE),
                        ),
                      ),
                      title: Text(language.name),
                      subtitle: Text('${language.code} → 简体中文'),
                      trailing: language.installed
                          ? const Text('已就绪')
                          : TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _download([language]),
                              child: const Text('下载'),
                            ),
                    ),
                ],
              ),
            if (_languages.isEmpty) const SettingsNoteCard('当前设备没有可用的翻译语言包'),
          ],
          const SizedBox(height: 16),
          const SettingsFooterNote(
            '这里只列出当前系统支持译为简体中文的语言。不支持的语种无法通过下载解决。安装状态由 iOS 管理，系统清理语言包后可在这里重新下载。',
          ),
        ],
      ),
    );
  }
}
