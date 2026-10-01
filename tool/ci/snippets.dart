// The README check: every ```dart block of the READMEs compiles, and every ```yaml block parses.
//
//   dart run tool/ci/snippets.dart [--packages-only] [--keep] [--root <dir>] [<README.md> ...]
//
// READMEs: README.md, packages/*/README.md and packages/*/example/README.md (--packages-only: packages/*/README.md),
// or the files given, relative to the root. Each README's dart blocks are analyzed in a temporary package that
// depends on what the reader of that README lists:
//   packages/<name>/README.md           <name>, by path (a host lists only the top-level package it uses)
//   packages/<name>/example/README.md   the example's own dependencies, dev dependencies and overrides (path
//                                       dependencies made absolute)
//   README.md                           local_inference_flutter
// plus test (pure Dart) or flutter_test (Flutter) as a dev dependency, the hooks block, and an override that takes
// local_inference from this checkout (local_inference_flutter depends on it as a hosted package). Pub resolves it
// offline (run pub get in the workspace first); then dart analyze runs with depend_on_referenced_packages as an
// error, so a block that imports a package its reader would not list fails. Errors and warnings fail, each reported
// at its README line; infos are printed only.
//
// Each dart block is a library of its own: in lib/, or in test/ when it imports package:test or
// package:flutter_test. A block that cannot compile on its own continues the one before it, and says so on the line
// right before its fence (an HTML comment, so a rendered page does not show it):
//
//   <!-- snippet: continues -->
//
// It is then compiled in one library with the blocks before it, back to the nearest block without the marker, with
// their import lines moved to the top. Keep these rare: a reader copies one block. Any other "<!-- snippet: ... -->"
// comment, or a marker that is not followed by a dart block, is an error.
//
// Toolchain: DART (default: the dart running this script) and FLUTTER (default: flutter on PATH; needed only for a
// README whose package depends on Flutter). Exit status: 0 when every block compiles, 1 when one does not, 2 on a
// usage or setup error. The temporary folder is removed unless --keep is given.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The marker of a block that continues the one before it.
const continuesMarker = '<!-- snippet: continues -->';

final _markerLine = RegExp(r'^\s*<!--\s*snippet:(.*?)-->\s*$');
final _fenceLine = RegExp(r'^(\s*)(`{3,})\s*([^`\s]*)[^`]*$');
final _testImport = RegExp(r'''^\s*import\s+['"]package:(test|flutter_test)/''', multiLine: true);

void main(List<String> args) async {
  exitCode = await run(args, out: stdout.writeln, err: stderr.writeln);
}

/// A fenced block of a README: its language, the README line of its first code line, and its code.
class Block {
  Block(this.language, this.line, this.code, {this.continues = false});

  final String language;
  final int line;
  final List<String> code;

  /// Whether the block carries [continuesMarker].
  final bool continues;
}

/// What a README's blocks look like, or why they cannot be read.
class Extracted {
  Extracted(this.blocks, this.problems);

  final List<Block> blocks;
  final List<Problem> problems;
}

/// A problem at a README line (1-based; 0 when it concerns the whole file).
class Problem {
  Problem(this.readme, this.line, this.severity, this.message, {this.column = 0});

  final String readme;
  final int line;
  final int column;

  /// `error`, `warning` or `info`; only errors and warnings fail.
  final String severity;
  final String message;

  bool get fails => severity != 'info';

  @override
  String toString() => '$readme${line > 0 ? ':$line${column > 0 ? ':$column' : ''}' : ''}: $severity: $message';
}

/// The fenced blocks of [text] (the README [readme]), with the markers applied.
Extracted extractBlocks(String readme, String text) {
  final lines = const LineSplitter().convert(text);
  final blocks = <Block>[];
  final problems = <Problem>[];
  int? pendingMarker;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_markerLine.hasMatch(line)) {
      if (pendingMarker != null) {
        problems.add(Problem(readme, pendingMarker, 'error', 'a snippet marker that is not followed by a dart block'));
        pendingMarker = null;
      }
      if (line.trim() == continuesMarker) {
        pendingMarker = i + 1;
      } else {
        problems.add(
          Problem(readme, i + 1, 'error', 'unknown snippet marker "${line.trim()}" (only "$continuesMarker")'),
        );
      }
      continue;
    }
    final fence = _fenceLine.firstMatch(line);
    if (fence == null) {
      if (line.trim().isNotEmpty && pendingMarker != null) {
        problems.add(Problem(readme, pendingMarker, 'error', 'a snippet marker that is not followed by a dart block'));
        pendingMarker = null;
      }
      continue;
    }
    final indent = fence[1]!;
    final ticks = fence[2]!;
    final language = fence[3]!.toLowerCase();
    final code = <String>[];
    var end = i + 1;
    while (end < lines.length && !RegExp('^\\s*$ticks`*\\s*\$').hasMatch(lines[end])) {
      final codeLine = lines[end];
      code.add(codeLine.startsWith(indent) ? codeLine.substring(indent.length) : codeLine.trimLeft());
      end++;
    }
    if (end >= lines.length) {
      problems.add(Problem(readme, i + 1, 'error', 'a code block that is never closed'));
      break;
    }
    if (pendingMarker != null && language != 'dart') {
      problems.add(Problem(readme, pendingMarker, 'error', 'a snippet marker that is not followed by a dart block'));
    }
    blocks.add(Block(language, i + 2, code, continues: pendingMarker != null && language == 'dart'));
    pendingMarker = null;
    i = end;
  }
  if (pendingMarker != null) {
    problems.add(Problem(readme, pendingMarker, 'error', 'a snippet marker that is not followed by a dart block'));
  }
  return Extracted(blocks, problems);
}

/// The dart blocks of [blocks] grouped into libraries: a block with [Block.continues] joins the library of the one
/// before it. A continuing first block is a problem.
List<List<Block>> libraries(String readme, List<Block> blocks, List<Problem> problems) {
  final result = <List<Block>>[];
  for (final block in blocks.where((b) => b.language == 'dart')) {
    if (block.continues && result.isEmpty) {
      problems.add(Problem(readme, block.line - 1, 'error', 'the first dart block cannot continue another one'));
      result.add([block]);
    } else if (block.continues) {
      result.last.add(block);
    } else {
      result.add([block]);
    }
  }
  return result;
}

/// The source of a library of [blocks], directives first (duplicates dropped), and the README line of each of its
/// lines (0 for none).
({String source, List<int> lines}) assemble(List<Block> blocks) {
  final directives = <String>[];
  final directiveLines = <int>[];
  final body = <String>[];
  final bodyLines = <int>[];
  final seen = <String>{};
  for (final block in blocks) {
    for (var i = 0; i < block.code.length; i++) {
      final line = block.code[i];
      if (RegExp(r'^(import|export|library)\b').hasMatch(line)) {
        // A directive runs to its semicolon, which may be on a later line.
        var end = i;
        while (!block.code[end].trimRight().endsWith(';') && end + 1 < block.code.length) {
          end++;
        }
        final text = block.code.sublist(i, end + 1);
        if (seen.add(text.map((l) => l.trim()).join(' '))) {
          for (var j = 0; j < text.length; j++) {
            directives.add(text[j]);
            directiveLines.add(block.line + i + j);
          }
        }
        i = end;
      } else {
        body.add(line);
        bodyLines.add(block.line + i);
      }
    }
    body.add('');
    bodyLines.add(0);
  }
  return (source: [...directives, '', ...body].join('\n'), lines: [...directiveLines, 0, ...bodyLines]);
}

/// Whether the library [source] belongs in test/ (it imports package:test or package:flutter_test).
bool isTestLibrary(String source) => _testImport.hasMatch(source);

/// The dependencies of the temporary package for the README at [readme] (relative to [root]): `dependencies`,
/// `dev_dependencies`, `dependency_overrides` and `environment` as pubspec maps, and whether it is a Flutter package.
/// Null when the README is not one this tool knows.
({
  Map<String, Object?> dependencies,
  Map<String, Object?> devDependencies,
  Map<String, Object?> overrides,
  Map<String, Object?> environment,
  bool flutter,
})?
dependenciesFor(String root, String readme) {
  final parts = p.split(p.normalize(readme));
  Map<String, Object?> path(String package) => {
    package: {'path': p.join(root, 'packages', package)},
  };
  if (parts.length == 1 && parts.single == 'README.md') {
    return (
      dependencies: {
        'flutter': {'sdk': 'flutter'},
        ...path('local_inference_flutter'),
      },
      devDependencies: {
        'flutter_test': {'sdk': 'flutter'},
      },
      overrides: path('local_inference'),
      environment: {'sdk': '^3.12.0', 'flutter': '>=3.44.0'},
      flutter: true,
    );
  }
  if (parts.length == 3 && parts.first == 'packages' && parts.last == 'README.md') {
    final pubspec = loadYaml(File(p.join(root, 'packages', parts[1], 'pubspec.yaml')).readAsStringSync()) as YamlMap;
    final flutter = (pubspec['dependencies'] as YamlMap?)?.containsKey('flutter') ?? false;
    return (
      dependencies: {
        if (flutter) 'flutter': {'sdk': 'flutter'},
        ...path(parts[1]),
      },
      devDependencies: flutter
          ? {
              'flutter_test': {'sdk': 'flutter'},
            }
          : {'test': 'any'},
      overrides: path('local_inference'),
      environment: _plain(pubspec['environment']) as Map<String, Object?>,
      flutter: flutter,
    );
  }
  if (parts.length == 4 && parts.first == 'packages' && parts[2] == 'example' && parts.last == 'README.md') {
    final dir = p.join(root, 'packages', parts[1], 'example');
    final pubspec = loadYaml(File(p.join(dir, 'pubspec.yaml')).readAsStringSync()) as YamlMap;
    Map<String, Object?> absolute(Object? deps) => {
      for (final MapEntry(:key, :value) in ((_plain(deps) as Map<String, Object?>?) ?? {}).entries)
        key: value is Map && value['path'] is String
            ? {...value, 'path': p.normalize(p.join(dir, value['path'] as String))}
            : value,
    };
    final dependencies = absolute(pubspec['dependencies']);
    final flutter = dependencies.containsKey('flutter');
    return (
      dependencies: dependencies,
      devDependencies: {
        ...absolute(pubspec['dev_dependencies']),
        if (flutter) 'flutter_test': {'sdk': 'flutter'} else 'test': 'any',
      },
      overrides: absolute(pubspec['dependency_overrides']),
      environment: _plain(pubspec['environment']) as Map<String, Object?>,
      flutter: flutter,
    );
  }
  return null;
}

/// [yaml] as plain Dart maps and lists.
Object? _plain(Object? yaml) => switch (yaml) {
  YamlMap map => {for (final MapEntry(:key, :value) in map.entries) '$key': _plain(value)},
  YamlList list => [for (final value in list) _plain(value)],
  _ => yaml,
};

/// One diagnostic of `dart analyze --format=machine`, or null for another line.
({String severity, String code, String file, int line, int column, String message})? parseDiagnostic(String line) {
  final fields = line.split('|');
  if (fields.length < 8 || !const {'ERROR', 'WARNING', 'INFO'}.contains(fields[0])) return null;
  final lineNumber = int.tryParse(fields[4]);
  final column = int.tryParse(fields[5]);
  if (lineNumber == null || column == null) return null;
  String unescape(String s) => s.replaceAll(r'\|', '|').replaceAll(r'\\', r'\');
  return (
    severity: fields[0].toLowerCase(),
    code: fields[2].toLowerCase(),
    file: unescape(fields[3]),
    line: lineNumber,
    column: column,
    message: unescape(fields.sublist(7).join('|')),
  );
}

/// The READMEs this tool checks by default under [root], relative to it.
List<String> defaultReadmes(String root, {bool packagesOnly = false}) {
  final found = <String>[];
  if (!packagesOnly && File(p.join(root, 'README.md')).existsSync()) found.add('README.md');
  final packages = Directory(p.join(root, 'packages'));
  if (!packages.existsSync()) return found;
  final names = [
    for (final entity in packages.listSync())
      if (entity is Directory) p.basename(entity.path),
  ]..sort();
  for (final name in names) {
    for (final readme in [
      p.join('packages', name, 'README.md'),
      if (!packagesOnly) p.join('packages', name, 'example', 'README.md'),
    ]) {
      if (File(p.join(root, readme)).existsSync()) found.add(readme);
    }
  }
  return found;
}

/// Checks [readmes] (relative path to text) against the packages under [root], in temporary packages under [work]
/// (removed after, unless [keep]). Returns the problems; throws [StateError] for a setup failure (pub get, a README
/// this tool does not know, a missing tool).
Future<List<Problem>> checkReadmes(
  String root,
  Map<String, String> readmes, {
  required String dart,
  String flutter = 'flutter',
  Directory? work,
  bool keep = false,
  void Function(String)? log,
}) async {
  final temp = work ?? Directory.systemTemp.createTempSync('li-snippets.');
  final problems = <Problem>[];
  try {
    var index = 0;
    for (final MapEntry(key: readme, value: text) in readmes.entries) {
      final extracted = extractBlocks(readme, text);
      problems.addAll(extracted.problems);
      final yamlBlocks = extracted.blocks.where((b) => b.language == 'yaml').toList();
      for (final block in yamlBlocks) {
        try {
          loadYaml(block.code.join('\n'));
        } on YamlException catch (e) {
          final span = e.span;
          problems.add(Problem(readme, block.line + (span?.start.line ?? 0), 'error', 'YAML: ${e.message}'));
        }
      }
      final units = libraries(readme, extracted.blocks, problems);
      final summary =
          '${units.fold(0, (n, u) => n + u.length)} dart block(s) in ${units.length} library(ies), '
          '${yamlBlocks.length} yaml block(s)';
      if (units.isEmpty) {
        log?.call('$readme: $summary');
        continue;
      }
      final deps = dependenciesFor(root, readme);
      if (deps == null) throw StateError('$readme: no dependencies known for this README (see tool/ci/snippets.dart)');
      final dir = Directory(p.join(temp.path, 'readme_${index++}'));
      final libraryLines = <String, ({String readme, List<int> lines})>{};
      for (final unit in units) {
        final (:source, :lines) = assemble(unit);
        final folder = isTestLibrary(source) ? 'test' : 'lib';
        final file = File(p.join(dir.path, folder, 'line_${unit.first.line}.dart'))..createSync(recursive: true);
        file.writeAsStringSync('$source\n');
        libraryLines[file.resolveSymbolicLinksSync()] = (readme: readme, lines: lines);
      }
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'name': 'readme_snippets_${index - 1}',
          'publish_to': 'none',
          'environment': deps.environment,
          'dependencies': deps.dependencies,
          'dev_dependencies': deps.devDependencies,
          if (deps.overrides.isNotEmpty) 'dependency_overrides': deps.overrides,
          'hooks': {
            'user_defines': {
              'llamadart': {
                'llamadart_native_runtimes': ['llama_cpp'],
              },
            },
          },
        }),
      );
      File(p.join(dir.path, 'analysis_options.yaml')).writeAsStringSync(
        'analyzer:\n  errors:\n    depend_on_referenced_packages: error\n'
        'linter:\n  rules:\n    - depend_on_referenced_packages\n',
      );
      final pub = await Process.run(deps.flutter ? flutter : dart, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: dir.path);
      if (pub.exitCode != 0) {
        throw StateError(
          '$readme: pub get --offline failed in ${dir.path} (run pub get in the workspace first):\n'
          '${pub.stdout}${pub.stderr}',
        );
      }
      final analyze = await Process.run(dart, ['analyze', '--format=machine', '.'], workingDirectory: dir.path);
      final before = problems.length;
      for (final line in const LineSplitter().convert('${analyze.stdout}\n${analyze.stderr}')) {
        final diagnostic = parseDiagnostic(line);
        if (diagnostic == null) continue;
        final reported = File(diagnostic.file);
        final origin = libraryLines[reported.existsSync() ? reported.resolveSymbolicLinksSync() : diagnostic.file];
        final readmeLine = origin != null && diagnostic.line - 1 < origin.lines.length
            ? origin.lines[diagnostic.line - 1]
            : 0;
        problems.add(
          Problem(
            origin?.readme ?? readme,
            readmeLine,
            diagnostic.severity,
            '${diagnostic.message} (${diagnostic.code})${origin == null ? ' in ${diagnostic.file}' : ''}',
            column: readmeLine > 0 ? diagnostic.column : 0,
          ),
        );
      }
      if (analyze.exitCode != 0 && !problems.skip(before).any((problem) => problem.fails)) {
        throw StateError('$readme: dart analyze failed:\n${analyze.stdout}${analyze.stderr}');
      }
      log?.call('$readme: $summary${problems.skip(before).any((e) => e.fails) ? '' : ': ok'}');
    }
  } finally {
    if (keep) {
      log?.call('kept ${temp.path}');
    } else {
      temp.deleteSync(recursive: true);
    }
  }
  return problems;
}

/// Runs the command line [args]; returns the exit status.
Future<int> run(List<String> args, {required void Function(String) out, required void Function(String) err}) async {
  var root = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var packagesOnly = false;
  var keep = false;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--packages-only') {
      packagesOnly = true;
    } else if (arg == '--keep') {
      keep = true;
    } else if (arg == '--root' && i + 1 < args.length) {
      root = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      out('usage: dart run tool/ci/snippets.dart [--packages-only] [--keep] [--root <dir>] [<README.md> ...]');
      return 0;
    } else if (arg.startsWith('-')) {
      err('snippets: unknown option $arg (see --help)');
      return 2;
    } else {
      files.add(arg);
    }
  }
  root = p.canonicalize(root);
  final readmes = files.isEmpty ? defaultReadmes(root, packagesOnly: packagesOnly) : files;
  final texts = <String, String>{};
  for (final readme in readmes) {
    final file = File(p.join(root, readme));
    if (!file.existsSync()) {
      err('snippets: no $readme under $root');
      return 2;
    }
    texts[p.normalize(readme)] = file.readAsStringSync();
  }
  final List<Problem> problems;
  try {
    problems = await checkReadmes(
      root,
      texts,
      dart: Platform.environment['DART'] ?? Platform.resolvedExecutable,
      flutter: Platform.environment['FLUTTER'] ?? 'flutter',
      keep: keep,
      log: (line) => out('snippets: $line'),
    );
  } on StateError catch (e) {
    err('snippets: ${e.message}');
    return 2;
  } on ProcessException catch (e) {
    err('snippets: cannot run ${e.executable}: ${e.message}');
    return 2;
  }
  final order = texts.keys.toList();
  problems.sort((a, b) {
    final byReadme = order.indexOf(a.readme).compareTo(order.indexOf(b.readme));
    return byReadme != 0 ? byReadme : a.line.compareTo(b.line);
  });
  for (final problem in problems) {
    (problem.fails ? err : out)(problem.toString());
  }
  final failed = problems.where((problem) => problem.fails).length;
  if (failed > 0) {
    err('snippets: $failed problem(s) in the README code blocks');
    return 1;
  }
  out('snippets: every dart block of ${texts.length} README(s) compiles');
  return 0;
}
