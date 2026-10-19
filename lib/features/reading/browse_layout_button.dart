import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/lume_icon.dart';

/// Identical layout entry and bottom sheet for all four homepages.
class BrowseLayoutButton extends StatelessWidget {
  const BrowseLayoutButton({
    super.key,
    required this.mode,
    required this.onChanged,
  });
  final BrowseLayoutMode mode;
  final ValueChanged<BrowseLayoutMode> onChanged;

  static IconData iconFor(BrowseLayoutMode mode) =>
      BrowseLayoutSettings.normalize(mode) == BrowseLayoutMode.list2
      ? Icons.view_column_outlined
      : Icons.apps_outlined;

  Future<void> _pick(BuildContext context) async {
    final current = BrowseLayoutSettings.normalize(mode);
    final picked = await showLumeBottomSheet<BrowseLayoutMode>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Material(
          color: LumeTheme.base,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .7,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                      child: Text(
                        '布局',
                        style: TextStyle(
                          fontSize: LumeTypography.titleSize,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                    ),
                    for (final option in BrowseLayoutSettings.homeModes)
                      ListTile(
                        selected: option == current,
                        leading: LumeIcon(
                          iconFor(option),
                          slot: 'browse.layout.${option.id}',
                          size: 20,
                        ),
                        title: Text(option.label),
                        subtitle: Text(option.hint),
                        trailing: option == current
                            ? LumeIcon(
                                Icons.check,
                                slot: 'browse.layout.selected',
                                color: LumeTheme.accent,
                                size: 20,
                              )
                            : null,
                        onTap: () => Navigator.of(context).pop(option),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (context.mounted && picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final current = BrowseLayoutSettings.normalize(mode);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: '布局',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(21),
            onTap: () => _pick(context),
            child: SizedBox.square(
              dimension: 42,
              child: Center(
                child: LumeIcon(
                  iconFor(current),
                  slot: 'browse.layout.${current.id}',
                  label: current.label,
                  group: '首页与书架',
                  size: 20,
                  color: LumeTheme.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
