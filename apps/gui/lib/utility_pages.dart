import 'dart:convert';

import 'package:flutter/material.dart';

import 'platform_widgets.dart';

import 'backend.dart';
import 'editor_page.dart' show DiagnosticsPanel;
import 'feature_stage.dart';
import 'typography.dart';
import 'ui_preferences.dart';
import 'workspace.dart';

String _display(dynamic value) {
  if (value == null) return '—';
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return const JsonEncoder.withIndent('  ').convert(value);
}

String _source(dynamic raw) {
  if (raw is String) return raw;
  final item = asMap(raw);
  return item['path']?.toString() ??
      item['name']?.toString() ??
      item['kind']?.toString() ??
      _display(raw);
}

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({super.key, required this.workspace});
  final Workspace workspace;
  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  final profile = TextEditingController();
  final overrides = TextEditingController();
  final executable = TextEditingController();
  Json? result;
  Json? featureResult;
  String filter = '';
  late int contextRevision;
  Workspace get w => widget.workspace;
  @override
  void initState() {
    super.initState();
    contextRevision = w.contextRevision;
  }

  @override
  void didUpdateWidget(covariant AnalysisPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (contextRevision != w.contextRevision) {
      contextRevision = w.contextRevision;
      result = null;
      featureResult = null;
    }
  }

  @override
  void dispose() {
    profile.dispose();
    overrides.dispose();
    executable.dispose();
    super.dispose();
  }

  Future<Json?> requestForContext(
    String operation,
    Json arguments,
    int revision,
  ) => w.guard<Json?>(() async {
    try {
      final data = await w.backend.call(operation, arguments);
      return revision == w.contextRevision ? data : null;
    } catch (_) {
      if (revision != w.contextRevision) return null;
      rethrow;
    }
  });

  Future<void> analyze() async {
    final revision = w.contextRevision;
    final data = await requestForContext('analyze', {
      ...w.context,
      if (profile.text.trim().isNotEmpty) 'profile': profile.text.trim(),
      'overrides': overrides.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(),
    }, revision);
    if (data != null && mounted && revision == w.contextRevision) {
      setState(() => result = data);
    }
  }

  Future<void> verifyFeatures() async {
    if (!w.hasProject) return;
    final revision = w.contextRevision;
    final featureRevision = w.featureRequestRevision;
    final data = await requestForContext('features', {
      ...w.context,
      if (executable.text.trim().isNotEmpty)
        'executable': executable.text.trim(),
    }, revision);
    if (data != null &&
        mounted &&
        revision == w.contextRevision &&
        w.hasProject) {
      w.useFeatureSnapshot(data, expectedRevision: featureRevision);
      setState(() => featureResult = data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = asList(result?['entries'])
        .map(asMap)
        .where(
          (entry) =>
              '${entry['pointer']} ${entry['value_toml']} ${_source(entry['source'])}'
                  .toLowerCase()
                  .contains(filter.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _CompactToolbar(
                    inlineWidth: 680,
                    leadingMaxWidth: 360,
                    leading: _ContextDescription(
                      label: w.hasProject
                          ? w.tr('项目目录', 'Project directory')
                          : w.tr('当前范围', 'Current scope'),
                      value: w.hasProject
                          ? w.projectDirectory!
                          : w.tr(
                              '全局配置（仅全局层）',
                              'Global configuration (global layers only)',
                            ),
                    ),
                    actions: [
                      SizedBox(
                        width: 230,
                        child: PlatformTextField(
                          controller: profile,
                          decoration: InputDecoration(
                            labelText: w.tr(
                              'Profile（可选）',
                              'Profile (optional)',
                            ),
                            hintText: w.tr('使用默认', 'Use default'),
                          ),
                        ),
                      ),
                      PlatformButton.icon(
                        kind: PlatformButtonKind.primary,
                        onPressed: w.busy ? null : analyze,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: Text(w.tr('分析', 'Analyze')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  PlatformTextField(
                    controller: overrides,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: AppTypography.monoFamily,
                      fontFamilyFallback: AppTypography.monoFallback,
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      labelText: w.tr(
                        '命令行覆盖（每行一个 key=value）',
                        'Command-line overrides (one key=value per line)',
                      ),
                      hintText: 'model = "gpt-5"',
                    ),
                  ),
                  if (w.documents.any((document) => document.dirty))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          w.tr(
                            '有未保存的编辑；本页读取磁盘中的文件。',
                            'There are unsaved edits. This page reads the files on disk.',
                          ),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: result == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.layers_outlined, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        w.tr(
                          '点击“分析”查看当前配置来源。',
                          'Select Analyze to view the current configuration sources.',
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (asList(result!['layers']).isNotEmpty)
                      Card(
                        child: ExpansionTile(
                          initiallyExpanded: true,
                          title: Text(w.tr('配置层级', 'Configuration layers')),
                          children: [
                            for (final raw in asList(result!['layers']))
                              _layer(context, asMap(raw)),
                          ],
                        ),
                      ),
                    if (asList(result!['unknowns']).isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                w.tr('无法静态确认的部分', 'Not statically determined'),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              for (final unknown in asList(result!['unknowns']))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    unknown is String
                                        ? unknown
                                        : asMap(
                                                unknown,
                                              )['message']?.toString() ??
                                              asMap(
                                                unknown,
                                              )['reason']?.toString() ??
                                              _display(unknown),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    PlatformTextField(
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search, size: 19),
                        hintText: w.tr(
                          '筛选键、值或来源',
                          'Filter by key, value or source',
                        ),
                      ),
                      onChanged: (value) => setState(() => filter = value),
                    ),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      child: _AnalysisColumns(
                        setting: Text(
                          w.tr('配置项', 'Setting'),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        value: Text(
                          w.tr('生效值', 'Effective value'),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        source: Text(
                          w.tr('来源', 'Source'),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final entry in entries) _entry(context, entry),
                    if (entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(w.tr('没有匹配的配置项。', 'No matching entries.')),
                      ),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _CompactToolbar(
                              leading: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    w.tr(
                                      'Codex feature 核验',
                                      'Codex feature verification',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    w.hasProject
                                        ? w.tr(
                                            '可选：读取本机 Codex 报告的 feature 状态。核验使用已保存文件，不包含本页的 Profile 与命令行覆盖。',
                                            'Optional: read feature states from local Codex using saved files. The profile and overrides on this page are not included.',
                                          )
                                        : w.tr(
                                            '请先从右上角打开项目，再核验 Codex feature 状态。',
                                            'Open a project from the top-right controls before verifying Codex feature states.',
                                          ),
                                  ),
                                ],
                              ),
                              actions: [
                                PlatformButton(
                                  onPressed: w.busy || !w.hasProject
                                      ? null
                                      : verifyFeatures,
                                  child: Text(w.tr('核验', 'Verify')),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            PlatformTextField(
                              controller: executable,
                              decoration: InputDecoration(
                                labelText: w.tr(
                                  'Codex 可执行文件（可选）',
                                  'Codex executable (optional)',
                                ),
                                hintText: w.tr(
                                  '留空使用 PATH 中的 Codex',
                                  'Leave empty to use Codex from PATH',
                                ),
                              ),
                            ),
                            if (featureResult != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                featureResult!['available'] == true
                                    ? w.tr(
                                        '已获取 Codex feature 状态',
                                        'Codex feature states retrieved',
                                      )
                                    : w.tr(
                                        '未能获取 Codex feature 状态',
                                        'Codex feature states unavailable',
                                      ),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 12),
                              for (final key in [
                                'version',
                                'executable',
                                'cwd',
                                'codex_home',
                              ])
                                if (asMap(featureResult!['context'])[key] !=
                                    null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _ContextDescription(
                                      label: {
                                        'version': w.tr('版本', 'Version'),
                                        'executable': w.tr(
                                          '可执行文件',
                                          'Executable',
                                        ),
                                        'cwd': w.tr(
                                          '项目目录',
                                          'Project directory',
                                        ),
                                        'codex_home': 'CODEX_HOME',
                                      }[key]!,
                                      value: asMap(
                                        featureResult!['context'],
                                      )[key].toString(),
                                    ),
                                  ),
                              if (featureResult!['captured_at'] != null)
                                Text(
                                  '${w.tr('核验时间', 'Captured at')} · ${featureResult!['captured_at']}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              for (final raw in asList(
                                featureResult!['features'],
                              ))
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    asMap(raw)['enabled'] == true
                                        ? Icons.check_circle_outline
                                        : Icons.remove_circle_outline,
                                    size: 20,
                                  ),
                                  title: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        asMap(raw)['name']?.toString() ?? '',
                                      ),
                                      FeatureStageBadge(
                                        workspace: w,
                                        stage:
                                            asMap(raw)['stage']?.toString() ??
                                            '',
                                        version:
                                            asMap(
                                              featureResult!['context'],
                                            )['version']?.toString() ??
                                            asMap(
                                              featureResult!['context'],
                                            )['executable']?.toString(),
                                      ),
                                    ],
                                  ),
                                  trailing: Text(
                                    asMap(raw)['enabled'] == true
                                        ? w.tr('已启用', 'Enabled')
                                        : w.tr('未启用', 'Disabled'),
                                  ),
                                ),
                              if (asList(featureResult!['diagnostics'])
                                  .isNotEmpty)
                                DiagnosticsPanel(
                                  workspace: w,
                                  diagnostics: asList(
                                    featureResult!['diagnostics'],
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        if (asList(result?['diagnostics']).isNotEmpty)
          DiagnosticsPanel(
            workspace: w,
            diagnostics: asList(result!['diagnostics']),
          ),
      ],
    );
  }

  Widget _layer(BuildContext context, Json layer) => ListTile(
    dense: true,
    leading: Icon(
      layer['applied'] == false || layer['status'] == 'skipped'
          ? Icons.layers_clear_outlined
          : Icons.layers_outlined,
      size: 20,
    ),
    title: Text(
      layer['name']?.toString() ??
          layer['kind']?.toString() ??
          layer['source']?.toString() ??
          '',
    ),
    subtitle: Text(
      [layer['path'], layer['reason']].where((item) => item != null).join('\n'),
    ),
    trailing: Text(
      layer['status']?.toString() ?? '',
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );

  Widget _entry(BuildContext context, Json entry) => Card(
    margin: const EdgeInsets.symmetric(vertical: 3),
    child: InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => PlatformDialog(
          title: SelectableText(entry['pointer']?.toString() ?? ''),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w.tr('生效值', 'Effective value'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    entry['value_toml']?.toString() ?? _display(entry['value']),
                    style: const TextStyle(
                      fontFamily: AppTypography.monoFamily,
                      fontFamilyFallback: AppTypography.monoFallback,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    w.tr('来源与覆盖过程', 'Sources and overrides'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  for (final raw in asList(entry['chain']))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _chain(context, asMap(raw)),
                    ),
                  if (asList(entry['chain']).isEmpty)
                    SelectableText(_source(entry['source'])),
                  if (entry['reason'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(entry['reason'].toString()),
                    ),
                  if (entry['resolved_path'] != null ||
                      entry['resolved_paths'] != null) ...[
                    const SizedBox(height: 16),
                    _ContextDescription(
                      label: w.tr('解析后的路径', 'Resolved paths'),
                      value:
                          entry['resolved_path']?.toString() ??
                          asList(entry['resolved_paths']).join('\n'),
                    ),
                    if (entry['path_base'] != null) ...[
                      const SizedBox(height: 8),
                      _ContextDescription(
                        label: w.tr('路径基准', 'Path base'),
                        value: entry['path_base'].toString(),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            PlatformButton.quiet(
              onPressed: () => Navigator.pop(context),
              child: Text(w.tr('关闭', 'Close')),
            ),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: _AnalysisColumns(
          setting: Text(
            entry['pointer']?.toString() ?? '',
            style: const TextStyle(
              fontFamily: AppTypography.monoFamily,
              fontFamilyFallback: AppTypography.monoFallback,
              fontSize: 12,
            ),
          ),
          value: Text(
            entry['value_toml']?.toString() ?? _display(entry['value']),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppTypography.monoFamily,
              fontFamilyFallback: AppTypography.monoFallback,
              fontSize: 12,
            ),
          ),
          source: Text(
            _source(entry['source']),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
      ),
    ),
  );

  Widget _chain(BuildContext context, Json item) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _source(item['source'] ?? item),
        style: Theme.of(context).textTheme.labelLarge,
      ),
      if (item['value_toml'] != null)
        SelectableText(
          item['value_toml'].toString(),
          style: const TextStyle(
            fontFamily: AppTypography.monoFamily,
            fontFamilyFallback: AppTypography.monoFallback,
            fontSize: 12,
          ),
        ),
      if (item['status'] != null || item['reason'] != null)
        Text(
          [
            item['status'],
            item['reason'],
          ].where((item) => item != null).join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );
}

class _AnalysisColumns extends StatelessWidget {
  const _AnalysisColumns({
    required this.setting,
    required this.value,
    required this.source,
    this.trailing,
  });

  final Widget setting;
  final Widget value;
  final Widget source;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(flex: 3, child: setting),
      const SizedBox(width: 10),
      Expanded(flex: 3, child: value),
      const SizedBox(width: 10),
      Expanded(flex: 4, child: source),
      SizedBox(width: 20, child: trailing),
    ],
  );
}

class BackupsPage extends StatefulWidget {
  const BackupsPage({
    super.key,
    required this.workspace,
    required this.confirmDiscard,
  });
  final Workspace workspace;
  final Future<bool> Function(ConfigDocument) confirmDiscard;
  @override
  State<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends State<BackupsPage> {
  final path = TextEditingController();
  List<Json> backups = [];
  Json? selected;
  String preview = '';
  String? loadedPath;
  String? previewRevision;
  late int contextRevision;
  int requestGeneration = 0;
  bool awaitingContextSelection = false;
  Workspace get w => widget.workspace;
  @override
  void initState() {
    super.initState();
    contextRevision = w.contextRevision;
    path.text = w.active?.path ?? '';
  }

  @override
  void didUpdateWidget(covariant BackupsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (contextRevision != w.contextRevision) {
      contextRevision = w.contextRevision;
      requestGeneration++;
      path.text = w.active?.path ?? '';
      loadedPath = null;
      backups = [];
      selected = null;
      preview = '';
      previewRevision = null;
      awaitingContextSelection = w.busy;
    }
    if (awaitingContextSelection && !w.busy) {
      path.text = w.active?.path ?? '';
      awaitingContextSelection = false;
    }
  }

  bool isCurrentRequest(int revision, int generation, String target) =>
      mounted &&
      revision == w.contextRevision &&
      generation == requestGeneration &&
      path.text.trim() == target;

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (path.text.trim().isEmpty) path.text = w.active?.path ?? '';
    if (path.text.trim().isEmpty) return;
    final target = path.text.trim();
    final revision = w.contextRevision;
    final generation = ++requestGeneration;
    final data = await w.guard(() async {
      try {
        final data = await w.backend.call('backups', {'path': target});
        return isCurrentRequest(revision, generation, target) ? data : null;
      } catch (_) {
        if (!isCurrentRequest(revision, generation, target)) return null;
        rethrow;
      }
    });
    if (data != null && isCurrentRequest(revision, generation, target)) {
      setState(() {
        loadedPath = target;
        backups = asList(data['backups'] ?? data['items']).map(asMap).toList();
        selected = null;
        preview = '';
        previewRevision = null;
      });
    }
  }

  Future<void> select(Json backup) async {
    final target = loadedPath;
    if (target == null || path.text.trim() != target) return;
    final revision = w.contextRevision;
    final generation = ++requestGeneration;
    final data = await w.guard(() async {
      try {
        final snapshot = await w.backend.call('open', {'path': backup['path']});
        if (!isCurrentRequest(revision, generation, target)) return null;
        final current = await w.backend.call('open', {'path': target});
        if (!isCurrentRequest(revision, generation, target)) return null;
        final diff = await w.backend.call('diff', {
          'before': current['content'] ?? '',
          'after': snapshot['content'] ?? '',
        });
        return isCurrentRequest(revision, generation, target)
            ? {...diff, 'revision': current['revision']}
            : null;
      } catch (_) {
        if (!isCurrentRequest(revision, generation, target)) return null;
        rethrow;
      }
    });
    if (data != null &&
        isCurrentRequest(revision, generation, target) &&
        loadedPath == target) {
      setState(() {
        selected = backup;
        preview = data['diff']?.toString() ?? '';
        previewRevision = data['revision']?.toString();
      });
    }
  }

  Future<void> restore() async {
    if (selected == null || loadedPath == null) return;
    final target = loadedPath!;
    final backup = selected!;
    final revision = w.contextRevision;
    final expectedFileRevision = previewRevision;
    bool stillSelected() =>
        mounted &&
        revision == w.contextRevision &&
        loadedPath == target &&
        path.text.trim() == target &&
        selected?['id'] == backup['id'];
    if (!stillSelected()) return;
    final document = w.documents
        .where((document) => document.path == target)
        .firstOrNull;
    final openedRevision = document?.revision;
    if (document != null &&
        document.dirty &&
        !await widget.confirmDiscard(document)) {
      return;
    }
    if (!stillSelected()) return;
    if (document != null && document.revision != openedRevision) {
      await select(backup);
      if (!stillSelected()) return;
      w.notice = w.tr(
        '文件已更改，恢复预览已刷新，请重新确认。',
        'The file changed. Review the refreshed preview before restoring.',
      );
      w.changed();
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformDialog(
        title: Text(w.tr('恢复这个备份？', 'Restore this backup?')),
        content: Text(
          w.tr(
            '恢复后将替换当前文件。\n$target',
            'This will replace the current file.\n$target',
          ),
        ),
        actions: [
          PlatformButton.quiet(
            onPressed: () => Navigator.pop(context, false),
            child: Text(w.tr('取消', 'Cancel')),
          ),
          PlatformButton.primary(
            onPressed: () => Navigator.pop(context, true),
            child: Text(w.tr('恢复', 'Restore')),
          ),
        ],
      ),
    );
    if (confirmed != true || !stillSelected()) return;
    final restored = await w.guard(() async {
      final data = await w.backend.call('restore', {
        'path': target,
        'backup_id': backup['id'],
        'revision': expectedFileRevision,
      });
      if (!stillSelected()) return false;
      if (document != null) {
        w.applySnapshot(document, asMap(data['snapshot'] ?? data));
        await w.inspect(document);
      }
      w.notice = w.tr('备份已恢复。', 'Backup restored.');
      return true;
    });
    if (restored == true) await refresh();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: _CompactToolbar(
          leading: PlatformTextField(
            controller: path,
            enabled: !w.busy,
            decoration: InputDecoration(
              labelText: w.tr('配置文件路径', 'Configuration file path'),
              hintText: w.active?.path,
            ),
            onSubmitted: (_) => refresh(),
          ),
          actions: [
            PlatformButton.quiet(
              onPressed: w.busy || w.active == null
                  ? null
                  : () {
                      path.text = w.active!.path;
                      refresh();
                    },
              child: Text(w.tr('使用当前文件', 'Use current file')),
            ),
            PlatformButton.icon(
              onPressed: w.busy ? null : refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(w.tr('刷新', 'Refresh')),
            ),
          ],
        ),
      ),
      const Divider(),
      Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 290,
              child: backups.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          loadedPath == null
                              ? w.tr(
                                  '选择文件并刷新备份列表。',
                                  'Choose a file and load its backups.',
                                )
                              : w.tr('这个文件尚无备份。', 'No backups for this file.'),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: backups
                          .map(
                            (backup) => Card(
                              child: ListTile(
                                selected: selected?['id'] == backup['id'],
                                leading: const Icon(Icons.history, size: 20),
                                title: Text(
                                  backup['created_at']?.toString() ??
                                      backup['id']?.toString() ??
                                      '',
                                ),
                                subtitle: Text(
                                  backup['id']?.toString() ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: w.busy ? null : () => select(backup),
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
            const VerticalDivider(),
            Expanded(
              child: selected == null
                  ? Center(
                      child: Text(
                        w.tr(
                          '选择一个备份预览差异。',
                          'Select a backup to preview its changes.',
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: _CompactToolbar(
                            inlineWidth: 480,
                            leadingMaxWidth: 200,
                            leading: Text(
                              w.tr('恢复预览', 'Restore preview'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            actions: [
                              PlatformButton.icon(
                                kind: PlatformButtonKind.primary,
                                onPressed: w.busy ? null : restore,
                                icon: const Icon(Icons.restore, size: 18),
                                label: Text(w.tr('恢复备份', 'Restore backup')),
                              ),
                            ],
                          ),
                        ),
                        const Divider(),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              preview.isEmpty
                                  ? w.tr(
                                      '备份与当前文件内容相同。',
                                      'This backup matches the current file.',
                                    )
                                  : preview,
                              style: const TextStyle(
                                fontFamily: AppTypography.monoFamily,
                                fontFamilyFallback: AppTypography.monoFallback,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    ],
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.workspace,
    this.uiStyle = UiStyle.system,
    this.onUiStyleChanged,
  });
  final Workspace workspace;
  final UiStyle uiStyle;
  final ValueChanged<UiStyle>? onUiStyleChanged;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final home = TextEditingController(text: widget.workspace.codexHome);
  Json? schemaCheck;
  Workspace get w => widget.workspace;
  @override
  void dispose() {
    home.dispose();
    super.dispose();
  }

  Future<void> schemaAction(String action, [String? path]) async {
    final result = await w.guard(
      () => w.backend.call('schema_update', {'action': action, 'path': ?path}),
    );
    if (result == null || !mounted) return;
    if (result.containsKey('form_schema') || result.containsKey('schema')) {
      w.schema = result;
      w.changed();
    } else if (action != 'check') {
      await w.guard(() async {
        w.schema = await w.backend.call('schema');
      });
    }
    if (action != 'check') {
      await w.guard(() async {
        for (final document in w.documents) {
          await w.inspect(document);
        }
      });
    }
    if (mounted) setState(() => schemaCheck = result);
  }

  Future<void> importSchema() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => PlatformDialog(
        title: Text(w.tr('导入官方 schema', 'Import schema')),
        content: SizedBox(
          width: 550,
          child: PlatformTextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: w.tr('JSON 文件完整路径', 'Full path to the JSON file'),
            ),
          ),
        ),
        actions: [
          PlatformButton.quiet(
            onPressed: () => Navigator.pop(context),
            child: Text(w.tr('取消', 'Cancel')),
          ),
          PlatformButton.primary(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: Text(w.tr('导入', 'Import')),
          ),
        ],
      ),
    );
    if (path != null) await schemaAction('import', path);
  }

  @override
  Widget build(BuildContext context) {
    final metadata = asMap(w.schema['metadata']);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CompactToolbar(
                  inlineWidth: 500,
                  leadingMaxWidth: 180,
                  leading: SizedBox(
                    width: 180,
                    child: Text(
                      w.tr('界面语言', 'Language'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  actions: [
                    PlatformSegments<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('简体中文')),
                        ButtonSegment(value: false, label: Text('English')),
                      ],
                      selected: {w.chinese},
                      onSelectionChanged: (selection) =>
                          w.language(selection.first),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _CompactToolbar(
                  inlineWidth: 500,
                  leadingMaxWidth: 180,
                  leading: SizedBox(
                    width: 180,
                    child: Text(
                      w.tr('界面风格', 'Interface style'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  actions: [
                    SizedBox(
                      width: 220,
                      child: PlatformSelect<UiStyle>(
                        isExpanded: true,
                        value: widget.uiStyle,
                        onChanged: widget.onUiStyleChanged == null
                            ? null
                            : (style) {
                                if (style != null) {
                                  widget.onUiStyleChanged!(style);
                                }
                              },
                        items: {
                          for (final style in UiStyle.values)
                            style: style.label(chinese: w.chinese),
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.tr('工具配置目录', 'Tool configuration directory'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 18),
                PlatformTextField(
                  controller: home,
                  decoration: InputDecoration(
                    labelText: 'CODEX_HOME',
                    hintText: w.tr(
                      '留空以使用系统默认值',
                      'Leave empty to use the default',
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                PlatformButton.icon(
                  kind: PlatformButtonKind.tonal,
                  onPressed: w.busy
                      ? null
                      : () => w.guard(() async {
                          await w.setCodexHome(home.text.trim());
                          home.text = w.codexHome;
                          w.notice = w.tr(
                            '配置文件列表已刷新。',
                            'Configuration files refreshed.',
                          );
                        }),
                  icon: const Icon(Icons.folder_copy_outlined, size: 18),
                  label: Text(
                    w.tr('应用并重新发现配置', 'Apply and discover configurations'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.tr('字段定义', 'Field definitions'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  w.tr(
                    '内置快照可离线使用。更新后可随时回退。',
                    'The bundled snapshot works offline. You can restore it after an update.',
                  ),
                ),
                const SizedBox(height: 16),
                if (metadata['cache_warning'] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      w.tr('已回退到内置字段定义：', 'Using bundled field definitions: ') +
                          metadata['cache_warning'].toString(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                for (final key in [
                  'source',
                  'semantic_version',
                  'bundled_date',
                  'updated_at',
                  'sha256',
                ])
                  if (metadata[key] != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ContextDescription(
                        label: {
                          'source': w.tr('来源', 'Source'),
                          'semantic_version': w.tr('版本', 'Version'),
                          'bundled_date': w.tr('快照日期', 'Snapshot date'),
                          'updated_at': w.tr('更新时间', 'Updated'),
                          'sha256': w.tr('内容指纹', 'Content fingerprint'),
                        }[key]!,
                        value: metadata[key].toString(),
                      ),
                    ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    PlatformButton.tonal(
                      onPressed: w.busy ? null : () => schemaAction('check'),
                      child: Text(w.tr('检查更新', 'Check for updates')),
                    ),
                    PlatformButton(
                      onPressed: w.busy ? null : () => schemaAction('update'),
                      child: Text(w.tr('更新', 'Update')),
                    ),
                    PlatformButton(
                      onPressed: w.busy ? null : importSchema,
                      child: Text(w.tr('导入文件', 'Import file')),
                    ),
                    PlatformButton.quiet(
                      onPressed: w.busy ? null : () => schemaAction('reset'),
                      child: Text(w.tr('恢复内置快照', 'Restore bundled snapshot')),
                    ),
                  ],
                ),
                if (schemaCheck != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      schemaCheck!['message']?.toString() ??
                          (asMap(schemaCheck!['update'])['available'] == true
                              ? w.tr(
                                  '有新的字段定义可用。',
                                  'New field definitions are available.',
                                )
                              : w.tr(
                                  '字段定义检查已完成。',
                                  'Field definitions checked.',
                                )),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ProfilesDialog extends StatefulWidget {
  const ProfilesDialog({super.key, required this.workspace});
  final Workspace workspace;
  @override
  State<ProfilesDialog> createState() => _ProfilesDialogState();
}

class _ProfilesDialogState extends State<ProfilesDialog> {
  List<dynamic> profiles = [];
  String? error;
  bool busy = false;
  Workspace get w => widget.workspace;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final data = await w.backend.call('profiles', {
        ...w.context,
        'action': 'list',
      });
      if (mounted) {
        setState(() {
          profiles = asList(data['profiles'] ?? data['items']);
          error = null;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String name(dynamic raw) =>
      raw is String ? raw : asMap(raw)['name']?.toString() ?? '';

  Future<void> change(String action, [String? source]) async {
    if (w.documents.any((document) => document.dirty)) {
      setState(
        () => error = w.tr(
          '请先保存或关闭未保存的文件，再修改 Profiles。',
          'Save or close unsaved files before changing profiles.',
        ),
      );
      return;
    }
    String? target;
    if (action != 'delete') {
      final controller = TextEditingController();
      target = await showDialog<String>(
        context: context,
        builder: (context) => PlatformDialog(
          title: Text(
            action == 'create'
                ? w.tr('新建 Profile', 'New profile')
                : action == 'copy'
                ? w.tr('复制 Profile', 'Copy profile')
                : w.tr('重命名 Profile', 'Rename profile'),
          ),
          content: SizedBox(
            width: 400,
            child: PlatformTextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(labelText: w.tr('新名称', 'New name')),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context, value.trim());
                }
              },
            ),
          ),
          actions: [
            PlatformButton.quiet(
              onPressed: () => Navigator.pop(context),
              child: Text(w.tr('取消', 'Cancel')),
            ),
            PlatformButton.primary(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: Text(w.tr('确定', 'Confirm')),
            ),
          ],
        ),
      );
      if (target == null) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformDialog(
          title: Text(w.tr('删除 Profile？', 'Delete profile?')),
          content: Text(source ?? ''),
          actions: [
            PlatformButton.quiet(
              onPressed: () => Navigator.pop(context, false),
              child: Text(w.tr('取消', 'Cancel')),
            ),
            PlatformButton.primary(
              onPressed: () => Navigator.pop(context, true),
              child: Text(w.tr('删除', 'Delete')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final sourcePath = profiles
          .map(asMap)
          .where((item) => item['name'] == source)
          .firstOrNull?['path']
          ?.toString();
      final sourceDocument = w.documents
          .where((document) => document.path == sourcePath)
          .firstOrNull;
      final snapshot = await w.backend.call('profiles', {
        ...w.context,
        'action': action,
        if (action == 'create') 'name': target else 'name': source,
        if (action == 'copy' || action == 'rename') 'new_name': target,
        if (action == 'delete' && sourceDocument != null)
          'revision': sourceDocument.revision,
      });
      await w.discover();
      if ((action == 'rename' || action == 'delete') &&
          sourceDocument != null) {
        w.close(sourceDocument);
      }
      if (action != 'delete' && snapshot['path'] != null) {
        await w.open(snapshot['path'].toString());
      }
      await load();
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PlatformDialog(
    title: Row(
      children: [
        Expanded(child: Text(w.tr('管理 Profiles', 'Manage profiles'))),
        PlatformButton.icon(
          kind: PlatformButtonKind.quiet,
          onPressed: busy ? null : () => change('create'),
          icon: const Icon(Icons.add),
          label: Text(w.tr('新建', 'New')),
        ),
      ],
    ),
    content: SizedBox(
      width: 650,
      height: 380,
      child: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: profiles.isEmpty && !busy
                ? Center(child: Text(w.tr('尚未创建 Profile。', 'No profiles yet.')))
                : ListView(
                    children: profiles
                        .map(
                          (profile) => ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text(name(profile)),
                            onTap: busy || asMap(profile)['path'] == null
                                ? null
                                : () {
                                    final path = asMap(
                                      profile,
                                    )['path'].toString();
                                    Navigator.pop(context);
                                    w.guard(() => w.open(path));
                                  },
                            subtitle: asMap(profile)['path'] == null
                                ? null
                                : Text(asMap(profile)['path'].toString()),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PlatformIconButton(
                                  tooltip: w.tr('复制', 'Copy'),
                                  onPressed: busy
                                      ? null
                                      : () => change('copy', name(profile)),
                                  icon: const Icon(Icons.copy, size: 18),
                                ),
                                PlatformIconButton(
                                  tooltip: w.tr('重命名', 'Rename'),
                                  onPressed: busy
                                      ? null
                                      : () => change('rename', name(profile)),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                ),
                                PlatformIconButton(
                                  tooltip: w.tr('删除', 'Delete'),
                                  onPressed: busy
                                      ? null
                                      : () => change('delete', name(profile)),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    ),
    actions: [
      PlatformButton.quiet(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(w.tr('关闭', 'Close')),
      ),
    ],
  );
}

class _CompactToolbar extends StatelessWidget {
  const _CompactToolbar({
    required this.leading,
    required this.actions,
    this.inlineWidth = 700,
    this.leadingMaxWidth = 640,
  });
  final Widget leading;
  final List<Widget> actions;
  final double inlineWidth;
  final double leadingMaxWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, available) {
      final controls = Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: actions,
      );
      final scale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
        1.0,
        1.5,
      );
      if (available.maxWidth < inlineWidth * scale) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            leading,
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: controls),
          ],
        );
      }
      return Row(
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: leadingMaxWidth),
              child: leading,
            ),
          ),
          const SizedBox(width: 12),
          controls,
        ],
      );
    },
  );
}

class _ContextDescription extends StatelessWidget {
  const _ContextDescription({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      SelectableText(value, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
