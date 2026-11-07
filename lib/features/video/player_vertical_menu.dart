import 'package:flutter/material.dart';

import '../../shared/widgets/video_glass_surface.dart';

abstract final class PlayerVerticalMenu {
  static const width = 128.0;
  static MenuStyle get style => MenuStyle(
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static Widget body({
    required BuildContext context,
    required Key key,
    required List<Widget> children,
  }) => VideoGlassSurface(
    radius: 12,
    dark: Theme.of(context).brightness == Brightness.dark,
    materialOpacity: VideoGlassSurface.panelOpacity,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        key: key,
        width: width,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    ),
  );

  static Widget option({
    required String label,
    required bool selected,
    required ValueChanged<bool>? onSelected,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: ChoiceChip(
      label: SizedBox(
        width: double.infinity,
        child: Text(label, textAlign: TextAlign.center),
      ),
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      visualDensity: VisualDensity.compact,
      selected: selected,
      showCheckmark: true,
      color: const WidgetStatePropertyAll(Colors.transparent),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: onSelected,
    ),
  );
}
