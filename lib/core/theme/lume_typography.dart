import 'package:flutter/material.dart';

/// Shared logical-pixel type scale. OS accessibility text scaling stays enabled.
abstract final class LumeTypography {
  static const pageTitleSize = 20.0;
  static const sectionTitleSize = 18.0;
  static const titleSize = 16.0;
  static const bodySize = 14.0;
  static const descriptionSize = 12.0;
  static const captionSize = 12.0;
  static const displaySize = 32.0;
  static const displayMediumSize = 28.0;
  static const displaySmallSize = 24.0;

  static const pageTitle = TextStyle(
    fontSize: pageTitleSize,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const sectionTitle = TextStyle(
    fontSize: sectionTitleSize,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );
  static const title = TextStyle(
    fontSize: titleSize,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );
  static const body = TextStyle(
    fontSize: bodySize,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const description = TextStyle(
    fontSize: descriptionSize,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
  static const caption = TextStyle(
    fontSize: captionSize,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  static TextTheme textTheme(Color primary, Color secondary) => TextTheme(
    displayLarge: pageTitle.copyWith(fontSize: displaySize, color: primary),
    displayMedium: pageTitle.copyWith(
      fontSize: displayMediumSize,
      color: primary,
    ),
    displaySmall: pageTitle.copyWith(
      fontSize: displaySmallSize,
      color: primary,
    ),
    headlineLarge: pageTitle.copyWith(color: primary),
    headlineMedium: pageTitle.copyWith(color: primary),
    headlineSmall: sectionTitle.copyWith(color: primary),
    titleLarge: pageTitle.copyWith(color: primary),
    titleMedium: title.copyWith(color: primary),
    titleSmall: title.copyWith(color: primary),
    bodyLarge: title.copyWith(fontWeight: FontWeight.w400, color: primary),
    bodyMedium: body.copyWith(color: primary),
    bodySmall: description.copyWith(color: secondary),
    labelLarge: title.copyWith(color: primary),
    labelMedium: description.copyWith(color: secondary),
    labelSmall: caption.copyWith(color: secondary),
  );
}
