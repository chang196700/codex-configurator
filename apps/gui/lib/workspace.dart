import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';

class PendingValue {
  const PendingValue(this.text, this.literal);
  final String text;
  final String literal;
}

class ConfigDocument {
  ConfigDocument({
    required this.path,
    required this.content,
    required this.saved,
    this.revision,
    this.exists = false,
  });
  final String path;
  String content;
  String saved;
  String? revision;
  bool exists;
  ValueNode? tree;
  List<dynamic> diagnostics = [];
  int generation = 0;
  final Map<String, PendingValue> pending = {};
  bool get dirty => content != saved || pending.isNotEmpty;
  String get name => path.replaceAll('\\', '/').split('/').last;
}

class Workspace extends ChangeNotifier {
  Workspace(this.backend);
  final CodexBackend backend;
  bool chinese = true;
  bool busy = false;
  String? _error;
  String? _notice;
  int _messageRevision = 0;
  int get messageRevision => _messageRevision;
  String? get error => _error;
  set error(String? value) {
    _error = value;
    _messageRevision++;
  }

  String? get notice => _notice;
  set notice(String? value) {
    _notice = value;
    _messageRevision++;
  }

  Json schema = {};
  Json paths = {};
  Json? featureCatalog;
  final Map<String, String> featureStages = {};
  final Map<String, bool> featureCatalogEnabled = {};
  final Map<String, bool> featureSnapshotEnabled = {};
  bool featureStagesLoading = false;
  String? featureStagesError;
  String featureExecutable = 'codex';
  int _featureRequest = 0;
  int get featureRequestRevision => _featureRequest;
  bool _disposed = false;
  final List<ConfigDocument> documents = [];
  final Set<String> _globalDocumentPaths = {};
  int activeIndex = -1;
  String? projectDirectory;
  int contextRevision = 0;
  bool get hasProject => projectDirectory != null;
  String codexHome = '';
  ConfigDocument? get active =>
      activeIndex >= 0 && activeIndex < documents.length
      ? documents[activeIndex]
      : null;
  String tr(String zh, String en) => chinese ? zh : en;
  Json get context => {
    'include_project': hasProject,
    if (hasProject) 'cwd': projectDirectory!,
    if (codexHome.trim().isNotEmpty) 'codex_home': codexHome.trim(),
  };
  Json get formSchema => asMap(schema['form_schema'] ?? schema['schema']);

  static bool isFeatureGroup(String pointer) {
    final parts = pointer.split('/');
    return (parts.length == 2 && parts[1] == 'features') ||
        (parts.length == 4 && parts[1] == 'profiles' && parts[3] == 'features');
  }

  String? featureStage(String pointer) {
    final separator = pointer.lastIndexOf('/');
    if (separator < 0 || !isFeatureGroup(pointer.substring(0, separator))) {
      return null;
    }
    return featureStages[pointerName(pointer)];
  }

  bool? featureEnabled(String pointer) {
    final separator = pointer.lastIndexOf('/');
    if (separator < 0 || !isFeatureGroup(pointer.substring(0, separator))) {
      return null;
    }
    final name = pointerName(pointer);
    return featureSnapshotEnabled[name] ?? featureCatalogEnabled[name];
  }

  void _applyFeatureData(Json data, {bool snapshot = false}) {
    featureCatalog = data;
    featureStages.clear();
    final enabled = snapshot ? featureSnapshotEnabled : featureCatalogEnabled;
    enabled.clear();
    if (data['available'] == true) {
      for (final raw in asList(data['features'])) {
        final feature = asMap(raw);
        final name = feature['name']?.toString() ?? '';
        final stage = feature['stage']?.toString() ?? '';
        if (name.isNotEmpty && stage.isNotEmpty) featureStages[name] = stage;
        if (name.isNotEmpty && feature['enabled'] is bool) {
          enabled[name] = feature['enabled'] as bool;
        }
      }
    }
  }

  Future<void> refreshFeatureStages() async {
    final projectScoped = hasProject;
    final request = ++_featureRequest;
    featureStagesLoading = true;
    featureStagesError = null;
    featureCatalog = null;
    featureStages.clear();
    featureCatalogEnabled.clear();
    if (projectScoped) featureSnapshotEnabled.clear();
    notifyListeners();
    try {
      final data = await backend.call(
        hasProject ? 'features' : 'feature_catalog',
        {...context, 'executable': featureExecutable},
      );
      if (_disposed || request != _featureRequest) return;
      _applyFeatureData(data, snapshot: projectScoped);
      if (data['available'] != true) {
        featureStagesError = asList(data['diagnostics'])
            .map((item) => asMap(item)['message']?.toString() ?? '')
            .where((message) => message.isNotEmpty)
            .join('\n');
      }
    } catch (exception) {
      if (_disposed || request != _featureRequest) return;
      featureStagesError = exception.toString();
    } finally {
      if (!_disposed && request == _featureRequest) {
        featureStagesLoading = false;
        notifyListeners();
      }
    }
  }

  // Apply the project-scoped snapshot immediately; refresh only changes the
  // stage source when the next context needs a separate catalog call.
  void useFeatureSnapshot(Json data, {required int expectedRevision}) {
    if (_disposed ||
        data['available'] != true ||
        expectedRevision != _featureRequest) {
      return;
    }
    featureExecutable =
        asMap(data['context'])['executable']?.toString() ?? 'codex';
    featureCatalogEnabled.clear();
    _applyFeatureData(data, snapshot: true);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _featureRequest++;
    super.dispose();
  }

  void changed() => notifyListeners();
  void clearMessage() {
    error = null;
    notice = null;
    notifyListeners();
  }

  void language(bool value) {
    chinese = value;
    notifyListeners();
  }

  Future<T?> guard<T>(Future<T> Function() task) async {
    if (busy) return null;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      return await task();
    } catch (exception) {
      error = exception.toString();
      if (exception is BackendException &&
          active != null &&
          exception.diagnostics.isNotEmpty) {
        active!.diagnostics = exception.diagnostics;
      }
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    schema = await backend.call('schema');
    await discover();
    final user = paths['user'];
    final path = user is String ? user : asMap(user)['path']?.toString();
    if (path != null && path.isNotEmpty) await open(path);
    unawaited(refreshFeatureStages());
  }

  Future<void> discover() async {
    paths = await backend.call('paths', context);
    if (codexHome.isEmpty) codexHome = paths['codex_home']?.toString() ?? '';
    notifyListeners();
  }

  String _pathKey(String path) {
    var key = path.replaceAll('\\', '/');
    while (key.length > 1 && key.endsWith('/')) {
      key = key.substring(0, key.length - 1);
    }
    return defaultTargetPlatform == TargetPlatform.windows
        ? key.toLowerCase()
        : key;
  }

  bool _within(String path, String directory) {
    final parent = _pathKey(directory);
    final child = _pathKey(path);
    return child == parent ||
        child.startsWith(parent.endsWith('/') ? parent : '$parent/');
  }

  String? _entryPath(dynamic entry) =>
      entry is String ? entry : asMap(entry)['path']?.toString();

  bool _isGlobalDocument(ConfigDocument document) =>
      _globalDocumentPaths.contains(_pathKey(document.path)) ||
      _isGlobalPath(document.path);

  bool _isGlobalPath(String path) {
    if (codexHome.isNotEmpty && _within(path, codexHome)) return true;
    final system = paths['system'];
    return [
      paths['user'],
      ...system is List ? system : [system],
      ...asList(paths['profiles']),
    ].any((entry) => _pathKey(_entryPath(entry) ?? '') == _pathKey(path));
  }

  List<ConfigDocument> get projectDocuments {
    if (!hasProject) return [];
    final discovered = asList(
      paths['projects'],
    ).map(_entryPath).whereType<String>().map(_pathKey).toSet();
    return documents
        .where(
          (document) =>
              !_isGlobalDocument(document) &&
              (_within(document.path, projectDirectory!) ||
                  discovered.contains(_pathKey(document.path))),
        )
        .toList();
  }

  bool isCurrentProject(String directory) =>
      hasProject && _pathKey(directory) == _pathKey(projectDirectory!);

  // The caller confirms unsaved project documents before changing scope.
  Future<void> setProject(String? directory) async {
    final nextPaths = await backend.call('paths', {
      'include_project': directory != null,
      'cwd': ?directory,
      if (codexHome.isNotEmpty) 'codex_home': codexHome,
    });
    final projectPaths = asList(nextPaths['projects']);
    final target = _entryPath(
      directory != null && projectPaths.isNotEmpty
          ? projectPaths.last
          : nextPaths['user'],
    );
    final snapshot = target == null
        ? null
        : await backend.call('open', {'path': target});
    final previousDocuments = projectDocuments;
    projectDirectory = directory == null
        ? null
        : nextPaths['cwd']?.toString() ?? directory;
    paths = nextPaths;
    contextRevision++;
    featureSnapshotEnabled.clear();
    unawaited(refreshFeatureStages());
    for (final document in previousDocuments) {
      close(document);
    }
    if (snapshot != null) await _openSnapshot(snapshot);
    notifyListeners();
  }

  Future<void> setCodexHome(String value) async {
    final nextPaths = await backend.call('paths', {
      'include_project': hasProject,
      if (hasProject) 'cwd': projectDirectory!,
      if (value.trim().isNotEmpty) 'codex_home': value.trim(),
    });
    final userPath = _entryPath(nextPaths['user']);
    final snapshot = userPath == null
        ? null
        : await backend.call('open', {'path': userPath});
    codexHome = nextPaths['codex_home']?.toString() ?? value.trim();
    paths = nextPaths;
    contextRevision++;
    featureSnapshotEnabled.clear();
    unawaited(refreshFeatureStages());
    if (snapshot != null) await _openSnapshot(snapshot);
    notifyListeners();
  }

  Future<void> open(String path) async {
    final index = documents.indexWhere(
      (document) => _pathKey(document.path) == _pathKey(path),
    );
    if (index >= 0) {
      activeIndex = index;
      notifyListeners();
      return;
    }
    final snapshot = await backend.call('open', {'path': path});
    await _openSnapshot(snapshot);
  }

  Future<void> _openSnapshot(Json snapshot) async {
    final resolved = snapshot['path'].toString();
    if (_isGlobalPath(resolved)) _globalDocumentPaths.add(_pathKey(resolved));
    final resolvedIndex = documents.indexWhere(
      (document) => _pathKey(document.path) == _pathKey(resolved),
    );
    if (resolvedIndex >= 0) {
      activeIndex = resolvedIndex;
      notifyListeners();
      return;
    }
    final content = snapshot['content']?.toString() ?? '';
    final document = ConfigDocument(
      path: resolved,
      content: content,
      saved: content,
      revision: snapshot['revision']?.toString(),
      exists: snapshot['exists'] == true,
    );
    document.diagnostics = asList(snapshot['diagnostics']);
    documents.add(document);
    activeIndex = documents.length - 1;
    await inspect(document);
    notifyListeners();
  }

  Future<void> inspect(ConfigDocument document) async {
    final generation = ++document.generation;
    try {
      final data = await backend.call('inspect', {
        'content': document.content,
        'pointer': '',
      });
      if (generation != document.generation) return;
      document.tree = ValueNode.fromJson(
        asMap(data['tree'] ?? data['node'] ?? data),
      );
      final validation = await backend.call('validate', {
        'content': document.content,
      });
      if (generation != document.generation) return;
      document.diagnostics = asList(validation['diagnostics']);
    } on BackendException catch (exception) {
      if (generation != document.generation) return;
      document.tree = null;
      document.diagnostics = exception.diagnostics.isNotEmpty
          ? exception.diagnostics
          : [
              {'severity': 'error', 'message': exception.message},
            ];
    }
    notifyListeners();
  }

  void select(int index) {
    activeIndex = index;
    notifyListeners();
  }

  void close(ConfigDocument document) {
    final index = documents.indexOf(document);
    if (index < 0) return;
    documents.removeAt(index);
    if (documents.isEmpty) {
      activeIndex = -1;
    } else if (activeIndex >= documents.length) {
      activeIndex = documents.length - 1;
    } else if (index < activeIndex) {
      activeIndex--;
    }
    notifyListeners();
  }

  void rawEdit(ConfigDocument document, String content) {
    document.content = content;
    document.generation++;
    notifyListeners();
  }

  void stage(
    ConfigDocument document,
    String pointer,
    String text,
    String literal,
  ) {
    final previous = document.tree?.at(pointer);
    final original = previous?.kind == 'string'
        ? stringLiteral(previous!.value.toString())
        : previous?.literal;
    if (literal == original) {
      document.pending.remove(pointer);
    } else {
      document.pending[pointer] = PendingValue(text, literal);
    }
    notifyListeners();
  }

  Future<void> flush(ConfigDocument document) async {
    for (final entry in document.pending.entries.toList()) {
      if (!document.pending.containsKey(entry.key)) continue;
      await edit(document, entry.key, literal: entry.value.literal);
    }
  }

  Future<void> edit(
    ConfigDocument document,
    String pointer, {
    String? literal,
  }) async {
    if (literal == null) {
      final parent = pointer.contains('/')
          ? pointer.substring(0, pointer.lastIndexOf('/'))
          : '';
      if (document.tree?.at(parent)?.isArray == true) {
        document.pending.removeWhere(
          (key, _) => key == pointer || key.startsWith('$pointer/'),
        );
        await flush(document);
      }
    }
    if (literal == null && document.tree?.at(pointer) == null) {
      document.pending.removeWhere(
        (key, _) => key == pointer || key.startsWith('$pointer/'),
      );
      notifyListeners();
      return;
    }
    final result = await backend.call('edit', {
      'content': document.content,
      'pointer': pointer,
      'action': literal == null ? 'unset' : 'set',
      'value_toml': ?literal,
    });
    document.pending.removeWhere(
      (key, _) => key == pointer || key.startsWith('$pointer/'),
    );
    document.content = result['content']?.toString() ?? document.content;
    document.diagnostics = asList(result['diagnostics']);
    await inspect(document);
    notifyListeners();
  }

  Future<bool> save(ConfigDocument document) async {
    await flush(document);
    final validation = await backend.call('validate', {
      'content': document.content,
    });
    document.diagnostics = asList(validation['diagnostics']);
    // The core decides which diagnostics block a save, including whether
    // unrelated validation errors already existed in the original file.
    final saving = document.content;
    final snapshot = await backend.call('save', {
      'path': document.path,
      'content': saving,
      'revision': document.revision,
    });
    final savedSnapshot = asMap(snapshot['snapshot'] ?? snapshot);
    if (document.content == saving && document.pending.isEmpty) {
      applySnapshot(document, savedSnapshot);
    } else {
      document.saved = savedSnapshot['content']?.toString() ?? saving;
      document.revision = savedSnapshot['revision']?.toString();
      document.exists = savedSnapshot['exists'] != false;
    }
    notice = tr(
      '已保存，原文件备份可在“备份恢复”中查看。',
      'Saved. Backups are available in Backups.',
    );
    await inspect(document);
    return !document.dirty;
  }

  void applySnapshot(ConfigDocument document, Json snapshot) {
    document.pending.clear();
    document.content = snapshot['content']?.toString() ?? document.content;
    document.saved = document.content;
    document.revision = snapshot['revision']?.toString();
    document.exists = snapshot['exists'] != false;
    document.diagnostics = asList(snapshot['diagnostics']);
    notifyListeners();
  }

  Future<void> reload(ConfigDocument document) async {
    applySnapshot(
      document,
      await backend.call('open', {'path': document.path}),
    );
    await inspect(document);
  }

  String label(Json field, String fallback) {
    final localized = asMap(field['label'] ?? field['title']);
    return (chinese
                ? field['label_zh'] ??
                      field['title_zh'] ??
                      localized['zh'] ??
                      localized['zh-CN']
                : field['label_en'] ?? field['title_en'] ?? localized['en'])
            ?.toString() ??
        (field['title'] is String
            ? field['title'] as String
            : fallback.replaceAll('_', ' '));
  }

  String description(Json field) {
    final localized = asMap(field['description']);
    return (chinese
                ? field['description_zh'] ??
                      localized['zh'] ??
                      localized['zh-CN']
                : field['description_en'] ?? localized['en'])
            ?.toString() ??
        (field['description'] is String ? field['description'] as String : '');
  }

  bool untranslated(Json field) =>
      chinese &&
      field['description_zh'] == null &&
      asMap(field['description'])['zh'] == null &&
      description(field).isNotEmpty;
}
