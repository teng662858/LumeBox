import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

/// App 主屏幕图标选择页。
///
/// 从「配置与体验」里拆出来，作为「个性与界面」下的独立入口：图标属于外观，
/// 不该和备份/触感混在一页。
class AppIconSettingsPage extends StatelessWidget {
  const AppIconSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final supported = Platform.isIOS || Platform.isAndroid;
    return GlassScaffold(
      effectModule: GlassModule.settings,
      behindBar: true,
      title: 'App 图标',
      child: ListView(
        padding: GlassScaffold.barInset(context)
            .add(const EdgeInsets.fromLTRB(16, 12, 16, 24)),
        children: <Widget>[
          GlassCard(
            radius: 14,
            padding: const EdgeInsets.all(16),
            child: AppIconGrid(previewOnly: !supported),
          ),
          const SizedBox(height: 4),
          SettingsFooterNote(
            supported
                ? '切换只改变主屏幕图标，不影响 App 内数据。'
                      '部分 Android 启动器不支持动态图标，会保持默认图标。'
                : '当前平台不支持动态切换 App 图标，以上为预览。',
          ),
        ],
      ),
    );
  }
}

/// App 图标网格（设置页与开发预览共用）。
class AppIconGrid extends StatefulWidget {
  const AppIconGrid({super.key, this.previewOnly = false, this.iconSize = 60});

  /// 预览模式：不调用平台通道，点了也不生效。
  final bool previewOnly;

  final double iconSize;

  @override
  State<AppIconGrid> createState() => _AppIconGridState();
}

class _AppIconGridState extends State<AppIconGrid> {
  static const List<(String, String)> _icons = <(String, String)>[
    ('default', '经典'),
    ('Aurora', '极光青'),
    ('Obsidian', '曜石紫'),
    ('Solar', '日曜金'),
    ('Orbit', '星环蓝'),
    ('Prism', '流光棱镜'),
    ('Spark', '电光青'),
  ];

  String _selected = 'default';
  bool _busy = false;

  bool get _supported =>
      !widget.previewOnly && (Platform.isIOS || Platform.isAndroid);

  @override
  void initState() {
    super.initState();
    if (_supported) _load();
  }

  Future<void> _load() async {
    try {
      final current = await const MethodChannel('lumebox/app_icon')
          .invokeMethod<String>('current');
      if (!mounted) return;
      setState(() => _selected = current ?? 'default');
    } catch (_) {
      // 读不到就按默认图标显示，不打断设置页。
    }
  }

  Future<void> _select(String name, String label) async {
    if (!_supported || _busy) return;
    setState(() => _busy = true);
    try {
      final ok = await const MethodChannel('lumebox/app_icon')
          .invokeMethod<bool>('set', name);
      if (!mounted) return;
      if (ok == true) setState(() => _selected = name);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok == true ? '已切换为$label图标' : '切换失败，请重试')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('切换失败：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.iconSize;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        for (final (name, label) in _icons)
          InkWell(
            onTap: _supported ? () => _select(name, label) : null,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 70,
              child: Column(
                children: <Widget>[
                  Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'assets/icon/'
                          '${name == 'default' ? 'app_icon_1024' : name}.png',
                          width: size,
                          height: size,
                        ),
                      ),
                      if (_selected == name)
                        Positioned(
                          right: -3,
                          top: -3,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: LumeIcon(
                              Icons.check_circle_rounded,
                              slot: 'app_icon_settings_page.1',
                              size: 18,
                              color: LumeTheme.accent,
                            ),
                          ),
                        ),
                      if (_busy && _selected == name)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .28),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: LumeTypography.captionSize,
                      fontWeight: FontWeight.w400,
                      color: LumeTheme.descriptionColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
