import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 播放源弹窗：控制栏右侧那颗小信息图标点开的底部面板（用户要求）。
///
/// 为什么把地址从控制栏上收进来：完整的播放链接又长又没信息量，直接铺在控制栏
/// 中间把进度条与按钮都挤下去了。收进弹窗后：控制栏干净了，而「看地址、复制地址、
/// 换线路、手动贴地址」四件事一件不少——**原有的读取与切换逻辑（宿主页）不变**，
/// 只是换了个入口。
///
/// 线路列表与「清晰度」按钮走的是同一份数据与同一个回调（宿主页的 `_selectQuality`），
/// 因此两条入口永远一致。
class PlayerSourceSheet extends StatefulWidget {
  const PlayerSourceSheet({
    super.key,
    required this.address,
    this.qualities = const <VideoQuality>[],
    this.currentIndex = 0,
    this.onSelectQuality,
    required this.onPlayAddress,
  });

  /// 当前播放地址（为空表示还没装载任何媒体）。
  final String address;

  /// 候选线路（图源给多条时才有）；单条 / 空时不出「线路」一栏。
  final List<VideoQuality> qualities;

  /// 当前线路下标。
  final int currentIndex;

  /// 切线路（宿主页负责重新装载并提示）。
  final ValueChanged<int>? onSelectQuality;

  /// 播放手动输入的地址；返回 null 表示已交出去，否则返回给用户看的错误文案
  /// （由本弹窗就地展示，不弹 SnackBar——用户的手还在输入框上）。
  final Future<String?> Function(String text) onPlayAddress;

  @override
  State<PlayerSourceSheet> createState() => _PlayerSourceSheetState();
}

class _PlayerSourceSheetState extends State<PlayerSourceSheet> {
  late final TextEditingController _input =
      TextEditingController(text: widget.address);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onPlayAddress(_input.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    // 交出去了才关面板；出错就留在原地让用户改。
    if (error == null) Navigator.of(context).pop();
  }

  Future<void> _copy() async {
    final text = widget.address.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已复制播放地址')),
    );
  }

  /// 线路那一行的副标题：地址太长，只留「域名/最后一段」这类一眼能分辨的部分。
  static String _shortUrl(Uri uri) {
    final text = uri.toString();
    if (text.length <= 64) return text;
    return '…${text.substring(text.length - 63)}';
  }

  @override
  Widget build(BuildContext context) {
    final address = widget.address.trim();
    final lines = widget.qualities;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: Padding(
            // 键盘顶上来时把面板一起顶上去（贴地址离不开键盘）。
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '播放源',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: LumeTheme.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: <Widget>[
                        GlassCard(
                          radius: 14,
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _label('当前播放地址'),
                              const SizedBox(height: 6),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Expanded(
                                    child: address.isEmpty
                                        ? Text(
                                            '还没有装载视频（在下面贴一个地址即可播放）',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: LumeTheme.muted,
                                            ),
                                          )
                                        : SelectableText(
                                            address,
                                            maxLines: 4,
                                            style: TextStyle(
                                              fontSize: 13,
                                              height: 1.4,
                                              color: LumeTheme.textPrimary,
                                            ),
                                          ),
                                  ),
                                  IconButton(
                                    tooltip: '复制地址',
                                    iconSize: 20,
                                    icon: const Icon(Icons.copy_outlined),
                                    onPressed: address.isEmpty ? null : _copy,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (lines.length > 1) ...<Widget>[
                          const SizedBox(height: 12),
                          GlassCard(
                            radius: 14,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                _label('线路（切换后从当前位置继续）'),
                                const SizedBox(height: 4),
                                for (var i = 0; i < lines.length; i++)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      i == widget.currentIndex
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      size: 20,
                                      color: i == widget.currentIndex
                                          ? LumeTheme.accent
                                          : LumeTheme.muted,
                                    ),
                                    title: Text(
                                      lines[i].label,
                                      style: TextStyle(
                                        color: LumeTheme.textPrimary,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _shortUrl(lines[i].url),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: LumeTheme.muted,
                                      ),
                                    ),
                                    onTap: widget.onSelectQuality == null
                                        ? null
                                        : () {
                                            Navigator.of(context).pop();
                                            widget.onSelectQuality!(i);
                                          },
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        GlassCard(
                          radius: 14,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _label('手动地址'),
                              const SizedBox(height: 4),
                              TextField(
                                controller: _input,
                                autofocus: false,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: LumeTheme.textPrimary,
                                ),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  isDense: true,
                                  hintText: '视频地址或本地路径',
                                  hintStyle: TextStyle(color: LumeTheme.muted),
                                ),
                                onSubmitted: (_) => _play(),
                              ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: LumeTheme.danger,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _busy ? null : _play,
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  label: const Text('播放这个地址'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
      );
}
