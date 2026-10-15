import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'editor_page.dart';
import 'utility_pages.dart';
import 'typography.dart';
import 'workspace.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
    runApp(ConfiguratorApp(workspace: Workspace(CodexBackend())));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: SelectableText(
                'Codex Configurator\n\n无法启动配置服务 / Could not start the configuration service.\n\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ConfiguratorApp extends StatefulWidget {
  const ConfiguratorApp({super.key, required this.workspace});
  final Workspace workspace;
  @override
  State<ConfiguratorApp> createState() => _ConfiguratorAppState();
}

class _ConfiguratorAppState extends State<ConfiguratorApp>
    with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();
  int page = 0;
  bool loading = true;
  bool choosingProject = false;
  ThemeMode themeMode = ThemeMode.system;
  Workspace get w => widget.workspace;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    w.chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    w.addListener(_updated);
    _initialize();
  }

  Future<void> _initialize() async {
    await w.guard(w.initialize);
    if (mounted) setState(() => loading = false);
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    w.removeListener(_updated);
    w.dispose();
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    for (final document
        in w.documents.where((document) => document.dirty).toList()) {
      if (!await _confirmClose(document)) return AppExitResponse.cancel;
    }
    return AppExitResponse.exit;
  }

  Future<bool> _confirmClose(ConfigDocument document) async {
    if (!document.dirty) return true;
    final context = navigatorKey.currentContext;
    if (context == null || w.busy) return false;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(w.tr('保存更改？', 'Save changes?')),
        content: SizedBox(
          width: 450,
          child: Text(
            w.tr(
              '${document.path}\n\n这个文件有尚未保存的更改。',
              '${document.path}\n\nThis file has unsaved changes.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(w.tr('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(w.tr('放弃更改', 'Discard')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(w.tr('保存', 'Save')),
          ),
        ],
      ),
    );
    if (action == 'discard') return true;
    if (action == 'save') return await w.guard(() => w.save(document)) == true;
    return false;
  }

  Future<void> _close(ConfigDocument document) async {
    if (await _confirmClose(document)) w.close(document);
  }

  Future<void> _openProject() async {
    if (loading || w.busy || choosingProject) return;
    setState(() => choosingProject = true);
    String? selected;
    try {
      selected = await getDirectoryPath(
        initialDirectory: w.projectDirectory,
        confirmButtonText: w.tr('打开项目', 'Open project'),
      );
    } catch (error) {
      w.error = error.toString();
      w.changed();
    } finally {
      if (mounted) setState(() => choosingProject = false);
    }
    if (mounted && selected != null && !w.isCurrentProject(selected)) {
      await _changeProject(selected);
    }
  }

  Future<void> _changeProject(String? directory) async {
    if (w.busy || choosingProject) return;
    for (final document in w.projectDocuments) {
      if (!await _confirmClose(document)) return;
    }
    if (!mounted) return;
    final changed = await w.guard(() async {
      await w.setProject(directory);
      return true;
    });
    if (mounted && changed == true) setState(() => page = 0);
  }

  Future<void> _openDialog() async {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(w.tr('打开配置文件', 'Open configuration')),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: w.tr('完整文件路径', 'Full file path'),
                  hintText: w.tr(
                    '粘贴 config.toml 的路径',
                    'Paste a path to config.toml',
                  ),
                ),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    Navigator.pop(context, value.trim());
                  }
                },
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  w.tr(
                    '不存在的文件将在首次保存时创建。',
                    'A missing file will be created when you save.',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(w.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: Text(w.tr('打开', 'Open')),
          ),
        ],
      ),
    );
    if (path != null) {
      await w.guard(() => w.open(path));
      if (mounted) setState(() => page = 0);
    }
  }

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff376b78),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      brightness: brightness,
      fontFamily: AppTypography.uiFamily,
      fontFamilyFallback: AppTypography.uiFallback,
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
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: colors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .6),
        thickness: 1,
        space: 1,
      ),
    );
  }

  Widget _projectControl(BuildContext context, bool compact) {
    final disabled = loading || w.busy || choosingProject;
    if (!w.hasProject) {
      return OutlinedButton.icon(
        onPressed: disabled ? null : _openProject,
        icon: const Icon(Icons.create_new_folder_outlined, size: 18),
        label: Text(w.tr('打开项目', 'Open project')),
      );
    }
    final directory = w.projectDirectory!;
    final segments = directory.replaceAll('\\', '/').split('/');
    final name =
        segments.where((part) => part.isNotEmpty).lastOrNull ?? directory;
    return PopupMenuButton<String>(
      enabled: !disabled,
      tooltip: directory,
      onSelected: (action) {
        if (action == 'open') {
          _openProject();
        } else {
          _changeProject(null);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'open',
          child: Text(w.tr('切换项目…', 'Switch project…')),
        ),
        PopupMenuItem(
          value: 'close',
          child: Text(w.tr('关闭项目 · 返回全局配置', 'Close project · global settings')),
        ),
      ],
      child: Container(
        constraints: BoxConstraints(maxWidth: compact ? 170 : 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open_outlined, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) => Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: LayoutBuilder(
      builder: (context, available) {
        final compact = available.maxWidth < 1000;
        return Row(
          children: [
            Tooltip(
              message: 'Codex Configurator',
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.tune,
                  size: 20,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (!compact) ...[
              Text(
                'Codex Configurator',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: VerticalDivider(),
              ),
            ],
            Expanded(
              child: Text(
                [
                  w.tr('配置编辑', 'Editor'),
                  w.tr('生效分析', 'Analysis'),
                  w.tr('备份恢复', 'Backups'),
                  w.tr('工具设置', 'Settings'),
                ][page],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (w.documents.any((document) => document.dirty))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Tooltip(
                  message: w.tr('有未保存的更改', 'Unsaved changes'),
                  child: Icon(
                    Icons.circle,
                    size: 8,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (!w.hasProject && available.maxWidth >= 760) ...[
              Text(
                w.tr('全局配置', 'Global settings'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
            ],
            _projectControl(context, compact),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => w.language(!w.chinese),
              tooltip: w.tr('Switch to English', '切换到中文'),
              icon: const Icon(Icons.translate, size: 20),
            ),
            PopupMenuButton<ThemeMode>(
              tooltip: w.tr('外观', 'Appearance'),
              icon: const Icon(Icons.brightness_6_outlined, size: 20),
              onSelected: (mode) => setState(() => themeMode = mode),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: ThemeMode.system,
                  child: Text(w.tr('跟随系统', 'System')),
                ),
                PopupMenuItem(
                  value: ThemeMode.light,
                  child: Text(w.tr('浅色', 'Light')),
                ),
                PopupMenuItem(
                  value: ThemeMode.dark,
                  child: Text(w.tr('深色', 'Dark')),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    title: 'Codex Configurator',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: themeMode,
    home: Builder(
      builder: (context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _SaveIntent(),
          SingleActivator(LogicalKeyboardKey.keyS, meta: true): _SaveIntent(),
          SingleActivator(LogicalKeyboardKey.keyO, control: true):
              _OpenIntent(),
          SingleActivator(LogicalKeyboardKey.keyO, meta: true): _OpenIntent(),
        },
        child: Actions(
          actions: {
            _SaveIntent: CallbackAction<_SaveIntent>(
              onInvoke: (_) {
                if (w.active != null && !w.busy) {
                  w.guard(() => w.save(w.active!));
                }
                return null;
              },
            ),
            _OpenIntent: CallbackAction<_OpenIntent>(
              onInvoke: (_) {
                if (!w.busy) _openDialog();
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    children: [
                      _topBar(context),
                      const Divider(),
                      if (w.busy)
                        const LinearProgressIndicator(minHeight: 2)
                      else
                        const SizedBox(height: 2),
                      Expanded(
                        child: loading
                            ? const Center(child: CircularProgressIndicator())
                            : w.schema.isEmpty
                            ? Center(
                                child: FilledButton.icon(
                                  onPressed: _initialize,
                                  icon: const Icon(Icons.refresh),
                                  label: Text(w.tr('重新加载', 'Try again')),
                                ),
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  NavigationRail(
                                    selectedIndex: page,
                                    onDestinationSelected: (value) =>
                                        setState(() => page = value),
                                    labelType: NavigationRailLabelType.none,
                                    minWidth: 64,
                                    groupAlignment: -1,
                                    destinations: [
                                      NavigationRailDestination(
                                        icon: Tooltip(
                                          message: w.tr('配置编辑', 'Editor'),
                                          child: const Icon(Icons.edit_note),
                                        ),
                                        label: Text(w.tr('配置编辑', 'Editor')),
                                      ),
                                      NavigationRailDestination(
                                        icon: Tooltip(
                                          message: w.tr('生效分析', 'Analysis'),
                                          child: const Icon(
                                            Icons.layers_outlined,
                                          ),
                                        ),
                                        label: Text(w.tr('生效分析', 'Analysis')),
                                      ),
                                      NavigationRailDestination(
                                        icon: Tooltip(
                                          message: w.tr('备份恢复', 'Backups'),
                                          child: const Icon(Icons.history),
                                        ),
                                        label: Text(w.tr('备份恢复', 'Backups')),
                                      ),
                                      NavigationRailDestination(
                                        icon: Tooltip(
                                          message: w.tr('工具设置', 'Settings'),
                                          child: const Icon(
                                            Icons.settings_outlined,
                                          ),
                                        ),
                                        label: Text(w.tr('工具设置', 'Settings')),
                                      ),
                                    ],
                                  ),
                                  const VerticalDivider(),
                                  Expanded(
                                    child: IndexedStack(
                                      index: page,
                                      children: [
                                        EditorPage(
                                          workspace: w,
                                          openDialog: _openDialog,
                                          closeDocument: _close,
                                        ),
                                        AnalysisPage(workspace: w),
                                        BackupsPage(
                                          workspace: w,
                                          confirmDiscard: _confirmClose,
                                        ),
                                        SettingsPage(workspace: w),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      const Divider(),
                      Container(
                        height: 29,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 7,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              w.hasProject
                                  ? w.tr('项目配置', 'Project settings')
                                  : w.tr('全局配置', 'Global settings'),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            const Spacer(),
                            Text(
                              w.tr(
                                'Ctrl / ⌘ + S 保存   ·   Ctrl / ⌘ + O 打开',
                                'Ctrl / ⌘ + S Save   ·   Ctrl / ⌘ + O Open',
                              ),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (w.error != null || w.notice != null)
                    _notification(context),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _notification(BuildContext context) {
    final error = w.error;
    final notice = w.notice;
    final revision = w.messageRevision;
    return Positioned(
      right: 16,
      bottom: 45,
      width: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 460.0),
      child: _NotificationToast(
        key: ValueKey(revision),
        message: error ?? notice!,
        isError: error != null,
        persistent: MediaQuery.accessibleNavigationOf(context),
        closeLabel: w.tr('关闭通知', 'Dismiss notification'),
        onDismiss: () {
          if (w.messageRevision == revision) w.clearMessage();
        },
      ),
    );
  }
}

class _NotificationToast extends StatefulWidget {
  const _NotificationToast({
    super.key,
    required this.message,
    required this.isError,
    required this.persistent,
    required this.closeLabel,
    required this.onDismiss,
  });

  final String message;
  final bool isError;
  final bool persistent;
  final String closeLabel;
  final VoidCallback onDismiss;

  @override
  State<_NotificationToast> createState() => _NotificationToastState();
}

class _NotificationToastState extends State<_NotificationToast> {
  Timer? _timer;
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _scheduleDismiss();
  }

  @override
  void didUpdateWidget(covariant _NotificationToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.persistent != widget.persistent) _scheduleDismiss();
  }

  void _scheduleDismiss() {
    _timer?.cancel();
    if (widget.isError || widget.persistent || _hovered || _focused) return;
    _timer = Timer(const Duration(seconds: 5), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = widget.isError
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * (20 / 14);
    final textPadding = ((40 - lineHeight) / 2).clamp(10.0, 20.0);
    final firstLineExtent = lineHeight + textPadding * 2;
    return Semantics(
      liveRegion: true,
      container: true,
      child: MouseRegion(
        onEnter: (_) {
          _hovered = true;
          _scheduleDismiss();
        },
        onExit: (_) {
          _hovered = false;
          _scheduleDismiss();
        },
        child: Focus(
          onFocusChange: (focused) {
            _focused = focused;
            _scheduleDismiss();
          },
          child: Material(
            elevation: 6,
            shadowColor: colors.shadow.withValues(alpha: .25),
            color: widget.isError
                ? colors.errorContainer
                : colors.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    height: firstLineExtent,
                    child: Icon(
                      widget.isError
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 20,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: (MediaQuery.sizeOf(context).height * .3)
                            .clamp(40.0, 240.0),
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(vertical: textPadding),
                        child: SelectableText(
                          widget.message,
                          style: TextStyle(
                            color: foreground,
                            fontSize: 14,
                            height: 20 / 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 40,
                    height: firstLineExtent,
                    child: Center(
                      child: IconButton(
                        onPressed: widget.onDismiss,
                        tooltip: widget.closeLabel,
                        color: foreground,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}
