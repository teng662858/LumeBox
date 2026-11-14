import 'package:flutter/material.dart';

/// Only shell root pages inherit this; pushed detail/settings pages keep theirs.
class GlobalSearchScope extends InheritedWidget {
  const GlobalSearchScope({
    super.key,
    required this.onSearch,
    required super.child,
  });
  final VoidCallback onSearch;
  static GlobalSearchScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlobalSearchScope>();
  @override
  bool updateShouldNotify(GlobalSearchScope oldWidget) =>
      onSearch != oldWidget.onSearch;
}

class GlobalSearchButton extends StatelessWidget {
  const GlobalSearchButton({super.key, required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('global-search-button'),
    tooltip: '全局搜索',
    onPressed: onPressed,
    icon: const Icon(Icons.search_rounded),
  );
}
