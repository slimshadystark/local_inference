/// The host the doctor checks: its pubspec, the root that resolves it (itself, or its workspace), the lock, the
/// package config and the llamadart hook runs its builds left in `.dart_tool`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'natives.dart';

/// The packages of this repository. Taken from git or by path, they come from one ref or one checkout; from pub.dev,
/// each at its own version.
const ourPackages = ['local_inference', 'local_inference_flutter'];

/// A host app or package, as read from its folder. Nothing here runs a tool or touches the network.
final class HostProject {
  HostProject._({
    required this.dir,
    required this.pubspec,
    required this.rootDir,
    required this.rootPubspec,
    required this.lock,
    required this.packageRoots,
    required this.hookRuns,
  });

  /// Reads the host in [dir]; throws [FormatException] when its pubspec.yaml is missing, is not valid YAML or is not a
  /// map.
  factory HostProject.load(String dir) {
    final absolute = p.normalize(p.absolute(dir));
    final path = p.join(absolute, 'pubspec.yaml');
    if (!File(path).existsSync()) throw FormatException('no pubspec.yaml in $absolute');
    final Object? pubspec;
    try {
      pubspec = _plain(loadYaml(File(path).readAsStringSync(), sourceUrl: Uri.file(path)));
    } on YamlException catch (e) {
      throw FormatException('$path is not valid YAML: ${e.message} (line ${(e.span?.start.line ?? -1) + 1})');
    }
    if (pubspec is! Map) throw FormatException('$path is not a YAML map of pubspec fields');
    final root = pubspec['resolution'] == 'workspace' ? _workspaceRoot(absolute) : absolute;
    final rootPubspec = root == absolute ? pubspec : _readYaml(p.join(root, 'pubspec.yaml'));
    final lockYaml = _readYaml(p.join(root, 'pubspec.lock'));
    return HostProject._(
      dir: absolute,
      pubspec: pubspec,
      rootDir: root,
      rootPubspec: rootPubspec is Map ? rootPubspec : const {},
      lock: lockYaml is Map && lockYaml['packages'] is Map ? _lockPackages(lockYaml['packages'] as Map) : null,
      packageRoots: _packageRoots(root),
      hookRuns: HookRun.readAll(p.join(root, '.dart_tool', 'hooks_runner', 'llamadart')),
    );
  }

  /// The host's folder, absolute.
  final String dir;
  final Map<Object?, Object?> pubspec;

  /// The folder whose pubspec the hooks runner reads (the workspace root of a workspace member, else [dir]); its
  /// `.dart_tool` and `pubspec.lock` belong to the host.
  final String rootDir;
  final Map<Object?, Object?> rootPubspec;

  /// `pubspec.lock`'s packages by name; null before the first `pub get`.
  final Map<String, LockedPackage>? lock;

  /// Each resolved package's folder, from `.dart_tool/package_config.json`; null before the first `pub get`.
  final Map<String, String>? packageRoots;

  /// The llamadart hook runs recorded in `.dart_tool/hooks_runner/llamadart/`, one per build target.
  final List<HookRun> hookRuns;

  bool get isWorkspaceMember => rootDir != dir;

  /// Whether the host is a workspace root (its pubspec lists `workspace:` members).
  bool get isWorkspaceRoot => pubspec['workspace'] is List;

  /// The folders of the members of the host's workspace (it is the root or a member); empty outside a workspace.
  List<String> get workspaceMembers {
    final members = rootPubspec['workspace'];
    return [
      if (members is List)
        for (final member in members)
          if (member is String) p.normalize(p.join(rootDir, member)),
    ];
  }

  /// The members of the host's workspace that are Flutter apps: they depend on the Flutter SDK, are not plugins, and
  /// have an android/, ios/ or macos/ folder.
  List<String> get workspaceApps => [
    for (final member in workspaceMembers)
      if (_readYaml(p.join(member, 'pubspec.yaml')) case final Map<Object?, Object?> spec
          when _dependsOnFlutter(spec) &&
              !(spec['flutter'] is Map && (spec['flutter'] as Map).containsKey('plugin')) &&
              const ['android', 'ios', 'macos'].any((f) => Directory(p.join(member, f)).existsSync()))
        member,
  ];

  /// Whether the host depends on the Flutter SDK.
  bool get isFlutter => _dependsOnFlutter(pubspec);

  static bool _dependsOnFlutter(Map<Object?, Object?> pubspec) {
    final dependencies = pubspec['dependencies'];
    final flutter = dependencies is Map ? dependencies['flutter'] : null;
    return flutter is Map && flutter['sdk'] == 'flutter';
  }

  /// Where the `dependency_overrides` entry of [package] is written (the root's `pubspec_overrides.yaml`, which wins,
  /// or its pubspec.yaml), or null.
  String? overrideSource(String package) {
    final overridesFile = _readYaml(p.join(rootDir, 'pubspec_overrides.yaml'));
    if (overridesFile is Map && overridesFile['dependency_overrides'] is Map) {
      if ((overridesFile['dependency_overrides'] as Map).containsKey(package)) {
        return show(p.join(rootDir, 'pubspec_overrides.yaml'));
      }
    }
    final fromPubspec = rootPubspec['dependency_overrides'];
    return fromPubspec is Map && fromPubspec.containsKey(package) ? show(hooksPubspecPath) : null;
  }

  /// The platform folders a Flutter host has, of those the packages support.
  List<String> get platforms => [
    for (final platform in const ['android', 'ios', 'macos'])
      if (isFlutter && Directory(p.join(dir, platform)).existsSync()) platform,
  ];

  /// The pubspec that holds the hooks block the hooks runner reads.
  String get hooksPubspecPath => p.join(rootDir, 'pubspec.yaml');

  /// The `hooks: user_defines: llamadart:` map of the root pubspec, or null.
  Map<Object?, Object?>? get llamadartDefines => _llamadartDefines(rootPubspec);

  /// The same block in a workspace member's own pubspec, which the hooks runner ignores.
  Map<Object?, Object?>? get ignoredMemberDefines => isWorkspaceMember ? _llamadartDefines(pubspec) : null;

  /// `llamadart_native_path`, resolved against the pubspec that declares it (hooks 2.x); null when unset.
  String? get nativePath {
    final value = llamadartDefines?['llamadart_native_path'];
    if (value is! String || value.trim().isEmpty) return null;
    return p.normalize(p.isAbsolute(value) ? value : p.join(rootDir, value));
  }

  /// The folder of the llamadart package this host resolves, or null.
  String? get llamadartRoot => packageRoots?['llamadart'];

  /// The folder of [package] as this host resolves it, or null.
  String? packageRoot(String package) => packageRoots?[package];

  /// Whether [package] is in the lock (or, without a lock, in the package config).
  bool resolves(String package) => lock?.containsKey(package) ?? packageRoots?.containsKey(package) ?? false;

  /// Where pubspec.lock no longer matches the host's pubspec.yaml (a package listed there but not locked, or a git ref
  /// that differs): the lock predates a change, and `pub get` has not run since. Empty without a lock. Git urls are
  /// not compared: pub keeps the locked spelling of a url that points at the same repository.
  List<String> get lockMismatches {
    final lock = this.lock;
    if (lock == null) return const [];
    final problems = <String>[];
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final deps = pubspec[section];
      if (deps is! Map) continue;
      for (final MapEntry(key: name, value: spec) in deps.entries) {
        final locked = lock['$name'];
        if (locked == null) {
          problems.add('$name is not in it');
          continue;
        }
        final git = spec is Map ? spec['git'] : null;
        if (git == null || locked.source != 'git') continue;
        final ref = git is Map && git['ref'] != null ? '${git['ref']}' : 'HEAD';
        if (ref != locked.gitRef) problems.add('$name is locked at ref ${locked.gitRef}, the pubspec says ref $ref');
      }
    }
    return problems;
  }

  /// [path] for the report: relative to the host when it is at most two folders up (the host's repository), else
  /// absolute (the pub cache).
  String show(String path) {
    final relative = p.relative(path, from: dir);
    return p.split(relative).takeWhile((s) => s == '..').length > 2 ? path : relative;
  }

  /// The app's own Dart files: lib/ and bin/ of the host, of the other members of its workspace, and of the path
  /// packages it resolves (not the local_inference packages).
  List<File> get dartSources {
    final lock = this.lock;
    final roots = {
      dir,
      ...workspaceMembers,
      if (lock != null)
        for (final locked in lock.values)
          if (locked.path case final path? when !ourPackages.contains(locked.name))
            p.normalize(p.isAbsolute(path) ? path : p.join(rootDir, path)),
    };
    return [
      for (final root in roots)
        for (final folder in const ['lib', 'bin'])
          if (Directory(p.join(root, folder)).existsSync())
            for (final entity in Directory(p.join(root, folder)).listSync(recursive: true, followLinks: false))
              if (entity is File && entity.path.endsWith('.dart')) entity,
    ];
  }

  static Map<Object?, Object?>? _llamadartDefines(Map<Object?, Object?> pubspec) {
    final hooks = pubspec['hooks'];
    final defines = hooks is Map ? hooks['user_defines'] : null;
    final llamadart = defines is Map ? defines['llamadart'] : null;
    return llamadart is Map ? llamadart : null;
  }

  static Object? _readYaml(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return _plain(loadYaml(file.readAsStringSync()));
    } on YamlException {
      return null;
    }
  }

  /// YAML nodes as plain maps, lists and scalars.
  static Object? _plain(Object? node) => switch (node) {
    Map() => {for (final MapEntry(:key, :value) in node.entries) _plain(key): _plain(value)},
    List() => [for (final item in node) _plain(item)],
    _ => node,
  };

  /// The workspace root above [dir]: the nearest pubspec.yaml whose `workspace:` lists [dir]; else the root that
  /// `.dart_tool/pub/workspace_ref.json` names; else [dir].
  static String _workspaceRoot(String dir) {
    for (var parent = p.dirname(dir); parent != p.dirname(parent); parent = p.dirname(parent)) {
      final pubspec = _readYaml(p.join(parent, 'pubspec.yaml'));
      final members = pubspec is Map ? pubspec['workspace'] : null;
      if (members is List && members.any((m) => p.equals(p.join(parent, '$m'), dir))) return parent;
    }
    final ref = File(p.join(dir, '.dart_tool', 'pub', 'workspace_ref.json'));
    if (ref.existsSync()) {
      try {
        final root = (jsonDecode(ref.readAsStringSync()) as Map)['workspaceRoot'];
        if (root is String) return p.normalize(p.join(dir, '.dart_tool', 'pub', root));
      } on FormatException {
        // Not resolved as a member after all.
      }
    }
    return dir;
  }

  static Map<String, LockedPackage> _lockPackages(Map<Object?, Object?> packages) => {
    for (final MapEntry(:key, :value) in packages.entries)
      if (value is Map) '$key': LockedPackage('$key', value),
  };

  static Map<String, String>? _packageRoots(String root) {
    final file = File(p.join(root, '.dart_tool', 'package_config.json'));
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      final packages = json is Map ? json['packages'] : null;
      if (packages is! List) return null;
      final base = Uri.file(p.join(root, '.dart_tool', 'package_config.json'));
      return {
        for (final entry in packages)
          if (entry is Map && entry['name'] is String && entry['rootUri'] is String)
            entry['name'] as String: p.normalize(p.fromUri(base.resolve(entry['rootUri'] as String))),
      };
    } on FormatException {
      return null;
    }
  }
}

/// One package of `pubspec.lock`.
final class LockedPackage {
  LockedPackage(this.name, Map<Object?, Object?> entry)
    : source = '${entry['source'] ?? ''}',
      version = '${entry['version'] ?? ''}',
      description = entry['description'] is Map ? entry['description'] as Map<Object?, Object?> : const {};

  final String name;

  /// `hosted`, `git`, `path` or `sdk`.
  final String source;
  final String version;
  final Map<Object?, Object?> description;

  String? get hostedUrl => source == 'hosted' ? '${description['url']}' : null;
  String? get gitUrl => source == 'git' ? '${description['url']}' : null;
  String? get gitRef => source == 'git' ? '${description['ref']}' : null;
  String? get resolvedRef => source == 'git' ? '${description['resolved-ref']}' : null;
  String? get path => source == 'path' ? '${description['path']}' : null;
}

/// One run of llamadart's build hook for this host, as `.dart_tool/hooks_runner/llamadart/<id>/` recorded it: what
/// it was given (target, user defines), what it logged and which libraries it reported.
final class HookRun {
  HookRun._({
    required this.id,
    required this.bundle,
    required this.definesSource,
    required this.defines,
    required this.log,
    required this.assets,
  });

  /// The runs under [folder], sorted by id; runs with no readable input are left out.
  static List<HookRun> readAll(String folder) {
    final dir = Directory(folder);
    if (!dir.existsSync()) return const [];
    final runs = <HookRun>[];
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final input = _json(p.join(entity.path, 'input.json'));
      if (input is! Map) continue;
      final config = input['config'];
      final code = config is Map && config['extensions'] is Map ? (config['extensions'] as Map)['code_assets'] : null;
      final ios = code is Map ? code['ios'] : null;
      final defines = input['user_defines'] is Map ? (input['user_defines'] as Map)['workspace_pubspec'] : null;
      final output = _json(p.join(entity.path, 'output.json'));
      final log = File(p.join(entity.path, 'stdout.txt'));
      runs.add(
        HookRun._(
          id: p.basename(entity.path),
          bundle: code is Map
              ? bundleForTarget(
                  os: '${code['target_os']}',
                  architecture: '${code['target_architecture']}',
                  iosSdk: ios is Map ? '${ios['target_sdk']}' : null,
                )
              : null,
          definesSource: defines is Map ? '${defines['base_path']}' : null,
          defines: defines is Map && defines['defines'] is Map ? defines['defines'] as Map : const {},
          log: log.existsSync() ? log.readAsStringSync() : null,
          assets: [
            if (output is Map && output['assets'] is List)
              for (final asset in output['assets'] as List)
                if (asset is Map && asset['encoding'] is Map && (asset['encoding'] as Map)['file'] is String)
                  (asset['encoding'] as Map)['file'] as String,
          ],
        ),
      );
    }
    return runs..sort((a, b) => a.id.compareTo(b.id));
  }

  static Object? _json(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync());
    } on FormatException {
      return null;
    }
  }

  /// The folder name (a hash of the build's configuration).
  final String id;

  /// The llama.cpp bundle of the run's target, or null for a target without one.
  final String? bundle;

  /// The pubspec whose `hooks: user_defines:` the run was given, or null.
  final String? definesSource;

  /// llamadart's user defines as the run got them.
  final Map<Object?, Object?> defines;

  /// The hook's log (stdout.txt), or null.
  final String? log;

  /// The libraries the run reported (absolute paths under `hooks_runner/shared/llamadart/build/`).
  final List<String> assets;

  /// What the log's `Selected native runtimes: …` line says, or null.
  String? get selectedRuntimes =>
      RegExp(r'Selected native runtimes: ([^\n]*?)\.?\s*$', multiLine: true).firstMatch(log ?? '')?[1]?.trim();
}
