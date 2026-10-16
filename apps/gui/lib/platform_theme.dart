// SPDX-License-Identifier: MIT OR Apache-2.0

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:yaru/yaru.dart';

import 'typography.dart';
import 'ui_style.dart';

TextStyle _desktopTextStyle(TextStyle style) => style.copyWith(
  fontFamily: AppTypography.uiFamily,
  fontFamilyFallback: AppTypography.uiFallback,
  letterSpacing: 0,
);

fluent.FluentThemeData fluentTheme(Brightness brightness) {
  final type = fluent.Typography.fromBrightness(brightness: brightness);
  return fluent.FluentThemeData(
    brightness: brightness,
    accentColor: fluent.Colors.blue,
    fontFamily: AppTypography.uiFamily,
    typography: fluent.Typography.raw(
      display: _desktopTextStyle(type.display!),
      titleLarge: _desktopTextStyle(type.titleLarge!),
      title: _desktopTextStyle(type.title!),
      subtitle: _desktopTextStyle(type.subtitle!),
      bodyLarge: _desktopTextStyle(type.bodyLarge!),
      bodyStrong: _desktopTextStyle(type.bodyStrong!),
      body: _desktopTextStyle(type.body!),
      caption: _desktopTextStyle(type.caption!),
    ),
  );
}

macos.MacosThemeData macosTheme(Brightness brightness) {
  final base = macos.MacosThemeData(brightness: brightness);
  final type = base.typography;
  return base.copyWith(
    typography: macos.MacosTypography.raw(
      largeTitle: _desktopTextStyle(type.largeTitle),
      title1: _desktopTextStyle(type.title1),
      title2: _desktopTextStyle(type.title2),
      title3: _desktopTextStyle(type.title3),
      headline: _desktopTextStyle(type.headline),
      subheadline: _desktopTextStyle(type.subheadline),
      body: _desktopTextStyle(type.body),
      callout: _desktopTextStyle(type.callout),
      footnote: _desktopTextStyle(type.footnote),
      caption1: _desktopTextStyle(type.caption1),
      caption2: _desktopTextStyle(type.caption2),
    ),
  );
}

/// Builds the Material-compatible theme used by the current page widgets.
///
/// The application can use Fluent, macOS, or Yaru-native widgets at the shell
/// level without forcing every schema editor widget to be rewritten.  The
/// shared pages continue to receive a [ThemeData], while this factory adjusts
/// their metrics, color seed, and shape to match the selected visual style.
ThemeData materialTheme(UiStyle style, Brightness brightness) {
  final resolved = resolveUiStyle(style);
  if (resolved == UiStyle.linuxYaru) {
    final theme = brightness == Brightness.light
        ? createYaruLightTheme(
            primaryColor: const Color(0xffe95420),
            fontFamily: AppTypography.uiFamily,
            fontFamilyFallback: AppTypography.uiFallback,
          )
        : createYaruDarkTheme(
            primaryColor: const Color(0xffe95420),
            fontFamily: AppTypography.uiFamily,
            fontFamilyFallback: AppTypography.uiFallback,
          );
    return theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontFamily: AppTypography.uiFamily,
        fontFamilyFallback: AppTypography.uiFallback,
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(isDense: true),
    );
  }
  final seedColor = switch (resolved) {
    UiStyle.windowsFluent => const Color(0xff0f6cbd),
    UiStyle.macos => const Color(0xff3478f6),
    UiStyle.linuxYaru => const Color(0xffe95420),
    UiStyle.material || UiStyle.system => const Color(0xff376b78),
  };
  var colors = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  if (resolved == UiStyle.windowsFluent || resolved == UiStyle.macos) {
    final dark = brightness == Brightness.dark;
    colors = colors.copyWith(
      primary: dark ? const Color(0xff78b9f6) : seedColor,
      surface: dark ? const Color(0xff202020) : const Color(0xfff5f5f5),
      surfaceDim: dark ? const Color(0xff181818) : const Color(0xffe7e7e7),
      surfaceBright: dark ? const Color(0xff363636) : Colors.white,
      surfaceContainerLowest: dark ? const Color(0xff181818) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xff272727) : Colors.white,
      surfaceContainer: dark
          ? const Color(0xff2d2d2d)
          : const Color(0xffeeeeee),
      surfaceContainerHigh: dark
          ? const Color(0xff333333)
          : const Color(0xffe8e8e8),
      surfaceContainerHighest: dark
          ? const Color(0xff3b3b3b)
          : const Color(0xffdddddd),
      onSurface: dark ? const Color(0xfff3f3f3) : const Color(0xff242424),
      onSurfaceVariant: dark
          ? const Color(0xffc7c7c7)
          : const Color(0xff5c5c5c),
      outline: dark ? const Color(0xff777777) : const Color(0xff949494),
      outlineVariant: dark ? const Color(0xff484848) : const Color(0xffd6d6d6),
      surfaceTint: Colors.transparent,
    );
  }

  final metrics = _StyleMetrics.forStyle(resolved);
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
    fontFamily: AppTypography.uiFamily,
    fontFamilyFallback: AppTypography.uiFallback,
    visualDensity: metrics.visualDensity,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 15, height: 1.5, letterSpacing: 0),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, letterSpacing: 0),
      bodySmall: TextStyle(fontSize: 12, height: 1.5, letterSpacing: 0),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0,
      ),
      labelLarge: TextStyle(fontSize: 13, letterSpacing: 0),
      labelMedium: TextStyle(fontSize: 12, letterSpacing: 0),
      labelSmall: TextStyle(fontSize: 11, letterSpacing: 0),
    ),
    scaffoldBackgroundColor: colors.surface,
    cardTheme: CardThemeData(
      elevation: metrics.cardElevation,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(metrics.cardRadius),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: colors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(metrics.controlRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(metrics.controlRadius),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant.withValues(alpha: .6),
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(0, metrics.buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.controlRadius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(0, metrics.buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.controlRadius),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: Size(0, metrics.buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.controlRadius),
        ),
      ),
    ),
  );
}

/// Common layout metrics for widgets shared by all style implementations.
class _StyleMetrics {
  const _StyleMetrics({
    required this.visualDensity,
    required this.cardRadius,
    required this.controlRadius,
    required this.buttonHeight,
    required this.cardElevation,
  });

  final VisualDensity visualDensity;
  final double cardRadius;
  final double controlRadius;
  final double buttonHeight;
  final double cardElevation;

  static _StyleMetrics forStyle(UiStyle style) => switch (style) {
    UiStyle.windowsFluent => const _StyleMetrics(
      visualDensity: VisualDensity.standard,
      cardRadius: 8,
      controlRadius: 4,
      buttonHeight: 32,
      cardElevation: 1,
    ),
    UiStyle.macos => const _StyleMetrics(
      visualDensity: VisualDensity.standard,
      cardRadius: 10,
      controlRadius: 7,
      buttonHeight: 32,
      cardElevation: 0,
    ),
    UiStyle.linuxYaru => const _StyleMetrics(
      visualDensity: VisualDensity.standard,
      cardRadius: 8,
      controlRadius: 6,
      buttonHeight: 36,
      cardElevation: 0,
    ),
    UiStyle.material || UiStyle.system => const _StyleMetrics(
      visualDensity: VisualDensity.standard,
      cardRadius: 12,
      controlRadius: 8,
      buttonHeight: 40,
      cardElevation: 0,
    ),
  };
}
