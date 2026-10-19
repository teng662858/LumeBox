import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/bangumi/bangumi_client.dart';
import '../../core/bangumi/bangumi_sync.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../settings/bangumi_settings_page.dart';

/// 视频详情页的「Bangumi 追番」面板：搜索作品、手动确认匹配、绑定章节。
///
/// 不自动把标题直接当 Bangumi 条目：源标题常带站点前缀，误绑会把进度写到
/// 别人的条目上。搜索结果的最终选择始终由用户点选。
Future<void> showBangumiMatchSheet({
  required BuildContext context,
  required ReadingLibrary library,
  required SourceItem item,
  required String initialTitle,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => BangumiMatchSheet(
    library: library,
    item: item,
    initialTitle: initialTitle,
  ),
);

class BangumiMatchSheet extends StatefulWidget {
  const BangumiMatchSheet({
    super.key,
    required this.library,
    required this.item,
    required this.initialTitle,
  });

  final ReadingLibrary library;
  final SourceItem item;
  final String initialTitle;

  @override
  State<BangumiMatchSheet> createState() => _BangumiMatchSheetState();
}

class _BangumiMatchSheetState extends State<BangumiMatchSheet> {
  final settings = BangumiSettings.instance;
  late final title = TextEditingController(text: widget.initialTitle);
  BangumiUser? user;
  BangumiBinding? binding;
  List<BangumiSubject> results = const <BangumiSubject>[];
  bool loading = true, busy = false;
  String? message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await settings.load();
    final token = await settings.token();
    BangumiUser? current;
    if (token.isNotEmpty) {
      final client = BangumiClient(token);
      try {
        current = await client.me();
      } catch (_) {
        // 令牌失效时保留输入框，让用户重填；不在这里弹错。
      } finally {
        client.close();
      }
    }
    final saved = BangumiBinding.decode(
      widget.library.setting(BangumiBinding.keyFor(widget.item.id)),
    );
    if (!mounted) return;
    setState(() {
      user = current;
      binding = saved;
      loading = false;
    });
  }

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (busy) return;
    final keyword = title.text.trim();
    if (keyword.isEmpty) {
      setState(() => message = '先填写要搜索的番剧名');
      return;
    }
    final token = await settings.token();
    if (token.isEmpty) {
      setState(() => message = '请先在设置里绑定 Bangumi 账号');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    final client = BangumiClient(token);
    try {
      final found = await client.search(keyword);
      if (mounted) {
        setState(() {
          results = found;
          message = found.isEmpty ? '没有搜到番剧，换个简短的标题再试' : null;
        });
      }
    } on BangumiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } catch (error) {
      if (mounted) setState(() => message = '搜索失败：$error');
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _bind(BangumiSubject subject) async {
    if (busy) return;
    final token = await settings.token();
    if (token.isEmpty) return;
    setState(() {
      busy = true;
      message = null;
    });
    final client = BangumiClient(token);
    var episodes = const <int>[];
    String? warning;
    try {
      try {
        episodes = [
          for (final episode in await client.episodes(subject.id)) episode.id,
        ];
      } catch (error) {
        warning = '章节列表暂时没取到，进度同步时会重试';
      }
      final value = BangumiBinding(
        subjectId: subject.id,
        name: subject.displayName,
        episodes: episodes,
      );
      widget.library.setSetting(
        BangumiBinding.keyFor(widget.item.id),
        value.encode(),
      );
      BangumiSyncService.instance.forget(widget.item.id);
      if (mounted) setState(() => binding = value);
      final progress = _currentProgress();
      if (progress != null) {
        await BangumiSyncService.instance.afterProgress(
          widget.library,
          progress,
          force: true,
        );
      }
      if (mounted) {
        setState(() {
          results = const <BangumiSubject>[];
          message = warning ?? '已绑定《${subject.displayName}》，观看进度会同步到 Bangumi';
        });
      }
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (busy) return;
    final progress = _currentProgress();
    if (progress == null) {
      setState(() => message = '还没有播放进度，先看一集再同步');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await BangumiSyncService.instance.afterProgress(
        widget.library,
        progress,
        force: true,
      );
      if (mounted) {
        setState(() => message = '已同步：第 ${progress.chapterIndex + 1} 集');
      }
    } catch (error) {
      if (mounted) setState(() => message = '同步失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _unbind() async {
    widget.library.setSetting(BangumiBinding.keyFor(widget.item.id), '');
    BangumiSyncService.instance.forget(widget.item.id);
    if (mounted) {
      setState(() {
        binding = null;
        message = '已解除绑定；本地阅读进度保留';
      });
    }
  }

  VideoProgress? _currentProgress() {
    final saved = widget.library.progress(widget.item.id);
    return saved is VideoProgress ? saved : null;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: <Widget>[
          Text(
            'Bangumi 追番',
            style: TextStyle(
              fontSize: LumeTypography.sectionTitleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            user == null ? '未连接 Bangumi 账号' : '已连接 ${user!.displayName}',
            style: TextStyle(
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
            ),
          ),
          const SizedBox(height: 12),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (user == null) ...<Widget>[
            GlassCard(
              radius: 14,
              padding: const EdgeInsets.all(14),
              child: Text(
                '先在设置 → 数据与网络 → Bangumi 追番同步里粘贴 Access Token。'
                '绑定作品后，播放到第几集会自动写入 Bangumi。',
                style: TextStyle(
                  fontSize: LumeTypography.bodySize,
                  height: 1.6,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BangumiSettingsPage(),
                  ),
                );
                await _load();
              },
              child: const Text('去绑定账号'),
            ),
          ] else if (binding != null) ...<Widget>[
            GlassCard(
              radius: 14,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '已绑定《${binding!.name}》',
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Bangumi 条目 #${binding!.subjectId} · '
                    '${binding!.episodes.isEmpty ? '章节待同步' : '${binding!.episodes.length} 集'}',
                    style: TextStyle(
                      fontSize: LumeTypography.descriptionSize,
                      color: LumeTheme.descriptionColor,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonal(
                        onPressed: busy ? null : _syncNow,
                        child: const Text('立即同步'),
                      ),
                      OutlinedButton(
                        onPressed: busy ? null : _unbind,
                        child: const Text('解除绑定'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                binding = null;
                message = null;
              }),
              child: const Text('换一个 Bangumi 条目'),
            ),
          ] else ...<Widget>[
            TextField(
              controller: title,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                labelText: '搜索番剧',
                hintText: '用完整标题或通用译名更容易命中',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: busy ? null : _search,
              icon: const LumeIcon(Icons.search, slot: 'bangumi_match_sheet.1'),
              label: Text(busy ? '搜索中…' : '搜索 Bangumi'),
            ),
            const SizedBox(height: 8),
            for (final subject in results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(subject.displayName),
                subtitle: Text(
                  [
                    if (subject.name.trim().isNotEmpty &&
                        subject.name != subject.displayName)
                      subject.name,
                    if (subject.date.trim().isNotEmpty) subject.date,
                    '#${subject.id}',
                  ].join(' · '),
                ),
                onTap: busy ? null : () => _bind(subject),
              ),
          ],
          if (message != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              message!,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
                color: message!.startsWith('已绑定') || message!.startsWith('已同步')
                    ? LumeTheme.textPrimary
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
