// SPDX-License-Identifier: MIT OR Apache-2.0
import 'package:flutter/foundation.dart';

abstract final class AppTypography {
  static String get uiFamily => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'Segoe UI',
    TargetPlatform.macOS || TargetPlatform.iOS => 'PingFang SC',
    _ => 'Noto Sans',
  };

  static const uiFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'sans-serif',
  ];

  static const monoFamily = 'Cascadia Mono';
  static const monoFallback = [
    'Consolas',
    'SF Mono',
    'Menlo',
    'DejaVu Sans Mono',
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans CJK SC',
    'monospace',
  ];
}
