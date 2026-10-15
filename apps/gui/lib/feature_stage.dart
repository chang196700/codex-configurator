// SPDX-License-Identifier: MIT OR Apache-2.0
import 'package:flutter/material.dart';

import 'backend.dart';
import 'workspace.dart';

class FeatureStageBadge extends StatelessWidget {
  const FeatureStageBadge({
    super.key,
    required this.workspace,
    required this.stage,
    this.version,
  });
  final Workspace workspace;
  final String stage;
  final String? version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = switch (stage) {
      'under development' => Colors.blue,
      'experimental' => Colors.amber,
      'stable' => Colors.green,
      'deprecated' => Colors.orange,
      'removed' => Colors.red,
      _ => Colors.grey,
    };
    final color = theme.brightness == Brightness.dark
        ? palette.shade200
        : palette.shade800;
    final meaning = switch (stage) {
      'under development' => workspace.tr('开发中', 'Under development'),
      'experimental' => workspace.tr('实验性功能', 'Experimental'),
      'stable' => workspace.tr('稳定', 'Stable'),
      'deprecated' => workspace.tr('已弃用', 'Deprecated'),
      'removed' => workspace.tr('已移除', 'Removed'),
      'not listed' => workspace.tr(
        '此版本的 Codex 未列出该配置项',
        'Not listed by this version of Codex',
      ),
      _ => stage,
    };
    return Tooltip(
      message:
          '$meaning\n${version ?? asMap(workspace.featureCatalog?['context'])['version'] ?? workspace.featureExecutable} · codex features list',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            stage,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

class FeatureEnabledBadge extends StatelessWidget {
  const FeatureEnabledBadge({
    super.key,
    required this.workspace,
    required this.enabled,
  });
  final Workspace workspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled
        ? (theme.brightness == Brightness.dark
              ? Colors.green.shade200
              : Colors.green.shade800)
        : (theme.brightness == Brightness.dark
              ? Colors.grey.shade300
              : Colors.grey.shade700);
    return Tooltip(
      message: workspace.tr(
        enabled ? 'Codex 当前启用' : 'Codex 当前禁用',
        enabled ? 'Currently enabled by Codex' : 'Currently disabled by Codex',
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            enabled.toString(),
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

class FeatureFieldTitle extends StatelessWidget {
  const FeatureFieldTitle({
    super.key,
    required this.workspace,
    required this.pointer,
    required this.child,
  });
  final Workspace workspace;
  final String pointer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final separator = pointer.lastIndexOf('/');
    if (separator < 0 ||
        !Workspace.isFeatureGroup(pointer.substring(0, separator))) {
      return child;
    }
    final stage =
        workspace.featureStage(pointer) ??
        (workspace.featureCatalog?['available'] == true ? 'not listed' : null);
    final enabled = workspace.featureEnabled(pointer);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        child,
        if (stage != null)
          FeatureStageBadge(workspace: workspace, stage: stage),
        if (enabled != null)
          FeatureEnabledBadge(workspace: workspace, enabled: enabled),
      ],
    );
  }
}

class FeatureCatalogStatus extends StatelessWidget {
  const FeatureCatalogStatus({super.key, required this.workspace});
  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final catalog = workspace.featureCatalog;
    final available = catalog?['available'] == true;
    final status = workspace.featureStagesLoading
        ? workspace.tr('正在读取阶段…', 'Reading stages…')
        : available
        ? '${workspace.tr('阶段与状态', 'Stages and status')} · ${asMap(catalog?['context'])['version'] ?? workspace.featureExecutable}'
        : workspace.tr('阶段不可用', 'Stages unavailable');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Tooltip(
            message: [
              '${workspace.featureExecutable} features list',
              if (catalog?['captured_at'] != null)
                catalog!['captured_at'].toString(),
              if (workspace.featureStagesError?.isNotEmpty == true)
                workspace.featureStagesError!,
              workspace.tr(
                '状态来自 codex features list 的 true/false 列；它不修改配置文件。',
                'Status comes from the true/false column of codex features list; it does not modify the config file.',
              ),
            ].join('\n'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: workspace.featureStagesLoading
              ? null
              : workspace.refreshFeatureStages,
          tooltip: workspace.tr('刷新功能阶段', 'Refresh feature stages'),
          icon: const Icon(Icons.refresh, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
