import 'package:flutter/material.dart';

import 'platform_widgets.dart';

import 'typography.dart';
import 'feature_stage.dart';

import 'backend.dart';
import 'workspace.dart';

typedef NavigateNode = void Function(String pointer, Json schema);

class NodeForm extends StatelessWidget {
  const NodeForm({
    super.key,
    required this.workspace,
    required this.document,
    required this.schema,
    required this.pointer,
    required this.navigate,
    this.allowedKeys,
  });
  final Workspace workspace;
  final ConfigDocument document;
  final Json schema;
  final String pointer;
  final NavigateNode navigate;
  final List<String>? allowedKeys;

  @override
  Widget build(BuildContext context) {
    final node = document.tree?.at(pointer);
    final branches = asList(schema['oneOf'] ?? schema['anyOf']);
    if (branches.isNotEmpty) {
      return UnionEditor(
        workspace: workspace,
        document: document,
        schema: schema,
        pointer: pointer,
        navigate: navigate,
      );
    }
    final kind = schemaType(schema, node);
    if (kind == 'array') return _array(context, node);
    if (kind != 'object') {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: FieldCard(
          workspace: workspace,
          document: document,
          schema: schema,
          pointer: pointer,
          navigate: navigate,
          expanded: true,
        ),
      );
    }
    final properties = asMap(schema['properties']);
    final fixedKeys = (allowedKeys ?? properties.keys.toList())
        .where((key) => properties.containsKey(key))
        .toList();
    final custom = (node?.children ?? <ValueNode>[])
        .where(
          (child) =>
              !properties.containsKey(child.key) &&
              (allowedKeys == null || allowedKeys!.contains(child.key)),
        )
        .toList();
    final permitsCustom =
        schema['additionalProperties'] != false && allowedKeys == null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (pointer.isNotEmpty) ...[
          _NodeHeading(
            workspace: workspace,
            schema: schema,
            pointer: pointer,
            node: node,
            unset: node == null
                ? null
                : () =>
                      workspace.guard(() => workspace.edit(document, pointer)),
          ),
          const SizedBox(height: 12),
        ],
        if (custom.isNotEmpty || (permitsCustom && properties.isEmpty)) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  workspace.tr('实例', 'Entries'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (permitsCustom)
                PlatformButton.icon(
                  kind: PlatformButtonKind.tonal,
                  onPressed: workspace.busy
                      ? null
                      : () => _addKey(context, node),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(workspace.tr('添加', 'Add')),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (custom.isEmpty)
            _EmptyHint(
              workspace.tr(
                '此处尚无配置。添加一个名称以开始。',
                'No entries yet. Add a name to get started.',
              ),
            ),
          for (final child in custom)
            Card(
              child: ListTile(
                leading: Icon(
                  child.isObject
                      ? Icons.folder_outlined
                      : child.isArray
                      ? Icons.list_alt
                      : Icons.tune,
                ),
                title: FeatureFieldTitle(
                  workspace: workspace,
                  pointer: child.pointer,
                  child: Text(child.key),
                ),
                subtitle: Text(
                  _summary(workspace, child),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PlatformIconButton(
                      tooltip: workspace.tr('删除', 'Remove'),
                      onPressed: workspace.busy
                          ? null
                          : () => workspace.guard(
                              () => workspace.edit(document, child.pointer),
                            ),
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => navigate(
                  child.pointer,
                  asMap(schema['additionalProperties']),
                ),
              ),
            ),
          if (fixedKeys.isNotEmpty) const SizedBox(height: 16),
        ],
        for (final key in fixedKeys)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FieldCard(
              workspace: workspace,
              document: document,
              schema: asMap(properties[key]),
              pointer: pointerChild(pointer, key),
              navigate: navigate,
              requiredField: asList(schema['required']).contains(key),
            ),
          ),
        if (permitsCustom && properties.isNotEmpty && custom.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: PlatformButton.icon(
              kind: PlatformButtonKind.quiet,
              onPressed: workspace.busy ? null : () => _addKey(context, node),
              icon: const Icon(Icons.add),
              label: Text(workspace.tr('添加自定义字段', 'Add custom field')),
            ),
          ),
        if (!permitsCustom && fixedKeys.isEmpty && custom.isEmpty)
          _EmptyHint(
            workspace.tr(
              '这个分类没有可编辑字段。',
              'This category has no editable fields.',
            ),
          ),
      ],
    );
  }

  Future<void> _addKey(BuildContext context, ValueNode? node) async {
    final controller = TextEditingController();
    String? problem;
    final key = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => PlatformDialog(
          title: Text(workspace.tr('添加配置项', 'Add entry')),
          content: SizedBox(
            width: 440,
            child: PlatformTextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: workspace.tr('名称', 'Name'),
                errorText: problem,
                helperText: workspace.tr(
                  '名称中的点、斜杠和空格会作为名称的一部分保留。',
                  'Dots, slashes and spaces are kept as part of the name.',
                ),
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty &&
                    !(node?.children.any((child) => child.key == value) ??
                        false)) {
                  Navigator.pop(context, value);
                }
              },
            ),
          ),
          actions: [
            PlatformButton.quiet(
              onPressed: () => Navigator.pop(context),
              child: Text(workspace.tr('取消', 'Cancel')),
            ),
            PlatformButton.primary(
              onPressed: () {
                final value = controller.text;
                if (value.trim().isEmpty ||
                    (node?.children.any((child) => child.key == value) ??
                        false)) {
                  setState(
                    () => problem = workspace.tr(
                      '请输入尚不存在的名称。',
                      'Enter a new, nonempty name.',
                    ),
                  );
                } else {
                  Navigator.pop(context, value);
                }
              },
              child: Text(workspace.tr('添加', 'Add')),
            ),
          ],
        ),
      ),
    );
    // Dialog animations may still use the controller until the route is removed.
    if (key == null) return;
    final childSchema = asMap(schema['additionalProperties']);
    final success = await workspace.guard(() async {
      await workspace.edit(
        document,
        pointerChild(pointer, key),
        literal: initialLiteral(childSchema),
      );
      return true;
    });
    if (success == true) navigate(pointerChild(pointer, key), childSchema);
  }

  Widget _array(BuildContext context, ValueNode? node) {
    final children = node?.children ?? <ValueNode>[];
    final itemSchema = asMap(schema['items']);
    Future<void> mutate(void Function(List<String>) change) async {
      await workspace.flush(document);
      final values = (document.tree?.at(pointer)?.children ?? <ValueNode>[])
          .map((child) => child.literal)
          .toList();
      change(values);
      await workspace.edit(
        document,
        pointer,
        literal: '[${values.join(', ')}]',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _NodeHeading(
          workspace: workspace,
          schema: schema,
          pointer: pointer,
          node: node,
          unset: node == null
              ? null
              : () => workspace.guard(() => workspace.edit(document, pointer)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                workspace.tr(
                  '${children.length} 个项目',
                  '${children.length} items',
                ),
              ),
            ),
            PlatformButton.icon(
              kind: PlatformButtonKind.tonal,
              onPressed: workspace.busy
                  ? null
                  : () => workspace.guard(
                      () => mutate(
                        (values) => values.add(initialLiteral(itemSchema)),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: Text(workspace.tr('添加项目', 'Add item')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (children.isEmpty)
          _EmptyHint(workspace.tr('列表为空。', 'The list is empty.')),
        for (var index = 0; index < children.length; index++)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                radius: 15,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              title: Text(
                _summary(workspace, children[index]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => navigate(children[index].pointer, itemSchema),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlatformIconButton(
                    tooltip: workspace.tr('上移', 'Move up'),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: workspace.busy || index == 0
                        ? null
                        : () => workspace.guard(
                            () => mutate((values) {
                              final moving = values.removeAt(index);
                              values.insert(index - 1, moving);
                            }),
                          ),
                  ),
                  PlatformIconButton(
                    tooltip: workspace.tr('下移', 'Move down'),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: workspace.busy || index == children.length - 1
                        ? null
                        : () => workspace.guard(
                            () => mutate((values) {
                              final moving = values.removeAt(index);
                              values.insert(index + 1, moving);
                            }),
                          ),
                  ),
                  PlatformIconButton(
                    tooltip: workspace.tr('删除', 'Remove'),
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: workspace.busy
                        ? null
                        : () => workspace.guard(
                            () => mutate((values) => values.removeAt(index)),
                          ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _summary(Workspace workspace, ValueNode node) {
  if (node.isObject) {
    return workspace.tr(
      '${node.children.length} 个字段',
      '${node.children.length} fields',
    );
  }
  if (node.isArray) {
    return workspace.tr(
      '${node.children.length} 个项目',
      '${node.children.length} items',
    );
  }
  return node.value?.toString() ?? node.literal;
}

class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.workspace,
    required this.document,
    required this.schema,
    required this.pointer,
    required this.navigate,
    this.requiredField = false,
    this.expanded = false,
  });
  final Workspace workspace;
  final ConfigDocument document;
  final Json schema;
  final String pointer;
  final NavigateNode navigate;
  final bool requiredField;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final value = document.tree?.at(pointer);
    final kind = schemaType(schema, value);
    final complex =
        kind == 'object' ||
        kind == 'array' ||
        schema.containsKey('oneOf') ||
        schema.containsKey('anyOf');
    final description = workspace.description(schema);
    final label = workspace.label(schema, pointerName(pointer));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FeatureFieldTitle(
                        workspace: workspace,
                        pointer: pointer,
                        child: Text(
                          label,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (label != pointerName(pointer))
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: SelectableText(
                            pointerName(pointer),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFamily: AppTypography.monoFamily,
                                  fontFamilyFallback:
                                      AppTypography.monoFallback,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (requiredField)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      workspace.tr('必填', 'Required'),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: value != null || document.pending.containsKey(pointer)
                      ? PlatformIconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: workspace.tr(
                            '移除当前层设置',
                            'Unset in this file',
                          ),
                          onPressed: workspace.busy
                              ? null
                              : () => workspace.guard(
                                  () => workspace.edit(document, pointer),
                                ),
                          icon: const Icon(Icons.restart_alt, size: 18),
                        )
                      : null,
                ),
              ],
            ),
            if (description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: Text(
                  '${workspace.untranslated(schema) ? workspace.tr('英文说明 · ', '') : ''}$description',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(height: 1.5),
                ),
              ),
            if (description.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5, bottom: 8),
                child: Text(
                  workspace.tr(
                    '官方 schema 未提供说明',
                    'No description in the official schema',
                  ),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (complex)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      value == null
                          ? workspace.tr('未设置', 'Not set')
                          : _summary(workspace, value),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  PlatformButton.icon(
                    kind: PlatformButtonKind.tonal,
                    onPressed: () => navigate(pointer, schema),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text(workspace.tr('编辑', 'Edit')),
                  ),
                ],
              )
            else
              ScalarEditor(
                workspace: workspace,
                document: document,
                schema: schema,
                pointer: pointer,
                value: value,
              ),
          ],
        ),
      ),
    );
  }
}

class ScalarEditor extends StatefulWidget {
  const ScalarEditor({
    super.key,
    required this.workspace,
    required this.document,
    required this.schema,
    required this.pointer,
    required this.value,
  });
  final Workspace workspace;
  final ConfigDocument document;
  final Json schema;
  final String pointer;
  final ValueNode? value;
  @override
  State<ScalarEditor> createState() => _ScalarEditorState();
}

class _ScalarEditorState extends State<ScalarEditor> {
  late TextEditingController controller;
  String anyType = 'string';
  bool revealSecret = false;
  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: _text());
  }

  String _text() =>
      widget.document.pending[widget.pointer]?.text ??
      widget.value?.value?.toString() ??
      widget.value?.literal ??
      '';
  @override
  void didUpdateWidget(covariant ScalarEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (controller.text != _text()) {
      controller.text = _text();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> commit(String literal) async {
    await widget.workspace.guard(
      () => widget.workspace.edit(
        widget.document,
        widget.pointer,
        literal: literal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.workspace;
    final value = widget.value;
    final enums = asList(widget.schema['enum']);
    var kind = schemaType(widget.schema, value);
    final arbitrary = isFreeSchema(widget.schema) || kind == 'any';
    if (arbitrary && value == null) kind = anyType;
    final content = <Widget>[];
    if (arbitrary) {
      final type = value == null ? anyType : schemaType({}, value);
      content.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: PlatformSelect<String>(
            isExpanded: true,
            key: ValueKey('type-${widget.pointer}-$type'),
            value:
                [
                  'string',
                  'integer',
                  'number',
                  'boolean',
                  'array',
                  'object',
                  'datetime',
                ].contains(type)
                ? type
                : 'string',
            label: w.tr('值类型', 'Value type'),
            items: {
              'string': w.tr('文本', 'Text'),
              'integer': w.tr('整数', 'Integer'),
              'number': w.tr('小数', 'Number'),
              'boolean': w.tr('开关', 'Boolean'),
              'array': w.tr('列表', 'List'),
              'object': w.tr('表', 'Table'),
              'datetime': w.tr('日期时间', 'Date / time'),
            },
            onChanged: w.busy
                ? null
                : (selection) {
                    if (selection == null) return;
                    setState(() => anyType = selection);
                    commit(initialLiteral({'type': selection}));
                  },
          ),
        ),
      );
    }
    if (enums.isNotEmpty) {
      final current = value == null
          ? null
          : enums.indexWhere(
              (entry) =>
                  literalForJson(entry) == value.literal ||
                  entry.toString() == value.value?.toString(),
            );
      content.add(
        PlatformSelect<int>(
          isExpanded: true,
          key: ValueKey('enum-${widget.pointer}-${value?.literal}'),
          value: current != null && current >= 0 ? current : null,
          hint: Text(
            value == null
                ? w.tr('未设置 · 选择一个值', 'Not set · choose a value')
                : w.tr(
                    '当前值不在选项中：${value.literal}',
                    'Current value is not listed: ${value.literal}',
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          items: {
            for (var i = 0; i < enums.length; i++) i: enums[i].toString(),
          },
          onChanged: w.busy
              ? null
              : (index) {
                  if (index != null) commit(literalForJson(enums[index]));
                },
        ),
      );
    } else if (kind == 'boolean') {
      content.add(
        PlatformSegments<int>(
          segments: [
            ButtonSegment(value: -1, label: Text(w.tr('未设置', 'Not set'))),
            ButtonSegment(value: 1, label: Text(w.tr('启用', 'On'))),
            ButtonSegment(value: 0, label: Text(w.tr('禁用', 'Off'))),
          ],
          selected: {
            value == null
                ? -1
                : value.value == true || value.literal == 'true'
                ? 1
                : 0,
          },
          onSelectionChanged: w.busy
              ? null
              : (selection) {
                  final selected = selection.first;
                  if (selected < 0) {
                    w.guard(() => w.edit(widget.document, widget.pointer));
                  } else {
                    commit(selected == 1 ? 'true' : 'false');
                  }
                },
        ),
      );
    } else {
      final multiline =
          kind == 'string' &&
          (controller.text.contains('\n') ||
              widget.pointer.contains('prompt') ||
              widget.pointer.contains('instructions'));
      final constraints = <String>[
        if (widget.schema['minimum'] != null) '≥ ${widget.schema['minimum']}',
        if (widget.schema['exclusiveMinimum'] != null)
          '> ${widget.schema['exclusiveMinimum']}',
        if (widget.schema['maximum'] != null) '≤ ${widget.schema['maximum']}',
        if (widget.schema['minLength'] != null)
          w.tr(
            '最短 ${widget.schema['minLength']} 字符',
            'Min ${widget.schema['minLength']} characters',
          ),
        if (widget.schema['maxLength'] != null)
          w.tr(
            '最长 ${widget.schema['maxLength']} 字符',
            'Max ${widget.schema['maxLength']} characters',
          ),
      ];
      final normalizedPointer = widget.pointer.toLowerCase();
      final sensitive =
          kind == 'string' &&
          const [
            'secret',
            'token',
            'password',
            'api_key',
            'authorization',
          ].any(normalizedPointer.contains) &&
          !normalizedPointer.contains('limit') &&
          !normalizedPointer.contains('budget');
      final input = PlatformTextField(
        controller: controller,
        enabled: !w.busy,
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 8 : 1,
        obscureText: sensitive && !multiline && !revealSecret,
        onChanged: (text) => w.stage(
          widget.document,
          widget.pointer,
          text,
          kind == 'string' ? stringLiteral(text) : text,
        ),
        decoration: InputDecoration(
          hintText: value == null ? w.tr('未设置', 'Not set') : null,
          labelText: kind == 'string' ? w.tr('值', 'Value') : kind,
          suffixIcon: sensitive && !multiline
              ? PlatformIconButton(
                  tooltip: revealSecret
                      ? w.tr('隐藏', 'Hide')
                      : w.tr('显示', 'Reveal'),
                  onPressed: () => setState(() => revealSecret = !revealSecret),
                  icon: Icon(
                    revealSecret
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                )
              : null,
        ),
        onSubmitted: multiline
            ? null
            : (_) => commit(
                kind == 'string'
                    ? stringLiteral(controller.text)
                    : controller.text,
              ),
      );
      final apply = PlatformButton.tonal(
        onPressed: w.busy
            ? null
            : () => commit(
                kind == 'string'
                    ? stringLiteral(controller.text)
                    : controller.text,
              ),
        child: Text(w.tr('应用', 'Apply')),
      );
      final helper = constraints.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 12, top: 6),
              child: Text(
                constraints.join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
      content.add(
        LayoutBuilder(
          builder: (context, available) {
            if (available.maxWidth < 360) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  input,
                  ?helper,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: apply),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: multiline
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    Expanded(child: input),
                    const SizedBox(width: 10),
                    apply,
                  ],
                ),
                ?helper,
              ],
            );
          },
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: content,
    );
  }
}

class UnionEditor extends StatefulWidget {
  const UnionEditor({
    super.key,
    required this.workspace,
    required this.document,
    required this.schema,
    required this.pointer,
    required this.navigate,
  });
  final Workspace workspace;
  final ConfigDocument document;
  final Json schema;
  final String pointer;
  final NavigateNode navigate;
  @override
  State<UnionEditor> createState() => _UnionEditorState();
}

class _UnionEditorState extends State<UnionEditor> {
  int? chosen;
  @override
  void didUpdateWidget(covariant UnionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pointer != widget.pointer) chosen = null;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.workspace;
    final branches = asList(widget.schema['oneOf'] ?? widget.schema['anyOf'])
        .map(asMap)
        .toList();
    final value = widget.document.tree?.at(widget.pointer);
    final detected = value == null
        ? -1
        : branches.indexWhere((branch) => schemaMatchesShape(branch, value));
    final selected = (chosen ?? (detected >= 0 ? detected : 0)).clamp(
      0,
      branches.length - 1,
    );
    final branch = branches[selected.clamp(0, branches.length - 1)];
    String branchName(int index) {
      final item = branches[index];
      final enums = asList(item['enum']);
      if (enums.isNotEmpty) {
        return enums.map((item) => item.toString()).join(' / ');
      }
      final properties = asMap(item['properties']);
      for (final discriminator in ['type', 'kind']) {
        final values = asList(asMap(properties[discriminator])['enum']);
        if (values.isNotEmpty) return values.join(' / ');
      }
      final keys = properties.keys.toList();
      if (keys.length == 1) return keys.single;
      final type = schemaType(item);
      return w.label(
        item,
        type == 'object' ? w.tr('详细配置', 'Detailed configuration') : type,
      );
    }

    return Column(
      children: [
        if (value != null && detected < 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              w.tr(
                '当前值与已知配置形式不匹配；选择一种形式后可重新配置。',
                'The current value does not match a known form. Choose a form to configure it again.',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: PlatformSelect<int>(
                  isExpanded: true,
                  key: ValueKey('${widget.pointer}-$selected'),
                  value: selected,
                  label: w.tr('配置形式', 'Configuration form'),
                  items: {
                    for (var i = 0; i < branches.length; i++) i: branchName(i),
                  },
                  onChanged: w.busy
                      ? null
                      : (index) {
                          if (index == null) return;
                          w.guard(() async {
                            await w.edit(
                              widget.document,
                              widget.pointer,
                              literal: initialLiteral(branches[index]),
                            );
                            if (mounted) setState(() => chosen = index);
                          });
                        },
                ),
              ),
              const SizedBox(width: 16),
              if (value == null) Text(w.tr('未设置', 'Not set')),
              if (value != null)
                PlatformIconButton(
                  tooltip: w.tr('移除当前层设置', 'Unset in this file'),
                  onPressed: w.busy
                      ? null
                      : () => w.guard(
                          () => w.edit(widget.document, widget.pointer),
                        ),
                  icon: const Icon(Icons.restart_alt),
                ),
            ],
          ),
        ),
        Expanded(
          child: NodeForm(
            workspace: w,
            document: widget.document,
            schema: branch,
            pointer: widget.pointer,
            navigate: widget.navigate,
          ),
        ),
      ],
    );
  }
}

class _NodeHeading extends StatelessWidget {
  const _NodeHeading({
    required this.workspace,
    required this.schema,
    required this.pointer,
    required this.node,
    required this.unset,
  });
  final Workspace workspace;
  final Json schema;
  final String pointer;
  final ValueNode? node;
  final VoidCallback? unset;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: FeatureFieldTitle(
              workspace: workspace,
              pointer: pointer,
              child: Text(
                workspace.label(schema, pointerName(pointer)),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          if (unset != null)
            PlatformButton.icon(
              kind: PlatformButtonKind.quiet,
              onPressed: workspace.busy ? null : unset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(workspace.tr('取消设置', 'Unset')),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SelectableText(
            pointer,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: AppTypography.monoFamily,
              fontFamilyFallback: AppTypography.monoFallback,
            ),
          ),
          if (Workspace.isFeatureGroup(pointer))
            FeatureCatalogStatus(workspace: workspace),
        ],
      ),
      if (workspace.description(schema).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(workspace.description(schema)),
        ),
      if (node == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            workspace.tr(
              '当前文件未设置；编辑下方字段可添加。',
              'Not set in this file. Edit a field below to add it.',
            ),
          ),
        ),
    ],
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
