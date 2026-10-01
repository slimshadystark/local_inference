/// The doctor's results: one per check, each with what it found and, when something is wrong, how to fix it.
library;

import 'dart:convert';

/// The outcome of one check.
enum CheckStatus {
  /// The host has what the check looks for.
  ok,

  /// Something works but is not as recommended; fails the run with `--strict`.
  warning,

  /// Something the packages need is missing or wrong; fails the run.
  error,

  /// The check does not apply (no ios/ folder, a pure-Dart host) or cannot run yet; [CheckResult.found] says why.
  skipped,
}

/// What one check found.
final class CheckResult {
  const CheckResult({required this.id, required this.title, required this.status, required this.found, this.fix});

  /// A stable name, such as `ios-memory-entitlement`.
  final String id;

  /// What the check looks at, in a few words.
  final String title;

  final CheckStatus status;

  /// What the check found (the files and values it read), or why it was skipped. May span lines.
  final String found;

  /// How to fix what is wrong; null when the result is ok or skipped.
  final String? fix;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'status': status.name, 'found': found, 'fix': fix};

  @override
  String toString() => '${status.name} $id: $found';
}

/// The report of one run of the doctor.
final class DoctorReport {
  const DoctorReport({
    required this.version,
    required this.host,
    required this.kind,
    required this.platforms,
    required this.results,
    this.strict = false,
    this.verifyNatives = false,
  });

  /// local_inference's version, which is also the doctor's.
  final String version;

  /// The absolute path of the host checked.
  final String host;

  /// `flutter` (the host depends on the Flutter SDK), `workspace` (a workspace root that does not) or `dart`.
  final String kind;

  /// The platform folders of a Flutter host: `android`, `ios`, `macos`.
  final List<String> platforms;

  final List<CheckResult> results;

  /// Whether warnings fail the run.
  final bool strict;

  /// Whether the native libraries were hashed.
  final bool verifyNatives;

  int count(CheckStatus status) => results.where((r) => r.status == status).length;

  /// 1 when a check found an error, or a warning with [strict]; else 0.
  int get exitCode => count(CheckStatus.error) > 0 || strict && count(CheckStatus.warning) > 0 ? 1 : 0;

  /// The result of the check [id], or null.
  CheckResult? operator [](String id) => results.where((r) => r.id == id).firstOrNull;

  /// The version of the shape of [toJson]; a change that breaks a reader raises it.
  static const jsonFormat = 1;

  Map<String, Object?> toJson() => {
    'tool': 'local_inference doctor',
    'format': jsonFormat,
    'version': version,
    'host': host,
    'kind': kind,
    'platforms': platforms,
    'strict': strict,
    'verifyNatives': verifyNatives,
    'results': [for (final r in results) r.toJson()],
    'summary': {for (final s in CheckStatus.values) s.name: count(s)},
    'exitCode': exitCode,
  };

  /// The report as indented JSON.
  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// The report as text: a line per check, what it found under it when there is more to say, and the fix.
  String render() {
    final out = StringBuffer();
    final what = switch (kind) {
      'flutter' => 'a Flutter app${platforms.isEmpty ? '' : ' (${platforms.join(', ')})'}',
      'workspace' => 'a workspace root',
      _ => 'a pure-Dart package',
    };
    out.writeln('local_inference doctor $version: $host, $what');
    out.writeln();
    final idWidth = results.fold(0, (w, r) => r.id.length > w ? r.id.length : w);
    for (final r in results) {
      final lines = r.found.split('\n');
      out.writeln('${r.status.name.padRight(8)} ${r.id.padRight(idWidth)}  ${lines.first}');
      final indent = ' ' * (8 + 1 + idWidth + 2);
      for (final line in lines.skip(1)) {
        out.writeln('$indent$line');
      }
      final fix = r.fix;
      if (fix != null) {
        final fixLines = fix.split('\n');
        out.writeln('${indent}fix: ${fixLines.first}');
        for (final line in fixLines.skip(1)) {
          out.writeln('$indent     $line');
        }
      }
    }
    out.writeln();
    final summary = [
      '${count(CheckStatus.ok)} ok',
      '${count(CheckStatus.warning)} warning${count(CheckStatus.warning) == 1 ? '' : 's'}',
      '${count(CheckStatus.error)} error${count(CheckStatus.error) == 1 ? '' : 's'}',
      '${count(CheckStatus.skipped)} skipped',
    ];
    out.write('${results.length} checks: ${summary.join(', ')}.');
    if (strict) out.write(' --strict: warnings fail.');
    if (!verifyNatives) out.write(' --verify-natives also hashes the native libraries.');
    out.writeln(' Exit status $exitCode.');
    return out.toString();
  }
}

/// Collects what a check finds and turns it into one [CheckResult]: the worst status wins, the findings are kept in
/// order and each distinct fix once.
final class Findings {
  Findings(this.id, this.title);

  final String id;
  final String title;
  final _lines = <String>[];
  final _fixes = <String>[];
  var _status = CheckStatus.ok;

  bool get hasProblems => _status == CheckStatus.warning || _status == CheckStatus.error;

  void ok(String found) => _lines.add(found);

  void warning(String found, String fix) => _add(CheckStatus.warning, found, fix);

  void error(String found, String fix) => _add(CheckStatus.error, found, fix);

  void _add(CheckStatus status, String found, String fix) {
    _lines.add(found);
    if (!_fixes.contains(fix)) _fixes.add(fix);
    if (status == CheckStatus.error || _status == CheckStatus.ok) _status = status;
  }

  CheckResult result() => CheckResult(
    id: id,
    title: title,
    status: _status,
    found: _lines.join('\n'),
    fix: _fixes.isEmpty ? null : _fixes.join('\n'),
  );

  /// A result that says why the check did not run.
  CheckResult skipped(String reason) => CheckResult(id: id, title: title, status: CheckStatus.skipped, found: reason);
}
