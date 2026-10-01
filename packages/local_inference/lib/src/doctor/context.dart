/// What every check of the doctor gets: the host, the run's options, and the files several checks read, each read once.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';
import 'natives.dart';
import 'report.dart';
import 'xcode.dart';

/// One check: a stable id and a function from the context to its result.
typedef DoctorCheck = CheckResult Function(DoctorContext context);

/// The `abiFilters` of a Gradle file: the ABIs named as quoted strings, and the statements that name none (a variable
/// or a function call the doctor cannot read).
typedef AbiFilters = ({List<String> abis, List<String> unreadable});

final class DoctorContext {
  DoctorContext({
    required this.host,
    required this.environment,
    required this.manifest,
    required this.machineBundle,
    required this.verifyNatives,
  });

  final HostProject host;

  /// The doctor's environment (the photo-library BYPASS variables).
  final Map<String, String> environment;
  final NativeManifest manifest;

  /// The bundle this computer builds for (`dart test`, `flutter test`, `dart run`).
  final String machineBundle;

  /// Whether to hash the native libraries.
  final bool verifyNatives;

  final _projects = <String, Object>{};

  /// The Xcode project of [platform]/ (`ios` or `macos`): an [XcodeProject], or a `String` saying why it cannot be
  /// read.
  Object xcodeProject(String platform) => _projects.putIfAbsent(platform, () {
    final path = XcodeProject.find(p.join(host.dir, platform));
    if (path == null) return 'no Xcode project in $platform/ ($platform/Runner.xcodeproj/project.pbxproj)';
    try {
      final project = XcodeProject.read(path);
      if (project.appTarget == null) return '${host.show(path)} has no application target';
      return project;
    } on FormatException catch (e) {
      return 'cannot read ${host.show(path)}: ${e.message}';
    } on FileSystemException catch (e) {
      return 'cannot read ${host.show(path)}: ${e.message}';
    }
  });

  String? _gradlePath;
  bool _gradleRead = false;

  /// android/app/build.gradle.kts (or build.gradle), or null.
  String? get gradlePath {
    if (!_gradleRead) {
      _gradleRead = true;
      for (final name in const ['build.gradle.kts', 'build.gradle']) {
        final path = p.join(host.dir, 'android', 'app', name);
        if (File(path).existsSync()) {
          _gradlePath = path;
          break;
        }
      }
    }
    return _gradlePath;
  }

  /// [gradlePath]'s text without its comments, or null.
  String? get gradleText {
    final path = gradlePath;
    if (path == null) return null;
    return stripComments(File(path).readAsStringSync());
  }

  /// The `abiFilters` of [gradlePath], or null when the file sets none. Each statement is read whole, also across
  /// lines: `abiFilters += listOf(…)`, `.add(…)`, `.addAll(…)`, Groovy's `abiFilters 'a', 'b'` and lists.
  AbiFilters? get abiFilters {
    final text = gradleText;
    if (text == null) return null;
    final abis = <String>{};
    final unreadable = <String>[];
    var found = false;
    for (final m in RegExp(r'\babiFilters\b').allMatches(text)) {
      final statement = statementAt(text, m.start);
      // Emptying the set (then adding to it) sets nothing by itself.
      if (RegExp(r'^abiFilters\s*\.\s*clear\s*\(\s*\)$').hasMatch(statement)) continue;
      found = true;
      final named = [for (final q in RegExp(r'''["']([A-Za-z0-9_-]+)["']''').allMatches(statement)) q[1]!];
      if (named.isEmpty) {
        unreadable.add(statement.replaceAll(RegExp(r'\s+'), ' '));
      } else {
        abis.addAll(named);
      }
    }
    return found ? (abis: abis.toList(), unreadable: unreadable) : null;
  }

  /// The result for a check of [platform] when it does not apply: a workspace root, a pure-Dart host, or no
  /// [platform]/ folder.
  CheckResult? skipPlatform(Findings findings, String platform) {
    if (!host.isFlutter) {
      final apps = host.workspaceApps;
      if (host.isWorkspaceRoot) {
        return findings.skipped(
          apps.isEmpty
              ? 'a workspace root with no Flutter app among its members'
              : 'a workspace root: its apps have their own settings (${apps.map(host.show).join(', ')}); see '
                    'hooks-block',
        );
      }
      return findings.skipped('a pure-Dart host (no Flutter SDK dependency)');
    }
    if (!host.platforms.contains(platform)) return findings.skipped('no $platform/ folder');
    return null;
  }
}

/// [text] without its comments (`//` to the end of the line, `/* */`), for Dart, Swift, Objective-C, Kotlin and Groovy
/// sources. Strings stay as they are (a `//` in a URL is not a comment), and a block comment keeps its line breaks, so
/// line numbers hold.
String stripComments(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '"' || c == "'") {
      final end = _stringEnd(text, i);
      out.write(text.substring(i, end));
      i = end;
    } else if (text.startsWith('//', i)) {
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end;
    } else if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      final stop = end < 0 ? text.length : end + 2;
      out.write('\n' * '\n'.allMatches(text.substring(i, stop)).length);
      i = stop;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The index after the string literal that starts at [start] (a quote); a line break ends one left open.
int _stringEnd(String text, int start) {
  final quote = text[start];
  var i = start + 1;
  while (i < text.length) {
    final c = text[i];
    if (c == r'\') {
      i += 2;
    } else if (c == quote) {
      return i + 1;
    } else if (c == '\n') {
      return i;
    } else {
      i++;
    }
  }
  return text.length;
}

/// The statement of [text] (without comments) that starts at [start]: it ends at a `;` or a line break outside
/// brackets, or at the `}` that closes the enclosing block; a line that ends in `,`, `=`, `+` or an opening bracket
/// goes on.
String statementAt(String text, int start) {
  var depth = 0;
  var i = start;
  while (i < text.length) {
    final c = text[i];
    if (c == '"' || c == "'") {
      i = _stringEnd(text, i);
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break;
      depth--;
    } else if (depth == 0 && c == ';') {
      break;
    } else if (depth == 0 && c == '\n' && !RegExp(r'[,=+(\[]$').hasMatch(text.substring(start, i).trimRight())) {
      break;
    }
    i++;
  }
  return text.substring(start, i).trim();
}
