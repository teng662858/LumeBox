import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock.dart';
import 'comic_settings.dart';
import 'comic_reader_preferences.dart';
import 'comic_image_tools_page.dart';
import '../../core/reading/chapter_display_order.dart';
import '../../shared/widgets/chapter_order_controls.dart';

/// 「阅读设置」二级页（用户口径）：把**不常用**的选项从底部面板搬到这里，
/// 底部面板只留阅读时真正会随手改的那几项（阅读模式 / 侧边距 / 页间距 + 页码）。
///
/// 目前收在这里的：
/// - **背景 / 点击行为 / 翻页方向 / 跨页配对**：都是「设定一次就不动」的口径，
///   放在面板里既占地方又容易被误碰（第十一次反馈：从面板整体搬过来）；
/// - **双击放大**：开关一次就不再动（多数人一直开着或一直关着）；
/// - **保存本页**：把当前这一页的原图存到本板块的导出目录（长按图片也能存，
///   这里给一个显式入口，避免「不知道能长按」的用户找不到）。
///
/// 页面本身不持存储：改动通过 [onChanged] 立刻写回阅读器的设置（与底部面板
/// 共用同一份 `ComicReaderSettings`），因此在这里改完返回阅读页立即生效。
class ComicReaderSettingsPage extends StatefulWidget {
  const ComicReaderSettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onSavePage,
    this.canSavePage = false,
    this.bookmarkCount = 0,
    this.onOpenBookmarks,
    this.onImageTools,
    this.chapterOrder,
    this.preferences,
    this.onPreferencesChanged,
  });

  final ComicReaderSettings settings;
  final ComicReaderPreferences? preferences;
  final VoidCallback? onPreferencesChanged;
  final ChapterDisplayOrder? chapterOrder;
  final Future<void> Function()? onImageTools;
  final ValueChanged<ComicReaderSettings> onChanged;

  /// 这本书当前的书签数（显示用）。
  final int bookmarkCount;

  /// 打开书签列表（顶栏不再放它的入口，挪到这里）。
  final Future<void> Function()? onOpenBookmarks;

  /// 保存当前页（阅读器提供；为 null 时按钮置灰）。
  final Future<void> Function()? onSavePage;

  /// 当前页是否可保存（没图 / 正在保存时为 false）。
  final bool canSavePage;

  @override
  State<ComicReaderSettingsPage> createState() =>
      _ComicReaderSettingsPageState();
}

class _ComicReaderSettingsPageState extends State<ComicReaderSettingsPage> {
  late ComicReaderSettings _settings = widget.settings;

  void _update(ComicReaderSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  void didUpdateWidget(ComicReaderSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _settings = widget.settings;
  }

  void _changePreferences(VoidCallback change) {
    setState(change);
    widget.onPreferencesChanged?.call();
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: interfaceFontWeight(context, FontWeight.w700)),
    ),
  );

  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> change, {
    String? detail,
  }) => ListTile(
    title: Text(title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail != null) Text(detail),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: change,
        ),
      ],
    ),
    trailing: Text(value.round().toString()),
  );

  @override
  Widget build(BuildContext context) {
    final prefs = widget.preferences;
    return GlassScaffold(
      effectModule: GlassModule.comic,
      settingsSurface: true,
      behindBar: true,
      title: '阅读设置',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(
          EdgeInsets.fromLTRB(
            16,
            12,
            16,
            24 + ShellDockScope.bottomInset(context),
          ),
        ),
        children: [
          const Text('与阅读页共用同一份设置，修改后立即生效。'),
          _section('阅读布局'),
          _OptionCard<ComicReadingMode>(
            title: '阅读模式',
            hint: '条漫连续滚动、单页翻页或双页跨页。',
            values: ComicReadingMode.values,
            value: _settings.mode,
            labelOf: (v) => v.label,
            onChanged: (v) => _update(_settings.copyWith(mode: v)),
          ),
          const SizedBox(height: 10),
          _OptionCard<ComicReadingDirection>(
            title: '翻页方向',
            hint: '按作品阅读顺序选择。',
            values: ComicReadingDirection.values,
            value: _settings.direction,
            labelOf: (v) => v.label,
            onChanged: (v) => _update(_settings.copyWith(direction: v)),
          ),
          const SizedBox(height: 10),
          _OptionCard<ComicSpreadMode>(
            title: '跨页配对',
            hint: '双页模式下选择封面是否单独显示。',
            values: ComicSpreadMode.values,
            value: _settings.spreadMode,
            labelOf: (v) => v.label,
            onChanged: (v) => _update(_settings.copyWith(spreadMode: v)),
          ),
          const SizedBox(height: 10),
          _OptionCard<ComicReaderBackground>(
            title: '背景',
            hint: '只改变图片之外的留白底色。',
            values: ComicReaderBackground.values,
            value: _settings.background,
            labelOf: (v) => v.label,
            onChanged: (v) => _update(_settings.copyWith(background: v)),
          ),
          GlassCard(
            child: Column(
              children: [
                _slider(
                  '侧边距',
                  _settings.marginRatio * 100,
                  0,
                  ComicReaderSettings.maxMarginRatio * 100,
                  (v) => _update(_settings.copyWith(marginRatio: v / 100)),
                  detail: '占屏幕宽度的百分比',
                ),
                _slider(
                  '页间距',
                  _settings.pageGap,
                  0,
                  ComicReaderSettings.maxPageGap,
                  (v) => _update(_settings.copyWith(pageGap: v)),
                ),
                if (prefs != null)
                  SwitchListTile(
                    title: const Text('横屏自动双页'),
                    subtitle: const Text('横屏并排显示，回到竖屏恢复原阅读模式'),
                    value: prefs.autoLandscapeDouble,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.autoLandscapeDouble = v),
                  ),
              ],
            ),
          ),
          _section('操作与显示'),
          _OptionCard<ComicTapAction>(
            title: '点击行为',
            hint: '翻页模式可分区点击；条漫点击呼出工具栏。',
            values: ComicTapAction.values,
            value: _settings.tapAction,
            labelOf: (v) => v.label,
            onChanged: (v) => _update(_settings.copyWith(tapAction: v)),
          ),
          GlassCard(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('双击放大'),
                  subtitle: const Text('双击放大到该点，再双击还原'),
                  value: _settings.doubleTapZoom,
                  onChanged: (v) =>
                      _update(_settings.copyWith(doubleTapZoom: v)),
                ),
                if (prefs != null) ...[
                  SwitchListTile(
                    title: const Text('音量键翻页'),
                    subtitle: const Text('音量减下一页，音量加上一页；iOS 可能仍显示系统音量提示'),
                    value: prefs.volumeKeys,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.volumeKeys = v),
                  ),
                  SwitchListTile(
                    title: const Text('灰度阅读'),
                    value: prefs.grayscale,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.grayscale = v),
                  ),
                  SwitchListTile(
                    title: const Text('反色阅读'),
                    value: prefs.inverted,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.inverted = v),
                  ),
                ],
              ],
            ),
          ),
          _section('自动阅读与预加载'),
          GlassCard(
            child: Column(
              children: [
                _slider(
                  '预加载半径',
                  _settings.preloadRadius.toDouble(),
                  1,
                  ComicReaderSettings.maxPreloadRadius.toDouble(),
                  (v) => _update(_settings.copyWith(preloadRadius: v.round())),
                  detail: '前后预加载图片数量，较大值会增加内存与流量',
                ),
                if (prefs != null) ...[
                  _slider(
                    '自动滚动速度',
                    prefs.autoSpeed,
                    10,
                    ComicReaderPreferences.maxAutoSpeed,
                    (v) => _changePreferences(() => prefs.autoSpeed = v),
                    detail: '像素 / 秒，跟随屏幕帧率平滑滚动',
                  ),
                  SwitchListTile(
                    title: const Text('章末自动续读'),
                    subtitle: const Text('自动阅读到章末时继续下一章，关闭后在章末停止'),
                    value: prefs.autoNextChapter,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.autoNextChapter = v),
                  ),
                ],
              ],
            ),
          ),
          if (widget.chapterOrder != null)
            ChapterAutoOrderSwitch(order: widget.chapterOrder!),
          _section('图片与翻译'),
          GlassCard(
            child: Column(
              children: [
                if (widget.onImageTools != null)
                  ListTile(
                    leading: const Icon(Icons.auto_fix_high),
                    title: const Text('当前页 AI 超分 / 上色 / 翻译'),
                    subtitle: const Text('保留原图对照，可保存或分享结果'),
                    onTap: widget.onImageTools,
                  ),
                ListTile(
                  leading: const Icon(Icons.hd_outlined),
                  title: const Text('AI 图片超分与上色'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const ComicImageToolsSettingsPage(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.translate),
                  title: const Text('漫画翻译'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const ComicImageToolsSettingsPage(translation: true),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.gesture),
                  title: const Text('圈选翻译是什么'),
                  subtitle: const Text('圈出一个对话框，合并区域文字后翻译'),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('圈选翻译'),
                      content: const Text(
                        '开启圈选后，在漫画上拖出区域，只识别并翻译圈内的文字。适合自动识别漏掉的对白、多行对话或只想翻译一句话时使用。翻译选定区域会把圈内文字合并成一个对话框翻译；它不是整页重绘。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (prefs != null)
                  SwitchListTile(
                    title: const Text('长按圈选翻译'),
                    subtitle: const Text('开启后长按图片进入区域翻译；关闭后恢复图片操作菜单'),
                    value: prefs.circleTranslation,
                    onChanged: (v) =>
                        _changePreferences(() => prefs.circleTranslation = v),
                  ),
              ],
            ),
          ),
          if (widget.onSavePage != null || widget.onOpenBookmarks != null) ...[
            _section('本书工具'),
            GlassCard(
              child: Column(
                children: [
                  if (widget.onSavePage != null)
                    ListTile(
                      leading: const Icon(Icons.download),
                      title: const Text('保存本页'),
                      trailing: FilledButton.tonal(
                        onPressed: widget.canSavePage
                            ? widget.onSavePage
                            : null,
                        child: const Text('保存'),
                      ),
                    ),
                  if (widget.onOpenBookmarks != null)
                    ListTile(
                      leading: const Icon(Icons.bookmarks_outlined),
                      title: const Text('书签列表'),
                      subtitle: Text('共 ${widget.bookmarkCount} 个书签'),
                      onTap: widget.onOpenBookmarks,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一张「标题 + 说明 + 分段选择」的设置卡。
///
/// 从底部面板搬过来的四项（背景 / 点击行为 / 翻页方向 / 跨页配对）共用这一套版式：
/// 面板里那几行是「一行排完」的紧凑版，到了二级页有整屏宽度，说明文字能完整摊开。
class _OptionCard<T> extends StatelessWidget {
  const _OptionCard({
    required this.title,
    required this.hint,
    required this.values,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<T> values;
  final T value;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: interfaceFontWeight(context, FontWeight.w600),
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              segments: <ButtonSegment<T>>[
                for (final option in values)
                  ButtonSegment<T>(
                    value: option,
                    label: Text(
                      labelOf(option),
                      style: TextStyle(
                        fontWeight: interfaceFontWeight(
                          context,
                          FontWeight.w600,
                        ),
                        fontSize: LumeTypography.captionSize,
                      ),
                    ),
                  ),
              ],
              selected: <T>{value},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}
