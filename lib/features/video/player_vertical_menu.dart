import 'package:flutter/material.dart';

abstract final class PlayerVerticalMenu {
  static const width = 144.0;
  static MenuStyle get style => MenuStyle(
    padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static Widget body({required Key key, required List<Widget> children}) =>
      SizedBox(
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
      );

  static Widget option({
    required String label,
    required bool selected,
    required ValueChanged<bool>? onSelected,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: ChoiceChip(
      label: SizedBox(
        width: double.infinity,
        child: Text(label, textAlign: TextAlign.center),
      ),
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      selected: selected,
      showCheckmark: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      onSelected: onSelected,
    ),
  );
}
