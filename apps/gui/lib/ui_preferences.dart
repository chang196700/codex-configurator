// SPDX-License-Identifier: MIT OR Apache-2.0

import 'package:shared_preferences/shared_preferences.dart';

import 'ui_style.dart';

export 'ui_style.dart';

/// Persists GUI-only preferences without touching Codex config.toml files.
class AppPreferences {
  AppPreferences({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const uiStyleKey = 'codex_configurator.ui_style';
  final SharedPreferencesAsync _preferences;
  Future<void> _pendingWrites = Future<void>.value();

  Future<UiStyle> loadUiStyle() async {
    try {
      final stored = await _preferences.getString(uiStyleKey);
      return parseUiStyle(stored);
    } catch (_) {
      return UiStyle.system;
    }
  }

  Future<void> saveUiStyle(UiStyle style) {
    final write = _pendingWrites.then(
      (_) => _preferences.setString(uiStyleKey, style.storageValue),
    );
    // Preserve selection order, while allowing a later save to proceed after
    // a failed write. The caller still receives the original failure.
    _pendingWrites = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return write;
  }
}
