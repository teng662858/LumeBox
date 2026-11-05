import 'package:flutter/material.dart';

/// Re-evaluate legacy static theme colors without discarding route/page State.
class ThemeRefreshBoundary extends StatefulWidget {
  const ThemeRefreshBoundary({
    super.key,
    required this.identity,
    required this.child,
  });
  final String identity;
  final Widget child;
  @override
  State<ThemeRefreshBoundary> createState() => _ThemeRefreshBoundaryState();
}

class _ThemeRefreshBoundaryState extends State<ThemeRefreshBoundary> {
  @override
  void didUpdateWidget(covariant ThemeRefreshBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void refresh(Element element) {
        if (!element.mounted) return;
        element.markNeedsBuild();
        element.visitChildren(refresh);
      }

      (context as Element).visitChildren(refresh);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
