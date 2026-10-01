// Tests of tool/ci/snippets.dart: reading the blocks and markers of a README, building the libraries, mapping the
// analyzer's lines back to the README, and one check of a README whose block does not compile.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../ci/snippets.dart' as snippets;

/// The repository root: `dart test tool/test` runs there.
String _repoRoot() {
  final root = Directory.current.path;
  if (!File(p.join(root, 'tool', 'ci', 'snippets.dart')).existsSync()) {
    throw StateError('run the tests from the repository root, not $root');
  }
  return root;
}

void main() {
  group('extractBlocks', () {
    test('reads each fenced block with its language and the README line of its first code line', () {
      const readme = '# Title\n\n```dart\nvoid main() {}\n```\n\ntext\n\n```sh\nls\n```\n\n```\nplain\n```\n';
      final extracted = snippets.extractBlocks('README.md', readme);
      expect(extracted.problems, isEmpty);
      expect(
        [for (final b in extracted.blocks) (b.language, b.line, b.code.join('\n'), b.continues)],
        [('dart', 4, 'void main() {}', false), ('sh', 10, 'ls', false), ('', 14, 'plain', false)],
      );
    });

    test('the continues marker applies to the dart block right after it (blank lines allowed)', () {
      const readme = '```dart\nfinal a = 1;\n```\n\n<!-- snippet: continues -->\n\n```dart\nfinal b = a;\n```\n';
      final extracted = snippets.extractBlocks('README.md', readme);
      expect(extracted.problems, isEmpty);
      expect([for (final b in extracted.blocks) b.continues], [false, true]);
    });

    test('an indented block loses its indentation', () {
      const readme = '- item:\n\n  ```dart\n  final a = [\n    1,\n  ];\n  ```\n';
      expect(snippets.extractBlocks('README.md', readme).blocks.single.code, ['final a = [', '  1,', '];']);
    });

    test('an unknown marker, a marker before prose or another language, and an unclosed block are problems', () {
      String problems(String readme) => [
        for (final problem in snippets.extractBlocks('R.md', readme).problems) '${problem.line} ${problem.message}',
      ].join('; ');

      expect(problems('<!-- snippet: skip -->\n```dart\nx\n```\n'), startsWith('1 unknown snippet marker'));
      expect(
        problems('<!-- snippet: continues -->\ntext\n'),
        '1 a snippet marker that is not followed by a dart block',
      );
      expect(
        problems('<!-- snippet: continues -->\n```yaml\na: 1\n```\n'),
        '1 a snippet marker that is not followed by a dart block',
      );
      expect(
        problems('text\n<!-- snippet: continues -->\n'),
        '2 a snippet marker that is not followed by a dart block',
      );
      expect(problems('```dart\nvoid main() {}\n'), '1 a code block that is never closed');
      final unknown = snippets.extractBlocks('R.md', '<!-- snippet: skip -->\n```dart\nx\n```\n');
      expect(unknown.blocks.single.continues, isFalse);
    });
  });

  group('libraries and assemble', () {
    test('a continuing block joins the library before it; a continuing first block is a problem', () {
      final blocks = [
        snippets.Block('dart', 2, ['a']),
        snippets.Block('sh', 6, ['ls']),
        snippets.Block('dart', 10, ['b'], continues: true),
        snippets.Block('dart', 14, ['c']),
      ];
      final problems = <snippets.Problem>[];
      expect(
        [
          for (final library in snippets.libraries('R.md', blocks, problems)) [for (final b in library) b.line],
        ],
        [
          [2, 10],
          [14],
        ],
      );
      expect(problems, isEmpty);
      snippets.libraries('R.md', [
        snippets.Block('dart', 3, ['a'], continues: true),
      ], problems);
      expect(problems.single.message, 'the first dart block cannot continue another one');
    });

    test('directives move to the top, once each, and every line keeps its README line', () {
      final (:source, :lines) = snippets.assemble([
        snippets.Block('dart', 10, ["import 'dart:io';", '', 'final a = stdout;']),
        snippets.Block('dart', 20, [
          "import 'dart:io';",
          "import 'dart:convert'",
          '    show jsonEncode;',
          'final b = jsonEncode(a.toString());',
        ]),
      ]);
      expect(source.split('\n'), [
        "import 'dart:io';",
        "import 'dart:convert'",
        '    show jsonEncode;',
        '',
        '',
        'final a = stdout;',
        '',
        'final b = jsonEncode(a.toString());',
        '',
      ]);
      expect(lines, [10, 21, 22, 0, 11, 12, 0, 23, 0]);
    });

    test('a library that imports package:test or package:flutter_test goes to test/', () {
      expect(snippets.isTestLibrary("import 'package:test/test.dart';\nvoid main() {}"), isTrue);
      expect(snippets.isTestLibrary("import 'package:flutter_test/flutter_test.dart';"), isTrue);
      expect(snippets.isTestLibrary("import 'package:local_inference/testing.dart';"), isFalse);
    });
  });

  group('the analyzer and the dependencies', () {
    test('parseDiagnostic reads the machine format, with escaped separators', () {
      final d = snippets.parseDiagnostic(
        r'ERROR|COMPILE_TIME_ERROR|UNDEFINED_IDENTIFIER|/tmp/x/lib/line_4.dart|3|7|5|Undefined name \|a\|.',
      )!;
      expect(
        (d.severity, d.code, d.file, d.line, d.column, d.message),
        ('error', 'undefined_identifier', '/tmp/x/lib/line_4.dart', 3, 7, 'Undefined name |a|.'),
      );
      expect(snippets.parseDiagnostic('Analyzing x...'), isNull);
    });

    test("each README's reader lists its own top-level packages", () {
      final root = _repoRoot();
      final core = snippets.dependenciesFor(root, 'packages/local_inference/README.md')!;
      expect(core.dependencies.keys, ['local_inference']);
      expect((core.devDependencies.keys.join(), core.flutter), ('test', false));
      final kit = snippets.dependenciesFor(root, 'packages/local_inference_flutter/README.md')!;
      expect(kit.dependencies.keys, ['flutter', 'local_inference_flutter']);
      expect((kit.devDependencies.keys.join(), kit.flutter), ('flutter_test', true));
      // local_inference_flutter takes local_inference from pub.dev; the check takes it from the checkout.
      expect(kit.overrides, {
        'local_inference': {'path': p.join(root, 'packages', 'local_inference')},
      });
      final top = snippets.dependenciesFor(root, 'README.md')!;
      expect(top.dependencies.keys, ['flutter', 'local_inference_flutter']);
      // An example: its own dependencies and overrides, the path ones made absolute. A temporary one, so the test
      // does not depend on the examples' pubspecs.
      final temp = Directory.systemTemp.createTempSync('snippets_test.');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'packages', 'x', 'example', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'name: x_example\nenvironment:\n  sdk: ^3.10.7\ndependencies:\n  x:\n    path: ..\n'
          'dev_dependencies:\n  lints: ^6.0.0\ndependency_overrides:\n  local_inference:\n'
          '    path: ../../local_inference\n',
        );
      final example = snippets.dependenciesFor(temp.path, 'packages/x/example/README.md')!;
      expect(example.dependencies, {
        'x': {'path': p.join(temp.path, 'packages', 'x')},
      });
      expect(example.overrides, {
        'local_inference': {'path': p.join(temp.path, 'packages', 'local_inference')},
      });
      expect((example.devDependencies.keys.join(' '), example.flutter), ('lints test', false));
      expect(snippets.dependenciesFor(root, 'docs/README.md'), isNull);
      expect(snippets.dependenciesFor(root, 'packages/x/doc/README.md'), isNull);
    });

    test('a block that does not compile is reported at its README line; the blocks around it compile', () async {
      final root = _repoRoot();
      const readme =
          '# local_inference\n'
          '\n'
          '```dart\n'
          "import 'package:local_inference/local_inference.dart';\n"
          '\n'
          "const spec = ToolSpec(name: 'a', description: 'b');\n"
          '```\n'
          '\n'
          '<!-- snippet: continues -->\n'
          '```dart\n'
          'final name = spec.nmae;\n'
          '```\n'
          '\n'
          '```dart\n'
          "import 'package:yaml/yaml.dart';\n"
          '\n'
          "final doc = loadYaml('a: 1');\n"
          '```\n';
      final problems = await snippets.checkReadmes(root, {
        'packages/local_inference/README.md': readme,
      }, dart: Platform.resolvedExecutable);
      final failing = [for (final problem in problems.where((e) => e.fails)) '${problem.line} ${problem.message}'];
      expect(failing, contains(startsWith("11 The getter 'nmae' isn't defined")));
      expect(failing, contains(allOf(startsWith('15 '), contains('depend_on_referenced_packages'))));
      expect(failing.where((e) => !e.startsWith('11 ') && !e.startsWith('15 ') && !e.startsWith('17 ')), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
