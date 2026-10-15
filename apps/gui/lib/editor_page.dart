import 'package:flutter/material.dart';

import 'backend.dart';
import 'form_editor.dart';
import 'typography.dart';
import 'workspace.dart';
import 'utility_pages.dart' show ProfilesDialog;

class _Location {
  _Location(this.pointer, this.schema, {this.keys, this.title, this.gate});
  final String pointer;
  final Json schema;
  final List<String>? keys;
  final String? title;
  final _Location? gate;
}

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.workspace,
    required this.openDialog,
    required this.closeDocument,
  });
  final Workspace workspace;
  final VoidCallback openDialog;
  final Future<void> Function(ConfigDocument) closeDocument;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  String query = '';
  final queryController = TextEditingController();
  final tabScrollController = ScrollController();
  final Map<String, GlobalKey> tabKeys = {};
  String? visibleTabPath;
  double? tabViewportWidth;
  double? tabFontSize;
  bool navigationCollapsed = false;
  String view = 'form';
  String? selectedCategory;
  final Map<String, List<_Location>> locations = {};
  Json? activeSchema;
  Workspace get w => widget.workspace;
  @override
  void dispose() {
    queryController.dispose();
    tabScrollController.dispose();
    super.dispose();
  }

  List<_Location> get trail =>
      locations.putIfAbsent(w.active?.path ?? '', () => []);
  void navigate(String pointer, Json schema) =>
      setState(() => trail.add(_Location(pointer, schema)));

  void _manageProfiles() => showDialog<void>(
    context: context,
    builder: (_) => ProfilesDialog(workspace: w),
  );

  void _revealActiveTab(double width, double fontSize) {
    final path = w.active?.path;
    if (path == visibleTabPath &&
        width == tabViewportWidth &&
        fontSize == tabFontSize) {
      return;
    }
    visibleTabPath = path;
    tabViewportWidth = width;
    tabFontSize = fontSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || w.active?.path != path) return;
      final tabContext = tabKeys[path]?.currentContext;
      if (tabContext != null) {
        Scrollable.ensureVisible(tabContext, alignment: .5);
      }
    });
  }

  Widget _documentBar(BuildContext context) => LayoutBuilder(
    builder: (context, available) {
      final document = w.active;
      final scaledFont = MediaQuery.textScalerOf(context)
          .scale(Theme.of(context).textTheme.labelLarge?.fontSize ?? 13);
      final compact = available.maxWidth < 720 * (scaledFont / 13);
      final save = w.busy || document == null || !document.dirty
          ? null
          : () => w.guard(() => w.save(document));
      return SizedBox(
        height: 48 + (scaledFont - 13).clamp(0.0, double.infinity) * 1.4,
        child: Row(
          children: [
            Expanded(
              child: document == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        w.tr('未打开文件', 'No open files'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, tabArea) {
                        _revealActiveTab(tabArea.maxWidth, scaledFont);
                        return SingleChildScrollView(
                          controller: tabScrollController,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < w.documents.length; i++)
                                _fileTab(
                                  context,
                                  i,
                                  labelWidth: (tabArea.maxWidth - 104).clamp(
                                    32.0,
                                    200.0,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 24, child: VerticalDivider(width: 17)),
            if (compact) ...[
              IconButton(
                onPressed: w.busy ? null : widget.openDialog,
                tooltip: w.tr('打开配置文件', 'Open configuration'),
                icon: const Icon(Icons.file_open_outlined, size: 19),
              ),
              IconButton.filledTonal(
                onPressed: save,
                tooltip: w.tr('保存', 'Save'),
                icon: const Icon(Icons.save_outlined, size: 19),
              ),
              PopupMenuButton<String>(
                enabled: !w.busy,
                tooltip: w.tr('更多操作', 'More actions'),
                icon: const Icon(Icons.more_horiz, size: 20),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'profiles',
                    child: Text(w.tr('管理 Profiles', 'Manage profiles')),
                  ),
                  const PopupMenuDivider(),
                  ..._pathItems(),
                ],
                onSelected: (action) {
                  if (action == 'profiles') {
                    _manageProfiles();
                  } else {
                    w.guard(() => w.open(action));
                  }
                },
              ),
            ] else ...[
              PopupMenuButton<String>(
                enabled: !w.busy,
                tooltip: w.tr('发现配置文件', 'Discover configuration files'),
                icon: const Icon(Icons.folder_copy_outlined, size: 20),
                itemBuilder: (_) => _pathItems(),
                onSelected: (path) => w.guard(() => w.open(path)),
              ),
              IconButton(
                tooltip: w.tr('管理 Profiles', 'Manage profiles'),
                icon: const Icon(Icons.person_outline, size: 20),
                onPressed: w.busy ? null : _manageProfiles,
              ),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: w.busy ? null : widget.openDialog,
                icon: const Icon(Icons.file_open_outlined, size: 18),
                label: Text(w.tr('打开', 'Open')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(w.tr('保存', 'Save')),
              ),
            ],
            const SizedBox(width: 12),
          ],
        ),
      );
    },
  );

  Widget _editingToolbar(BuildContext context, ConfigDocument document) =>
      LayoutBuilder(
        builder: (context, available) {
          final theme = Theme.of(context);
          final textStyle = theme.textTheme.labelLarge!.copyWith(
            fontWeight: FontWeight.w400,
            height: 1.25,
          );
          final fontSize = textStyle.fontSize!;
          final scale =
              MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
          final compact = available.maxWidth < 650 * scale;
          final buttonStyle = ButtonStyle(
            textStyle: WidgetStatePropertyAll(textStyle),
            minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Tooltip(
                message: w.tr('校验', 'Validate'),
                child: TextButton(
                  style: buttonStyle,
                  onPressed: w.busy
                      ? null
                      : () => w.guard(() async {
                          await w.flush(document);
                          final result = await w.backend.call('validate', {
                            'content': document.content,
                          });
                          document.diagnostics = asList(result['diagnostics']);
                          w.notice = result['valid'] == true
                              ? w.tr('校验通过', 'Validation passed')
                              : w.tr(
                                  '请查看下方校验结果',
                                  'Review the validation results below',
                                );
                          await w.inspect(document);
                        }),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fact_check_outlined, size: 18),
                      if (!compact) ...[
                        const SizedBox(width: 8),
                        Text(w.tr('校验', 'Validate')),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                style: buttonStyle,
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: 'form',
                    label: compact ? null : Text(w.tr('表单', 'Form')),
                    tooltip: w.tr('表单', 'Form'),
                    icon: const Icon(Icons.view_list_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: 'toml',
                    label: compact ? null : const Text('TOML'),
                    tooltip: 'TOML',
                    icon: const Icon(Icons.code, size: 18),
                  ),
                  ButtonSegment(
                    value: 'diff',
                    label: compact ? null : Text(w.tr('差异', 'Changes')),
                    tooltip: w.tr('差异', 'Changes'),
                    icon: const Icon(Icons.difference_outlined, size: 18),
                  ),
                ],
                selected: {view},
                onSelectionChanged: w.busy
                    ? null
                    : (value) async {
                        final success = await w.guard(() async {
                          await w.flush(document);
                          if (value.first == 'form') {
                            await w.inspect(document);
                          }
                          return true;
                        });
                        if (mounted && success == true) {
                          setState(() => view = value.first);
                        }
                      },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Tooltip(
                  message: document.path,
                  child: SelectionArea(
                    child: Text(
                      document.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );

  Future<void> _showNavigation() => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      alignment: Alignment.centerLeft,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 360,
        height: MediaQuery.sizeOf(dialogContext).height * .8,
        child: StatefulBuilder(
          builder: (context, refresh) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        w.tr('配置分类', 'Configuration categories'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      tooltip: w.tr('关闭', 'Close'),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _sidebar(
                  context,
                  onSelected: () => Navigator.pop(dialogContext),
                  onQueryChanged: (value) {
                    setState(() => query = value);
                    refresh(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void locate(_Location location) {
    setState(() {
      view = 'form';
      trail.clear();
      trail.add(location.gate ?? location);
    });
    if (location.gate != null) {
      w.notice = w.tr(
        '请先在此选择包含 ${pointerName(location.pointer)} 的配置形式。',
        'First choose the configuration form that contains ${pointerName(location.pointer)}.',
      );
      w.changed();
    }
  }

  List<Json> get categories {
    final raw = asList(w.schema['categories']).map(asMap).toList();
    if (raw.isEmpty) {
      raw.addAll([
        {
          'id': 'all',
          'label_zh': '所有配置',
          'label_en': 'All settings',
          'keys': asMap(w.formSchema['properties']).keys.toList(),
        },
      ]);
    }
    final properties = asMap(w.formSchema['properties']);
    final unknown =
        w.active?.tree?.children
            .where((child) => !properties.containsKey(child.key))
            .map((child) => child.key)
            .toList() ??
        <String>[];
    if (unknown.isNotEmpty) {
      raw.add({
        'id': 'unknown',
        'label_zh': '未知配置项',
        'label_en': 'Unknown settings',
        'keys': unknown,
      });
    }
    return raw;
  }

  _Location get location {
    if (trail.isNotEmpty) return trail.last;
    final category =
        categories
            .where((item) => item['id'] == selectedCategory)
            .firstOrNull ??
        categories.first;
    return _Location(
      '',
      w.formSchema,
      keys: asList(category['keys']).map((key) => key.toString()).toList(),
      title: w.label(category, category['id']?.toString() ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(activeSchema, w.schema)) {
      locations.clear();
      activeSchema = w.schema;
    }
    final document = w.active;
    tabKeys.removeWhere(
      (path, _) => !w.documents.any((item) => item.path == path),
    );
    if (document == null) visibleTabPath = null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _documentBar(context),
        const Divider(),
        if (document == null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.description_outlined, size: 48),
                  const SizedBox(height: 18),
                  Text(
                    w.tr(
                      '打开一个 config.toml 开始配置',
                      'Open a config.toml to get started',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: widget.openDialog,
                    child: Text(w.tr('打开配置文件', 'Open configuration')),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: _editingToolbar(context, document),
          ),
          const Divider(),
          Expanded(
            child: view == 'toml'
                ? RawEditor(
                    key: ValueKey('raw-${document.path}'),
                    workspace: w,
                    document: document,
                  )
                : view == 'diff'
                ? DiffView(
                    key: ValueKey('${document.path}-${document.generation}'),
                    workspace: w,
                    document: document,
                  )
                : LayoutBuilder(
                    builder: (context, available) {
                      final scale =
                          (MediaQuery.textScalerOf(context).scale(14) / 14)
                              .clamp(1.0, 1.5);
                      final narrowNavigation = available.maxWidth < 780 * scale;
                      final compactNavigation =
                          navigationCollapsed || narrowNavigation;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!compactNavigation) ...[
                            SizedBox(width: 216, child: _sidebar(context)),
                            const VerticalDivider(),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  constraints: const BoxConstraints(
                                    minHeight: 40,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      if (compactNavigation) ...[
                                        TextButton.icon(
                                          onPressed: narrowNavigation
                                              ? _showNavigation
                                              : () => setState(
                                                  () => navigationCollapsed =
                                                      false,
                                                ),
                                          icon: const Icon(
                                            Icons.menu,
                                            size: 18,
                                          ),
                                          label: Text(w.tr('分类', 'Categories')),
                                        ),
                                        const SizedBox(width: 8),
                                      ] else ...[
                                        IconButton(
                                          onPressed: () => setState(
                                            () => navigationCollapsed = true,
                                          ),
                                          tooltip: w.tr(
                                            '收起分类栏',
                                            'Collapse categories',
                                          ),
                                          icon: CustomPaint(
                                            size: const Size(20, 20),
                                            painter: _CollapseCategoriesPainter(
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                            ),
                                          ),
                                          iconSize: 20,
                                          style: IconButton.styleFrom(
                                            minimumSize: const Size(36, 36),
                                            padding: const EdgeInsets.all(8),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      if (trail.isNotEmpty)
                                        IconButton(
                                          onPressed: () => setState(
                                            () => trail.removeLast(),
                                          ),
                                          tooltip: w.tr('返回上一级', 'Back'),
                                          icon: const Icon(
                                            Icons.arrow_back,
                                            size: 19,
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          location.title ??
                                              w.label(
                                                location.schema,
                                                pointerName(location.pointer),
                                              ),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (trail.length > 1)
                                        TextButton(
                                          onPressed: () =>
                                              setState(() => trail.clear()),
                                          child: Text(
                                            w.tr('返回分类', 'Back to category'),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                Expanded(
                                  child:
                                      document.tree == null &&
                                          document.content.trim().isNotEmpty
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(32),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.error_outline,
                                                  size: 38,
                                                ),
                                                const SizedBox(height: 12),
                                                Text(
                                                  w.tr(
                                                    '文件暂时无法显示为表单，请在 TOML 中修正语法。',
                                                    'Fix the TOML syntax to use the form editor.',
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                TextButton(
                                                  onPressed: () => setState(
                                                    () => view = 'toml',
                                                  ),
                                                  child: Text(
                                                    w.tr(
                                                      '编辑 TOML',
                                                      'Edit TOML',
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        )
                                      : NodeForm(
                                          key: ValueKey(
                                            '${document.path}-${location.pointer}-${selectedCategory ?? ''}',
                                          ),
                                          workspace: w,
                                          document: document,
                                          schema: location.schema,
                                          pointer: location.pointer,
                                          allowedKeys: location.keys,
                                          navigate: navigate,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (document.diagnostics.isNotEmpty)
            DiagnosticsPanel(
              workspace: w,
              diagnostics: document.diagnostics,
              onLocate: (pointer) {
                final match = _searchEntries()
                    .where((entry) => entry.pointer == pointer)
                    .firstOrNull;
                if (match != null) {
                  locate(match);
                }
              },
            ),
        ],
      ],
    );
  }

  Widget _fileTab(
    BuildContext context,
    int index, {
    required double labelWidth,
  }) {
    final document = w.documents[index];
    final active = index == w.activeIndex;
    return Padding(
      key: tabKeys.putIfAbsent(document.path, GlobalKey.new),
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: active
            ? Theme.of(context).colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
        child: InkWell(
          onTap: () => w.select(index),
          child: Tooltip(
            message: document.path,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Icon(
                      document.dirty
                          ? Icons.circle
                          : Icons.description_outlined,
                      size: document.dirty ? 7 : 15,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: labelWidth),
                    child: Text(
                      _tabName(document),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(width: 7),
                  IconButton(
                    onPressed: w.busy
                        ? null
                        : () => widget.closeDocument(document),
                    tooltip: w.tr('关闭文件', 'Close file'),
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _tabName(ConfigDocument document) {
    if (w.documents.where((item) => item.name == document.name).length <= 1) {
      return document.name;
    }
    final segments = document.path.replaceAll('\\', '/').split('/');
    for (var count = 2; count <= segments.length; count++) {
      final suffix = segments.skip(segments.length - count).join('/');
      final clashes = w.documents.any((other) {
        if (identical(other, document)) return false;
        final parts = other.path.replaceAll('\\', '/').split('/');
        return parts.length >= count &&
            parts.skip(parts.length - count).join('/') == suffix;
      });
      if (!clashes) return suffix;
    }
    return document.path;
  }

  List<PopupMenuEntry<String>> _pathItems() {
    final items = <PopupMenuEntry<String>>[];
    void add(dynamic entry, String label) {
      final path = entry is String ? entry : asMap(entry)['path']?.toString();
      if (path != null && path.isNotEmpty) {
        items.add(
          PopupMenuItem(
            value: path,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                Text(path, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        );
      }
    }

    add(w.paths['user'], w.tr('用户配置', 'User configuration'));
    final system = w.paths['system'];
    if (system is List) {
      for (final entry in system) {
        add(entry, w.tr('系统配置', 'System configuration'));
      }
    } else {
      add(system, w.tr('系统配置', 'System configuration'));
    }
    for (final entry in asList(w.paths['projects'])) {
      add(entry, w.tr('项目配置', 'Project configuration'));
    }
    for (final entry in asList(w.paths['profiles'])) {
      add(entry, 'Profile · ${asMap(entry)['name'] ?? ''}');
    }
    return items;
  }

  Widget _sidebar(
    BuildContext context, {
    VoidCallback? onSelected,
    ValueChanged<String>? onQueryChanged,
  }) {
    final matches = query.trim().isEmpty
        ? <_Location>[]
        : _searchEntries()
              .where((entry) {
                final text =
                    '${entry.pointer} ${w.label(entry.schema, '')} ${w.description(entry.schema)}'
                        .toLowerCase();
                return text.contains(query.trim().toLowerCase());
              })
              .take(100)
              .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: queryController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 19),
              hintText: w.tr('搜索名称、键或说明', 'Search settings'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 12,
              ),
            ),
            onChanged:
                onQueryChanged ?? (value) => setState(() => query = value),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: query.trim().isNotEmpty
                ? [
                    if (matches.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(w.tr('没有匹配项', 'No matches')),
                      ),
                    for (final entry in matches)
                      ListTile(
                        dense: true,
                        title: Text(
                          w.label(entry.schema, pointerName(entry.pointer)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry.pointer,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () {
                          locate(entry);
                          onSelected?.call();
                        },
                      ),
                  ]
                : [
                    for (final category in categories)
                      _category(context, category, onSelected: onSelected),
                  ],
          ),
        ),
      ],
    );
  }

  Widget _category(
    BuildContext context,
    Json category, {
    VoidCallback? onSelected,
  }) {
    final selected =
        (selectedCategory ?? categories.first['id']) == category['id'];
    final keys = asList(category['keys']).map((key) => key.toString()).toList();
    final props = asMap(w.formSchema['properties']);
    return ListTileTheme(
      data: ListTileTheme.of(context)
          .copyWith(minLeadingWidth: 20, horizontalTitleGap: 8),
      child: ExpansionTile(
        key: PageStorageKey(category['id']),
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: selected,
        leading: Icon(
          Icons.folder_outlined,
          size: 18,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: InkWell(
          onTap: () {
            setState(() {
              selectedCategory = category['id'].toString();
              trail.clear();
            });
            onSelected?.call();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              w.label(category, category['id']?.toString() ?? ''),
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
        children: [
          for (final key in keys)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.only(left: 52, right: 8),
              title: Text(
                w.label(asMap(props[key]), key),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () {
                setState(() {
                  selectedCategory = category['id'].toString();
                  trail.clear();
                  trail.add(
                    _Location(pointerChild('', key), asMap(props[key])),
                  );
                });
                onSelected?.call();
              },
            ),
        ],
      ),
    );
  }

  List<_Location> _searchEntries() {
    final found = <String, _Location>{};
    void walk(Json schema, String pointer, int depth, [_Location? gate]) {
      if (depth > 128) return;
      if (pointer.isNotEmpty) {
        final existing = found[pointer];
        if (existing == null || (existing.gate != null && gate == null)) {
          found[pointer] = _Location(pointer, schema, gate: gate);
        }
      }
      for (final entry in asMap(schema['properties']).entries) {
        walk(
          asMap(entry.value),
          pointerChild(pointer, entry.key),
          depth + 1,
          gate,
        );
      }
      final branches = asList(schema['oneOf'] ?? schema['anyOf']);
      for (final branch in branches) {
        final node = w.active?.tree?.at(pointer);
        final blocked =
            node == null || !schemaMatchesShape(asMap(branch), node);
        walk(
          asMap(branch),
          pointer,
          depth + 1,
          gate ?? (blocked ? _Location(pointer, schema) : null),
        );
      }
      if (branches.isNotEmpty) return;
      final node = w.active?.tree?.at(pointer);
      if (node != null) {
        final properties = asMap(schema['properties']);
        for (final child in node.children.where(
          (child) => !properties.containsKey(child.key),
        )) {
          walk(
            asMap(
              node.isArray ? schema['items'] : schema['additionalProperties'],
            ),
            child.pointer,
            depth + 1,
            gate,
          );
        }
      }
    }

    walk(w.formSchema, '', 0);
    return found.values.toList();
  }
}

class _CollapseCategoriesPainter extends CustomPainter {
  const _CollapseCategoriesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(size.width / 20, size.height / 20);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(1, 2, 18, 16),
        const Radius.circular(2),
      ),
      stroke,
    );
    canvas.drawLine(const Offset(6, 2), const Offset(6, 18), stroke);
    canvas.drawLine(const Offset(10, 10), const Offset(16, 10), stroke);
    canvas.drawPath(
      Path()
        ..moveTo(13, 7)
        ..lineTo(10, 10)
        ..lineTo(13, 13),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CollapseCategoriesPainter oldDelegate) =>
      oldDelegate.color != color;
}

class RawEditor extends StatefulWidget {
  const RawEditor({super.key, required this.workspace, required this.document});
  final Workspace workspace;
  final ConfigDocument document;
  @override
  State<RawEditor> createState() => _RawEditorState();
}

class _RawEditorState extends State<RawEditor> {
  late final controller = TextEditingController(text: widget.document.content);
  @override
  void didUpdateWidget(covariant RawEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (controller.text != widget.document.content) {
      controller.text = widget.document.content;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: TextField(
      controller: controller,
      enabled: !widget.workspace.busy,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(
        fontFamily: AppTypography.monoFamily,
        fontFamilyFallback: AppTypography.monoFallback,
        fontSize: 13,
        height: 1.55,
      ),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.all(14),
      ),
      onChanged: (content) =>
          widget.workspace.rawEdit(widget.document, content),
    ),
  );
}

class DiffView extends StatefulWidget {
  const DiffView({super.key, required this.workspace, required this.document});
  final Workspace workspace;
  final ConfigDocument document;
  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  late final future = widget.workspace.backend.call('diff', {
    'before': widget.document.saved,
    'after': widget.document.content,
  });
  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(child: Text(snapshot.error.toString()));
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final text = snapshot.data!['diff']?.toString() ?? '';
      if (text.isEmpty) {
        return Center(
          child: Text(widget.workspace.tr('没有未保存的差异。', 'No unsaved changes.')),
        );
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: text
                .split('\n')
                .map(
                  (line) => Container(
                    width: double.infinity,
                    color: line.startsWith('+')
                        ? Colors.green.withValues(alpha: .10)
                        : line.startsWith('-')
                        ? Colors.red.withValues(alpha: .10)
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontFamily: AppTypography.monoFamily,
                        fontFamilyFallback: AppTypography.monoFallback,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      );
    },
  );
}

class DiagnosticsPanel extends StatelessWidget {
  const DiagnosticsPanel({
    super.key,
    required this.workspace,
    required this.diagnostics,
    this.onLocate,
  });
  final Workspace workspace;
  final List<dynamic> diagnostics;
  final void Function(String)? onLocate;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxHeight: 155),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: ListView(
      shrinkWrap: true,
      children: diagnostics.map((raw) {
        final item = asMap(raw);
        final severity = item['severity']?.toString() ?? 'error';
        final pointer =
            item['pointer']?.toString() ?? item['path']?.toString() ?? '';
        return ListTile(
          dense: true,
          leading: Icon(
            severity == 'error' ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: severity == 'error'
                ? Theme.of(context).colorScheme.error
                : null,
          ),
          title: Text(
            item['message']?.toString() ?? raw.toString(),
            maxLines: 3,
          ),
          subtitle: pointer.isEmpty ? null : Text(pointer),
          onTap: onLocate == null || pointer.isEmpty
              ? null
              : () => onLocate!(pointer),
        );
      }).toList(),
    ),
  );
}
