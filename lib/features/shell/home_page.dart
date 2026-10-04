import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../cat/cat_page.dart';
import '../comic/comic_page.dart';
import '../novel/novel_page.dart';
import '../settings/settings_page.dart';
import '../source/global_source_page.dart';
import '../video/video_page.dart';

/// 首页：四个互相隔离的板块入口 + 全局图源总管理 + 设置。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(LumeTheme.appName),
        actions: <Widget>[
          IconButton(
            tooltip: '图源总管理',
            icon: const Icon(Icons.tune),
            onPressed: () => _open(context, const GlobalSourcePage()),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(context, const SettingsPage()),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          child: GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            children: <Widget>[
              _SectionCard(
                section: Section.novel,
                icon: Icons.menu_book_rounded,
                onTap: () => _open(context, const NovelPage()),
              ),
              _SectionCard(
                section: Section.comic,
                icon: Icons.auto_stories_rounded,
                onTap: () => _open(context, const ComicPage()),
              ),
              _SectionCard(
                section: Section.video,
                icon: Icons.play_circle_outline_rounded,
                onTap: () => _open(context, const VideoPage()),
              ),
              _SectionCard(
                section: Section.cat,
                icon: Icons.pets_rounded,
                onTap: () => _open(context, const CatPage()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.section,
    required this.icon,
    required this.onTap,
  });

  final Section section;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Icon(icon, size: 34, color: Colors.white),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                section.label,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                LumeTheme.appName,
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
