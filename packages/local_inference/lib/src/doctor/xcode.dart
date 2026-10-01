/// Reads an Xcode project (project.pbxproj, an old-style ASCII property list) and its .xcconfig files: the targets,
/// their build configurations and phases, and the value a build setting resolves to.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Parses an old-style (OpenStep) ASCII property list: `{ key = value; }`, `( a, b )`, quoted and bare strings,
/// `<hex data>` (kept as text), and `/* */` and `//` comments. Throws [FormatException].
Object? parseOpenStepPlist(String text) => _OpenStepParser(text).parse();

final class _OpenStepParser {
  _OpenStepParser(this.s);

  final String s;
  int i = 0;

  Object? parse() {
    final value = _value();
    _skip();
    if (i < s.length) _fail('unexpected text after the value');
    return value;
  }

  Never _fail(String what) => throw FormatException(what, s, i);

  void _skip() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
        i++;
      } else if (s.startsWith('/*', i)) {
        final end = s.indexOf('*/', i + 2);
        if (end < 0) _fail('unterminated comment');
        i = end + 2;
      } else if (s.startsWith('//', i)) {
        final end = s.indexOf('\n', i);
        i = end < 0 ? s.length : end + 1;
      } else {
        return;
      }
    }
  }

  Object? _value() {
    _skip();
    if (i >= s.length) _fail('a value was expected');
    switch (s[i]) {
      case '{':
        return _dict();
      case '(':
        return _array();
      case '"' || "'":
        return _quoted();
      case '<':
        final end = s.indexOf('>', i);
        if (end < 0) _fail('unterminated data');
        final data = s.substring(i, end + 1);
        i = end + 1;
        return data;
      default:
        return _bare();
    }
  }

  Map<String, Object?> _dict() {
    i++;
    final map = <String, Object?>{};
    while (true) {
      _skip();
      if (i >= s.length) _fail('unterminated dictionary');
      if (s[i] == '}') {
        i++;
        return map;
      }
      final key = _value();
      if (key is! String) _fail('a dictionary key must be a string');
      _skip();
      if (i >= s.length || s[i] != '=') _fail('"=" expected');
      i++;
      map[key] = _value();
      _skip();
      if (i >= s.length || s[i] != ';') _fail('";" expected');
      i++;
    }
  }

  List<Object?> _array() {
    i++;
    final list = <Object?>[];
    while (true) {
      _skip();
      if (i >= s.length) _fail('unterminated array');
      if (s[i] == ')') {
        i++;
        return list;
      }
      list.add(_value());
      _skip();
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i < s.length && s[i] != ')') {
        _fail('"," or ")" expected');
      }
    }
  }

  String _quoted() {
    final quote = s[i++];
    final out = StringBuffer();
    while (true) {
      if (i >= s.length) _fail('unterminated string');
      final c = s[i++];
      if (c == quote) return out.toString();
      if (c != r'\') {
        out.write(c);
        continue;
      }
      if (i >= s.length) _fail('unterminated escape');
      final e = s[i++];
      switch (e) {
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case 'U':
          final hex = s.substring(i, (i + 4).clamp(0, s.length));
          final code = int.tryParse(hex, radix: 16);
          if (code == null || hex.length != 4) _fail('bad \\U escape');
          out.writeCharCode(code);
          i += 4;
        default:
          out.write(e);
      }
    }
  }

  static final _bareChar = RegExp(r'[A-Za-z0-9_$/:.\-+]');

  String _bare() {
    final start = i;
    while (i < s.length && _bareChar.hasMatch(s[i])) {
      i++;
    }
    if (i == start) _fail('unexpected "${s[i]}"');
    return s.substring(start, i);
  }
}

/// An Xcode project: `<name>.xcodeproj/project.pbxproj` in [projectDir] (the folder that holds the .xcodeproj, which
/// is `$SRCROOT` and `$PROJECT_DIR`).
final class XcodeProject {
  XcodeProject._(this.projectDir, this.pbxprojPath, this._objects, this._root);

  /// Reads [pbxprojPath]; throws [FileSystemException] or [FormatException].
  factory XcodeProject.read(String pbxprojPath) {
    final parsed = parseOpenStepPlist(File(pbxprojPath).readAsStringSync());
    if (parsed is! Map<String, Object?>) throw const FormatException('project.pbxproj is not a dictionary');
    final objects = parsed['objects'];
    final rootId = parsed['rootObject'];
    if (objects is! Map<String, Object?> || rootId is! String || objects[rootId] is! Map<String, Object?>) {
      throw const FormatException('project.pbxproj has no objects or root object');
    }
    return XcodeProject._(
      p.dirname(p.dirname(pbxprojPath)),
      pbxprojPath,
      objects.map((k, v) => MapEntry(k, v is Map<String, Object?> ? v : const <String, Object?>{})),
      objects[rootId]! as Map<String, Object?>,
    );
  }

  /// The project in [dir] (an ios/ or macos/ folder): `Runner.xcodeproj`, else the only other .xcodeproj that is not
  /// `Pods.xcodeproj`; null when there is none.
  static String? find(String dir) {
    final runner = p.join(dir, 'Runner.xcodeproj', 'project.pbxproj');
    if (File(runner).existsSync()) return runner;
    final folder = Directory(dir);
    if (!folder.existsSync()) return null;
    final others = [
      for (final e in folder.listSync())
        if (e is Directory && e.path.endsWith('.xcodeproj') && p.basename(e.path) != 'Pods.xcodeproj')
          p.join(e.path, 'project.pbxproj'),
    ]..sort();
    return others.where((f) => File(f).existsSync()).firstOrNull;
  }

  final String projectDir;
  final String pbxprojPath;
  final Map<String, Map<String, Object?>> _objects;
  final Map<String, Object?> _root;
  Map<String, String>? _parents;

  Map<String, Object?>? object(Object? id) => id is String ? _objects[id] : null;

  List<XcodeTarget> get targets => [
    for (final id in _list(_root['targets']))
      if (object(id) case final target? when target['isa'] == 'PBXNativeTarget') XcodeTarget._(this, target),
  ];

  /// The application target: the one named Runner, else the first application.
  XcodeTarget? get appTarget {
    final apps = targets.where((t) => t.productType == 'com.apple.product-type.application').toList();
    return apps.where((t) => t.name == 'Runner').firstOrNull ?? apps.firstOrNull;
  }

  /// The project-level build configuration named [name].
  Map<String, Object?>? projectConfig(String name) => _configs(_root['buildConfigurationList'])[name];

  Map<String, Map<String, Object?>> _configs(Object? listId) {
    final configs = <String, Map<String, Object?>>{};
    for (final id in _list(object(listId)?['buildConfigurations'])) {
      final config = object(id);
      final name = config?['name'];
      if (config != null && name is String) configs[name] = config;
    }
    return configs;
  }

  /// The path of the file [refId] names (a PBXFileReference), from its groups; null when it lives outside the
  /// project's folders (the SDK, the build products).
  String? filePath(Object? refId) {
    final ref = object(refId);
    if (ref == null) return null;
    final path = ref['path'];
    if (path is! String) return null;
    switch (ref['sourceTree']) {
      case '<absolute>':
        return path;
      case 'SOURCE_ROOT':
        return p.normalize(p.join(projectDir, path));
      case '<group>':
        final parent = _parentOf(refId! as String);
        final base = parent == null ? projectDir : _groupPath(parent);
        return base == null ? null : p.normalize(p.join(base, path));
      default:
        return null;
    }
  }

  String? _groupPath(String groupId) {
    final group = object(groupId);
    if (group == null) return null;
    final path = group['path'];
    final parent = _parentOf(groupId);
    switch (group['sourceTree']) {
      case '<absolute>':
        return path is String ? path : null;
      case 'SOURCE_ROOT':
        return path is String ? p.join(projectDir, path) : projectDir;
      case '<group>' || null:
        final base = parent == null ? projectDir : _groupPath(parent);
        if (base == null) return null;
        return path is String ? p.join(base, path) : base;
      default:
        return null;
    }
  }

  String? _parentOf(String id) {
    final parents = _parents ??= {
      for (final MapEntry(key: groupId, value: group) in _objects.entries)
        if (group['isa'] == 'PBXGroup' || group['isa'] == 'PBXVariantGroup')
          for (final child in _list(group['children']))
            if (child is String) child: groupId,
    };
    return parents[id];
  }

  static List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];
}

/// A native target of an [XcodeProject].
final class XcodeTarget {
  XcodeTarget._(this.project, this._target);

  final XcodeProject project;
  final Map<String, Object?> _target;

  String get name => '${_target['name'] ?? ''}';

  String get productType => '${_target['productType'] ?? ''}';

  /// The target's build configurations (Debug, Release, Profile), in the project's order.
  List<XcodeConfig> get configs => [
    for (final MapEntry(:key, :value) in project._configs(_target['buildConfigurationList']).entries)
      XcodeConfig._(project, key, value, project.projectConfig(key)),
  ];

  /// The target's build phases, in build order.
  List<XcodePhase> get phases => [
    for (final id in XcodeProject._list(_target['buildPhases']))
      if (project.object(id) case final phase?) XcodePhase._(project, phase),
  ];
}

/// One build configuration of a target, with the project-level configuration of the same name.
final class XcodeConfig {
  XcodeConfig._(this.project, this.name, this._target, this._project);

  final XcodeProject project;
  final String name;
  final Map<String, Object?> _target;
  final Map<String, Object?>? _project;

  /// The literal value of build setting [key], as Xcode resolves it without evaluating `$(…)`: the target's own
  /// setting, then its .xcconfig file, then the project's setting, then the project's .xcconfig; null when none
  /// sets it (Xcode's default applies). Conditional settings (`KEY[sdk=…]`) are not read.
  String? setting(String key) {
    for (final level in [_target, _project]) {
      if (level == null) continue;
      final value = _settingIn(level['buildSettings'], key);
      if (value != null) return value;
      final xcconfig = project.filePath(level['baseConfigurationReference']);
      if (xcconfig != null) {
        final fromFile = readXcconfig(xcconfig)[key];
        if (fromFile != null) return fromFile;
      }
    }
    return null;
  }

  /// Where [setting] found [key], for the report: `target`, `target xcconfig`, `project`, `project xcconfig`.
  String? settingSource(String key) => switch (_origin(key)) {
    (final level, null) => level,
    (final level, _) => '$level xcconfig',
    null => null,
  };

  /// The .xcconfig file [setting] found [key] in (the base configuration file, which may take it from a file it
  /// includes), or null when a build setting of the target or the project sets it, or nothing does.
  String? settingFile(String key) => _origin(key)?.$2;

  (String, String?)? _origin(String key) {
    for (final (level, where) in [(_target, 'target'), (_project, 'project')]) {
      if (level == null) continue;
      if (_settingIn(level['buildSettings'], key) != null) return (where, null);
      final xcconfig = project.filePath(level['baseConfigurationReference']);
      if (xcconfig != null && readXcconfig(xcconfig)[key] != null) return (where, xcconfig);
    }
    return null;
  }

  static String? _settingIn(Object? settings, String key) {
    if (settings is! Map<String, Object?>) return null;
    final value = settings[key];
    return switch (value) {
      String() => value,
      List<Object?>() => value.join(' '),
      _ => null,
    };
  }
}

/// A build phase: its kind (`PBXShellScriptBuildPhase`, `PBXResourcesBuildPhase`, …), name and content.
final class XcodePhase {
  XcodePhase._(this.project, this._phase);

  final XcodeProject project;
  final Map<String, Object?> _phase;

  String get isa => '${_phase['isa'] ?? ''}';

  /// The phase's name; an unnamed Run Script phase is "Run Script".
  String get name => switch (_phase['name']) {
    final String name => name,
    _ => isa == 'PBXShellScriptBuildPhase' ? 'Run Script' : isa,
  };

  /// A Run Script phase's script; '' for other phases.
  String get shellScript => '${_phase['shellScript'] ?? ''}';

  /// Whether a Run Script phase runs on every build ("Based on dependency analysis" off).
  bool get alwaysOutOfDate => '${_phase['alwaysOutOfDate'] ?? ''}' == '1';

  /// The paths of the files the phase copies or compiles (the file references of its build files).
  List<String> get filePaths => [
    for (final id in XcodeProject._list(_phase['files'])) ?project.filePath(project.object(id)?['fileRef']),
  ];
}

/// The settings of the .xcconfig file at [path], with its `#include`s (a missing `#include?` file is skipped); later
/// lines win. Conditional settings (`KEY[sdk=…]`) are left out.
Map<String, String> readXcconfig(String path, {Set<String>? seen}) {
  final visited = seen ?? <String>{};
  final settings = <String, String>{};
  final file = File(path);
  if (!visited.add(p.normalize(path)) || !file.existsSync()) return settings;
  for (var line in file.readAsLinesSync()) {
    final include = RegExp(r'^\s*#include\??\s+"([^"]+)"').firstMatch(line);
    if (include != null) {
      settings.addAll(readXcconfig(p.join(p.dirname(path), include[1]!), seen: visited));
      continue;
    }
    final comment = line.indexOf('//');
    if (comment >= 0) line = line.substring(0, comment);
    final setting = RegExp(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*;?\s*$').firstMatch(line);
    if (setting != null) settings[setting[1]!] = setting[2]!;
  }
  return settings;
}

/// Compares dotted versions (`16.4`, `16.4.1`, `17`): negative, zero or positive; null when one is not a version.
int? compareDottedVersions(String a, String b) {
  List<int>? parts(String v) {
    final items = v.trim().split('.');
    final numbers = [for (final item in items) int.tryParse(item)];
    return numbers.contains(null) || numbers.isEmpty ? null : numbers.cast<int>();
  }

  final x = parts(a), y = parts(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < x.length || i < y.length; i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}
