import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'backend.dart';
import 'editor_page.dart';
import 'platform_theme.dart';
import 'platform_widgets.dart';
import 'utility_pages.dart';
import 'ui_preferences.dart';
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
  UiStyle uiStyle = UiStyle.system;
  int _styleRevision = 0;
  final AppPreferences preferences = AppPreferences();
  Workspace get w => widget.workspace;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    w.chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    w.addListener(_updated);
    _loadPreferences();
    _initialize();
  }

  Future<void> _loadPreferences() async {
    final revision = _styleRevision;
    final style = await preferences.loadUiStyle();
    if (mounted && revision == _styleRevision) {
      setState(() => uiStyle = style);
    }
  }

  Future<void> _setUiStyle(UiStyle style) async {
    if (style == uiStyle) return;
    final revision = ++_styleRevision;
    setState(() => uiStyle = style);
    try {
      await preferences.saveUiStyle(style);
    } catch (error) {
      if (mounted && revision == _styleRevision) {
        w.error = w.tr(
          '界面风格已切换，但未能保存偏好：$error',
          'The style was applied, but the preference could not be saved: $error',
        );
        w.changed();
      }
    }
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
      builder: (context) => PlatformDialog(
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
          PlatformButton.quiet(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(w.tr('取消', 'Cancel')),
          ),
          PlatformButton.quiet(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(w.tr('放弃更改', 'Discard')),
          ),
          PlatformButton.primary(
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
      builder: (context) => PlatformDialog(
        title: Text(w.tr('打开配置文件', 'Open configuration')),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlatformTextField(
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

  ThemeData _theme(Brightness brightness) => materialTheme(uiStyle, brightness);

  Widget _projectControl(BuildContext context, bool compact) {
    final disabled = loading || w.busy || choosingProject;
    if (!w.hasProject) {
      return PlatformButton.icon(
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
    height: (MediaQuery.textScalerOf(context).scale(22) + 28).clamp(52, 100),
    padding: const EdgeInsets.symmetric(horizontal: 16),
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
            PlatformIconButton(
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

  Widget _platformTheme(BuildContext context, Widget child) {
    final brightness = Theme.of(context).brightness;
    // Keep every ancestor of the navigator mounted across style changes so
    // pages, controllers, drafts and navigation retain their state.
    return PlatformStyleScope(
      style: resolveUiStyle(uiStyle),
      child: fluent.FluentTheme(
        data: fluentTheme(brightness),
        child: macos.MacosTheme(data: macosTheme(brightness), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    title: 'Codex Configurator',
    locale: Locale(w.chinese ? 'zh' : 'en'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: const [
      fluent.FluentLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: themeMode,
    builder: (context, child) =>
        _platformTheme(context, child ?? const SizedBox.shrink()),
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
                                child: PlatformButton.icon(
                                  kind: PlatformButtonKind.primary,
                                  onPressed: _initialize,
                                  icon: const Icon(Icons.refresh),
                                  label: Text(w.tr('重新加载', 'Try again')),
                                ),
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _AppNavigation(
                                    selectedIndex: page,
                                    onSelected: (value) =>
                                        setState(() => page = value),
                                    labels: [
                                      w.tr('配置编辑', 'Editor'),
                                      w.tr('生效分析', 'Analysis'),
                                      w.tr('备份恢复', 'Backups'),
                                      w.tr('工具设置', 'Settings'),
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
                                        SettingsPage(
                                          workspace: w,
                                          uiStyle: uiStyle,
                                          onUiStyleChanged: _setUiStyle,
                                        ),
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

class _AppNavigation extends StatelessWidget {
  const _AppNavigation({
    required this.selectedIndex,
    required this.onSelected,
    required this.labels,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<String> labels;
  static const _icons = [
    Icons.edit_note,
    Icons.layers_outlined,
    Icons.history,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final style = PlatformStyleScope.of(context);
    if (style == UiStyle.material || style == UiStyle.linuxYaru) {
      return NavigationRail(
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelected,
        labelType: NavigationRailLabelType.none,
        minWidth: 64,
        groupAlignment: -1,
        destinations: [
          for (var i = 0; i < labels.length; i++)
            NavigationRailDestination(
              icon: Tooltip(message: labels[i], child: Icon(_icons[i])),
              label: Text(labels[i]),
            ),
        ],
      );
    }
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 60,
      child: ColoredBox(
        color: colors.surfaceContainerLow,
        child: Column(
          children: [
            const SizedBox(height: 8),
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Semantics(
                  selected: selectedIndex == i,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 48,
                        height: 40,
                        child: PlatformIconButton(
                          tooltip: labels[i],
                          icon: Icon(_icons[i], size: 22),
                          isSelected: selectedIndex == i,
                          onPressed: () => onSelected(i),
                        ),
                      ),
                      if (style == UiStyle.windowsFluent && selectedIndex == i)
                        Positioned(
                          left: 0,
                          child: Container(
                            width: 3,
                            height: 18,
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
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
    final style = PlatformStyleScope.of(context);
    final nativeSurface =
        style == UiStyle.windowsFluent || style == UiStyle.macos;
    final foreground = widget.isError
        ? (nativeSurface ? colors.error : colors.onErrorContainer)
        : (nativeSurface ? colors.onSurface : colors.onSecondaryContainer);
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
            color: nativeSurface
                ? colors.surfaceContainerLow
                : widget.isError
                ? colors.errorContainer
                : colors.secondaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                style == UiStyle.windowsFluent ? 6 : 12,
              ),
              side: BorderSide(color: colors.outlineVariant),
            ),
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
                      child: PlatformIconButton(
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
