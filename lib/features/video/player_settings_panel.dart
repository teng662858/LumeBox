import '../../shared/widgets/video_glass_surface.dart';

import 'package:flutter/material.dart';

import 'danmaku/danmaku_panel.dart';

/// A local navigation stack keeps second/third-level settings over the video.
Future<T?> showPlayerSettingsPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDanmakuPanel<T>(
  context: context,
  builder: (sheetContext) => PlayerSettingsNavigation(
    close: (result) => Navigator.of(sheetContext).pop(result),
    builder: builder,
  ),
);

class PlayerSettingsNavigation extends StatefulWidget {
  const PlayerSettingsNavigation({
    super.key,
    required this.builder,
    required this.close,
  });
  final WidgetBuilder builder;
  final ValueChanged<Object?> close;
  @override
  State<PlayerSettingsNavigation> createState() =>
      _PlayerSettingsNavigationState();
}

class _PlayerSettingsNavigationState extends State<PlayerSettingsNavigation> {
  final navigator = GlobalKey<NavigatorState>();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: bounds.biggest),
      child: _PlayerSettingsScope(
        close: () => widget.close(null),
        child: NavigatorPopHandler<Object?>(
          onPopWithResult: (result) => navigator.currentState!.pop(result),
          child: Navigator(
            key: navigator,
            onGenerateRoute: (_) => _PlayerSettingsRootRoute(
              builder: widget.builder,
              close: widget.close,
            ),
          ),
        ),
      ),
    ),
  );
}

class _PlayerSettingsRootRoute extends MaterialPageRoute<Object?> {
  _PlayerSettingsRootRoute({required super.builder, required this.close});
  final ValueChanged<Object?> close;
  @override
  // The initial route must stay installed until its outer sheet is dismissed.
  // Calling super would complete/remove that route and empty the navigator.
  // ignore: must_call_super
  bool didPop(Object? result) {
    close(result);
    return false;
  }
}

class _PlayerSettingsScope extends InheritedWidget {
  const _PlayerSettingsScope({required this.close, required super.child});
  final VoidCallback close;
  @override
  bool updateShouldNotify(_PlayerSettingsScope oldWidget) =>
      close != oldWidget.close;
}

/// The same settings remain usable from global settings, with bounded line width.
class PlayerSettingsScaffold extends StatelessWidget {
  const PlayerSettingsScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.embedded = false,
  });
  final bool embedded;
  final String title;
  final Widget body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_PlayerSettingsScope>();
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        listTileTheme: theme.listTileTheme.copyWith(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          minVerticalPadding: 8,
          titleTextStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ),
      child: embedded
          ? Column(
              children: [
                if (actions.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: actions,
                    ),
                  ),
                Expanded(child: body),
              ],
            )
          : Scaffold(
              backgroundColor: VideoGlassScope.active(context)
                  ? Colors.transparent
                  : theme.colorScheme.surface,
              appBar: AppBar(
                toolbarHeight: 52,
                centerTitle: false,
                title: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: VideoGlassScope.active(context)
                    ? Colors.transparent
                    : theme.colorScheme.surface,
                surfaceTintColor: Colors.transparent,
                leading: scope == null
                    ? null
                    : IconButton(
                        tooltip: Navigator.of(context).canPop()
                            ? '返回上一级'
                            : '关闭设置',
                        icon: Icon(
                          Navigator.of(context).canPop()
                              ? Icons.arrow_back_rounded
                              : Icons.close_rounded,
                          size: 22,
                        ),
                        onPressed: Navigator.of(context).canPop()
                            ? () => Navigator.of(context).pop()
                            : scope.close,
                      ),
                actions: [
                  ...actions,
                  if (scope != null && Navigator.of(context).canPop())
                    IconButton(
                      tooltip: '关闭全部设置',
                      icon: const Icon(Icons.close_rounded, size: 21),
                      onPressed: scope.close,
                    ),
                  const SizedBox(width: 4),
                ],
              ),
              body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: body,
                ),
              ),
            ),
    );
  }
}

class PlayerSettingsSection extends StatelessWidget {
  const PlayerSettingsSection({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              title!,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Material(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: .45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          color: VideoGlassScope.active(context)
              ? Colors.white.withValues(alpha: .22)
              : Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    ),
  );
}
