import 'package:flutter/material.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/browse_choice_access.dart';

// Windows-only visual preview entry. Uses the production drawer with sample options.
void main() => runApp(const FilterPreview());

class FilterPreview extends StatefulWidget {
  const FilterPreview({super.key});
  @override
  State<FilterPreview> createState() => _FilterPreviewState();
}

class _FilterPreviewState extends State<FilterPreview> {
  bool dark = false;
  String? category;
  Map<String, String> filters = {};
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: LumeTheme.build(
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    builder: (context, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(
          padding: media.padding.copyWith(bottom: 34),
          viewPadding: media.viewPadding.copyWith(bottom: 34),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child ?? const SizedBox.shrink(),
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    width: 134,
                    height: 5,
                    decoration: BoxDecoration(
                      color: dark ? Colors.white : Colors.black,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('筛选预览 · iPhone 底部安全区 34px'),
          actions: [
            IconButton(
              tooltip: '切换亮暗模式',
              icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
              onPressed: () => setState(() => dark = !dark),
            ),
          ],
        ),
        body: Center(
          child: FilledButton(
            child: const Text('打开分类与筛选'),
            onPressed: () async {
              final result = await showBrowseFilters(
                context: context,
                categories: const [
                  SourceCategory(id: 'movie', title: '电影'),
                  SourceCategory(id: 'series', title: '电视剧'),
                  SourceCategory(id: 'animation', title: '动漫'),
                ],
                groups: [
                  SourceFilterGroup(
                    id: 'type',
                    title: '类型',
                    options: [
                      for (final label in ['动作', '喜剧', '科幻', '爱情'])
                        SourceFilterOption(id: label, title: label),
                    ],
                  ),
                  SourceFilterGroup(
                    id: 'area',
                    title: '地区',
                    options: [
                      for (final label in ['中国大陆', '中国香港', '美国', '日本'])
                        SourceFilterOption(id: label, title: label),
                    ],
                  ),
                  SourceFilterGroup(
                    id: 'year',
                    title: '年份',
                    options: [
                      for (final label in ['2026', '2025', '2024', '2023'])
                        SourceFilterOption(id: label, title: label),
                    ],
                  ),
                ],
                category: category,
                filters: filters,
              );
              if (result != null && mounted) {
                setState(() {
                  category = result.category;
                  filters = result.filters;
                });
              }
            },
          ),
        ),
      ),
    ),
  );
}
