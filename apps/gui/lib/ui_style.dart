// SPDX-License-Identifier: MIT OR Apache-2.0

import 'package:flutter/foundation.dart';

/// The visual style used by the Flutter shell.
///
/// This preference is deliberately independent from [ThemeMode].  A user can
/// choose the macOS or Linux style while running on Windows, for example, to
/// preview the same layout before deploying it on another desktop platform.
enum UiStyle {
  /// Select a style from the host operating system.
  system,

  /// Fluent-style spacing, surfaces, and controls.
  windowsFluent,

  /// macOS-style spacing, surfaces, and controls.
  macos,

  /// Yaru/GNOME-style spacing, surfaces, and controls.
  linuxYaru,

  /// Material 3 controls and surfaces.
  material,
}

extension UiStyleValues on UiStyle {
  /// Stable value used by the local GUI preference store.
  String get storageValue => switch (this) {
    UiStyle.system => 'system',
    UiStyle.windowsFluent => 'windows-fluent',
    UiStyle.macos => 'macos',
    UiStyle.linuxYaru => 'linux-yaru',
    UiStyle.material => 'material',
  };

  String get labelZh => switch (this) {
    UiStyle.system => '跟随系统',
    UiStyle.windowsFluent => 'Windows Fluent',
    UiStyle.macos => 'macOS',
    UiStyle.linuxYaru => 'Linux Yaru',
    UiStyle.material => 'Material',
  };

  String get labelEn => switch (this) {
    UiStyle.system => 'Follow system',
    UiStyle.windowsFluent => 'Windows Fluent',
    UiStyle.macos => 'macOS',
    UiStyle.linuxYaru => 'Linux Yaru',
    UiStyle.material => 'Material',
  };

  String label({required bool chinese}) => chinese ? labelZh : labelEn;

  static UiStyle parse(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'windows-fluent' ||
      'windows_fluent' ||
      'windowsfluent' ||
      'fluent' => UiStyle.windowsFluent,
      'macos' || 'mac-os' || 'mac' => UiStyle.macos,
      'linux-yaru' ||
      'linux_yaru' ||
      'linuxyaru' ||
      'yaru' ||
      'gnome' => UiStyle.linuxYaru,
      'material' => UiStyle.material,
      _ => UiStyle.system,
    };
  }
}

/// Parses a value from the local preference store.
///
/// Unknown or missing values intentionally map to [UiStyle.system], so an
/// older or manually edited preference cannot prevent the GUI from starting.
UiStyle parseUiStyle(String? value) => UiStyleValues.parse(value);

/// Resolves [style] to the concrete style for [platform].
UiStyle resolveUiStyle(UiStyle style, [TargetPlatform? platform]) {
  if (style != UiStyle.system) return style;
  final selectedPlatform = platform ?? defaultTargetPlatform;
  return switch (selectedPlatform) {
    TargetPlatform.windows => UiStyle.windowsFluent,
    TargetPlatform.macOS || TargetPlatform.iOS => UiStyle.macos,
    TargetPlatform.linux => UiStyle.linuxYaru,
    TargetPlatform.android || TargetPlatform.fuchsia => UiStyle.material,
  };
}
