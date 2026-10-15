import 'dart:convert';

import 'src/rust/api.dart' as native;

typedef Json = Map<String, dynamic>;

Json asMap(dynamic value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};

List<dynamic> asList(dynamic value) => value is List ? value : <dynamic>[];

class BackendException implements Exception {
  BackendException(this.code, this.message, [this.diagnostics = const []]);
  final String code;
  final String message;
  final List<dynamic> diagnostics;
  @override
  String toString() => message;
}

class CodexBackend {
  Future<Json> call(String operation, [Json arguments = const {}]) async {
    final response = asMap(
      jsonDecode(
        await native.request(
          requestJson: jsonEncode({'op': operation, ...arguments}),
        ),
      ),
    );
    if (response['ok'] != true) {
      final error = asMap(response['error']);
      throw BackendException(
        error['code']?.toString() ?? 'unknown',
        error['message']?.toString() ?? 'The operation could not be completed.',
        asList(error['diagnostics']),
      );
    }
    final data = response['data'];
    return data is List ? {'items': data} : asMap(data);
  }
}

String pointerChild(String parent, String key) =>
    '$parent/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';

String pointerName(String pointer) =>
    pointer.split('/').last.replaceAll('~1', '/').replaceAll('~0', '~');

String stringLiteral(String value) => jsonEncode(value);

class ValueNode {
  ValueNode({
    required this.pointer,
    required this.kind,
    required this.literal,
    this.value,
    this.key = '',
    this.children = const [],
  });

  factory ValueNode.fromJson(Json json, {String parent = ''}) {
    final key = json['key']?.toString() ?? '';
    final pointer =
        json['pointer']?.toString() ??
        (key.isEmpty ? parent : pointerChild(parent, key));
    final children = asList(json['children'])
        .map((child) => ValueNode.fromJson(asMap(child), parent: pointer))
        .toList();
    return ValueNode(
      pointer: pointer,
      key: key,
      kind: json['kind']?.toString() ?? 'unknown',
      literal: json['value_toml']?.toString() ?? '',
      value: json['value'],
      children: children,
    );
  }

  final String pointer;
  final String key;
  final String kind;
  final String literal;
  final dynamic value;
  final List<ValueNode> children;
  bool get isObject =>
      kind == 'object' || kind == 'table' || kind == 'inline_table';
  bool get isArray => kind == 'array' || kind == 'array_of_tables';
  ValueNode? at(String path) {
    if (pointer == path) return this;
    for (final child in children) {
      if (path == child.pointer || path.startsWith('${child.pointer}/')) {
        final found = child.at(path);
        if (found != null) return found;
      }
    }
    return null;
  }
}

String schemaType(Json schema, [ValueNode? value]) {
  final type = schema['type'];
  if (type is String) return type;
  if (schema.containsKey('properties') ||
      schema.containsKey('additionalProperties')) {
    return 'object';
  }
  if (value?.isObject == true) return 'object';
  if (value?.isArray == true) return 'array';
  if (value != null) return value.kind == 'float' ? 'number' : value.kind;
  return 'any';
}

bool isFreeSchema(Json schema) => ![
  'type',
  'properties',
  'additionalProperties',
  'enum',
  'const',
  'oneOf',
  'anyOf',
].any(schema.containsKey);

bool schemaMatchesShape(Json schema, ValueNode value) {
  final enums = asList(schema['enum']);
  if (enums.isNotEmpty) {
    return enums.any(
      (entry) =>
          literalForJson(entry) == value.literal ||
          entry.toString() == value.value?.toString(),
    );
  }
  final type = schemaType(schema);
  if (type == 'object' && value.isObject) {
    final properties = asMap(schema['properties']);
    for (final key in asList(schema['required'])) {
      final child = value.children.where((node) => node.key == key).firstOrNull;
      if (child == null) return false;
      final field = asMap(properties[key]);
      if (field.containsKey('enum') && !schemaMatchesShape(field, child)) {
        return false;
      }
    }
    return true;
  }
  return type == schemaType({}, value) ||
      type == 'any' ||
      (type == 'number' && value.kind == 'integer');
}

String initialLiteral(dynamic rawSchema) {
  final schema = asMap(rawSchema);
  if (schema['default'] != null) return literalForJson(schema['default']);
  final values = asList(schema['enum']);
  if (values.isNotEmpty) return literalForJson(values.first);
  for (final union in ['oneOf', 'anyOf']) {
    final branches = asList(schema[union]);
    if (branches.isNotEmpty) return initialLiteral(branches.first);
  }
  switch (schemaType(schema)) {
    case 'boolean':
      return 'false';
    case 'integer':
      return (schema['minimum'] ?? 0).toInt().toString();
    case 'number':
      final lower = schema['exclusiveMinimum'];
      return lower is num
          ? (lower + 1).toString()
          : (schema['minimum'] ?? 0.0).toString();
    case 'array':
      return '[]';
    case 'datetime':
      return '1970-01-01T00:00:00Z';
    case 'object':
      final properties = asMap(schema['properties']);
      return '{${asList(schema['required']).where((key) => properties.containsKey(key)).map((key) => '${stringLiteral(key.toString())} = ${initialLiteral(properties[key])}').join(', ')}}';
    default:
      return '""';
  }
}

String literalForJson(dynamic value) {
  if (value is String) return stringLiteral(value);
  if (value is bool || value is num) return value.toString();
  if (value is List) return '[${value.map(literalForJson).join(', ')}]';
  if (value is Map) {
    return '{${value.entries.map((entry) => '${stringLiteral(entry.key.toString())} = ${literalForJson(entry.value)}').join(', ')}}';
  }
  return '""';
}
