/// The checks of what the host resolves: the hooks block, the pinned versions, how the local_inference packages are
/// listed and where they come from, companions and other runtimes, and LiteRT-LM.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'host.dart';
import 'report.dart';

/// The block every host needs, as the fix texts print it.
const hooksBlock = '''
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]''';

const _llamaCpp = 'llama_cpp';
const _liteRtLm = 'litert_lm';

/// What `llamadart_native_runtimes` selects, by llamadart 0.8.23's rules for a string or a list (tokens trimmed,
/// lowercased, `_` read as `-`, its aliases, `all`/`both`, `none`/`off`/`false`; nothing recognised selects every
/// runtime), with the tokens it does not know; null for a map (a per-platform value), which the doctor does not
/// resolve. An unset key (null) selects every runtime.
({Set<String> runtimes, List<String> unknown})? selectedRuntimes(Object? value) {
  const all = {_llamaCpp, _liteRtLm};
  if (value == null) return (runtimes: all, unknown: const []);
  final List<Object?> tokens;
  if (value == false) {
    tokens = const [false];
  } else if (value is String) {
    tokens = value.split(',');
  } else if (value is List) {
    tokens = value;
  } else {
    return null;
  }
  final result = <String>{};
  final unknown = <String>[];
  var cleared = false;
  for (final token in tokens) {
    if (token == false) {
      result.clear();
      cleared = true;
      continue;
    }
    if (token is! String) {
      if (token != null) unknown.add('$token');
      continue;
    }
    switch (_runtimeToken(token)) {
      case null:
        if (token.trim().isNotEmpty) unknown.add(token.trim());
      case 'all':
        result.addAll(all);
      case 'none':
        result.clear();
        cleared = true;
      case final runtime:
        result.add(runtime);
    }
  }
  return (runtimes: result.isEmpty && !cleared ? all : result, unknown: unknown);
}

String? _runtimeToken(String token) {
  final t = token.trim().toLowerCase().replaceAll('_', '-');
  if (t.isEmpty) return null;
  return switch (t) {
    'all' || 'both' => 'all',
    'none' || 'off' || 'false' => 'none',
    'llama-cpp' || 'llama' || 'llamacpp' || 'llama.cpp' || 'gguf' => _llamaCpp,
    'litert-lm' || 'litert' || 'lite-rt' || 'lite-rt-lm' || 'litertlm' || 'litert.lm' || '.litertlm' => _liteRtLm,
    _ => null,
  };
}

bool _llamaCppOnly(Object? value) {
  final selected = selectedRuntimes(value);
  return selected != null && selected.runtimes.length == 1 && selected.runtimes.single == _llamaCpp;
}

String _yamlText(Object? value) => switch (value) {
  List() => '[${value.join(', ')}]',
  null => '(unset)',
  _ => '$value',
};

/// The folder that holds the host's recorded builds, as the fix texts name it.
String _hooksRunner(HostProject host) => host.show(p.join(host.rootDir, '.dart_tool', 'hooks_runner'));

/// `hooks-block`: the pubspec the hooks runner reads (the host's, or its workspace root's) selects llama_cpp alone.
CheckResult checkHooksBlock(DoctorContext c) {
  final f = Findings('hooks-block', 'the llamadart hooks block');
  final host = c.host;
  final source = host.show(host.hooksPubspecPath);
  final block = host.llamadartDefines;
  final fix =
      'put this block in $source (a library cannot set it; in a workspace it goes in the root pubspec), '
      'then run flutter clean (or delete ${_hooksRunner(host)}):\n$hooksBlock';
  if (block == null) {
    f.error(
      '$source has no hooks: user_defines: llamadart: block, so llamadart bundles LiteRT-LM next to llama.cpp '
      '(+35-43 MB per platform)',
      fix,
    );
  } else if (!block.containsKey('llamadart_native_runtimes')) {
    f.error('$source: the llamadart block has no llamadart_native_runtimes, so every runtime is bundled', fix);
  } else {
    final value = block['llamadart_native_runtimes'];
    final selected = selectedRuntimes(value);
    if (selected == null) {
      f.warning(
        '$source: llamadart_native_runtimes is a per-platform map, which the doctor does not resolve (the litert-lm '
            'check reads what the builds selected)',
        'write it as llamadart_native_runtimes: [llama_cpp]',
      );
    } else if (!_llamaCppOnly(value)) {
      f.error('$source: llamadart_native_runtimes: ${_yamlText(value)} selects ${selected.runtimes.join(', ')}', fix);
    } else if (selected.unknown.isNotEmpty) {
      f.warning(
        '$source: llamadart_native_runtimes: ${_yamlText(value)} selects llama_cpp; llamadart ignores '
            '${selected.unknown.join(', ')}',
        'write it as llamadart_native_runtimes: [llama_cpp]',
      );
    } else {
      f.ok('$source: llamadart_native_runtimes: ${_yamlText(value)}');
    }
    final nativePath = block['llamadart_native_path'];
    f.ok(
      nativePath == null
          ? 'no llamadart_native_path: the hook downloads the llama.cpp bundles'
          : 'llamadart_native_path: $nativePath',
    );
  }
  if (host.ignoredMemberDefines != null) {
    f.warning(
      '${host.show(p.join(host.dir, 'pubspec.yaml'))} is a workspace member: its own hooks block is ignored; the '
          'hooks runner reads $source',
      'keep the block in $source only',
    );
  }
  final apps = host.isWorkspaceRoot && !host.isFlutter ? host.workspaceApps : const <String>[];
  if (apps.isNotEmpty) {
    f.warning(
      'this is a workspace root: the iOS, Android and macOS settings of its apps (${apps.map(host.show).join(', ')}) '
          'are checked only when the doctor runs on an app',
      'run the doctor on each app too: dart run local_inference_flutter:doctor --strict <app folder>',
    );
  }
  return f.result();
}

/// `pins`: the lock has llamadart 0.8.23 exactly and dinja in '>=1.0.0 <1.1.0' (1.0.0 is the tested one).
CheckResult checkPins(DoctorContext c) {
  final f = Findings('pins', 'llamadart and dinja versions');
  final host = c.host;
  final lock = host.lock;
  if (lock == null) return f.skipped(_noLock(host));
  // A normal constraint that disagrees with local_inference's fails pub get; only an override puts another version
  // in the lock.
  String overridden(String package) {
    final source = host.overrideSource(package);
    return source == null ? '' : ' (dependency_overrides in $source)';
  }

  String fix(String package, String pin, {bool setPin = false}) {
    final source = host.overrideSource(package);
    if (source != null) return 'remove $package from dependency_overrides in $source, then pub get';
    return setPin
        ? 'set $package: $pin in the host\'s dependencies, then pub get'
        : 'remove the host\'s own $package constraint (or set $package: $pin), then pub get';
  }

  final llamadart = lock['llamadart'];
  if (llamadart == null) {
    f.error('pubspec.lock has no llamadart: the host does not resolve local_inference', _dependFix);
  } else if (llamadart.version != '0.8.23') {
    f.error(
      'llamadart ${llamadart.version} in pubspec.lock${overridden('llamadart')}; local_inference needs 0.8.23 exactly '
      '(the prefix states, the chat rendering and the native bundles are tied to it)',
      fix('llamadart', '0.8.23'),
    );
  } else {
    f.ok('llamadart 0.8.23');
  }
  final dinja = lock['dinja'];
  final version = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(dinja?.version ?? '');
  if (dinja == null) {
    if (llamadart != null) f.error('pubspec.lock has no dinja', 'run pub get again');
  } else if (version == null || version[1] != '1' || version[2] != '0') {
    f.error(
      'dinja ${dinja.version} in pubspec.lock${overridden('dinja')}, outside >=1.0.0 <1.1.0 (the chat templates '
      'render through it)',
      fix('dinja', '1.0.0'),
    );
  } else if (dinja.version != '1.0.0') {
    f.warning(
      'dinja ${dinja.version}${overridden('dinja')}: in range, but the prompts were checked byte for byte with 1.0.0',
      fix('dinja', '1.0.0', setPin: true),
    );
  } else {
    f.ok('dinja 1.0.0');
  }
  return f.result();
}

const _dependFix = 'depend on local_inference_flutter (Flutter apps) or local_inference (Dart), then pub get';

String _noLock(HostProject host) =>
    'no pubspec.lock in ${host.show(host.rootDir) == '.' ? 'the host' : host.show(host.rootDir)} yet: run flutter pub '
    'get (or dart pub get) first';

/// `one-ref`: the local_inference packages the lock holds come from one place: one package server (pub.dev), one git
/// url and resolved commit, or one checkout. From git or a checkout they are one release, so their versions match too;
/// from a package server each has its own version, which pub's constraints keep compatible.
CheckResult checkOneRef(DoctorContext c) {
  final f = Findings('one-ref', 'one source for the local_inference packages');
  final host = c.host;
  final lock = host.lock;
  if (lock == null) return f.skipped(_noLock(host));
  final stale = host.lockMismatches;
  if (stale.isNotEmpty) {
    f.warning(
      'pubspec.lock does not match pubspec.yaml (${stale.join('; ')}): pins, one-ref and runtimes describe the old '
          'lock',
      'run flutter pub get (or dart pub get), then the doctor again',
    );
  }
  final ours = [for (final name in ourPackages) ?lock[name]];
  if (ours.isEmpty) {
    f.error('pubspec.lock has none of ${ourPackages.join(', ')}', _dependFix);
    return f.result();
  }
  final names = ours.map((o) => o.name).join(', ');
  final versions = {for (final o in ours) o.version};
  final sources = {for (final o in ours) o.source};
  if (versions.length > 1 && !(sources.length == 1 && sources.single == 'hosted')) {
    f.error(
      'the versions differ: ${ours.map((o) => '${o.name} ${o.version}').join(', ')}',
      'take every local_inference package from the same git ref or checkout (they are released together)',
    );
  }
  if (sources.length > 1) {
    f.error(
      'mixed sources: ${ours.map((o) => '${o.name} from ${o.source}').join(', ')}',
      'take every local_inference package from one place: pub.dev, one git url and ref, or one checkout by path (a '
          'dependency_overrides entry can move local_inference to the source of the package that brings it in)',
    );
    return f.result();
  }
  switch (sources.single) {
    case 'hosted':
      final urls = {for (final o in ours) o.hostedUrl};
      if (urls.length > 1) {
        f.error(
          'the package servers differ: ${ours.map((o) => '${o.name} from ${o.hostedUrl}').join(', ')}',
          'take every local_inference package from the same package server',
        );
      } else {
        f.ok('${ours.map((o) => '${o.name} ${o.version}').join(', ')}: hosted at ${urls.single}');
      }
    case 'git':
      final urls = {for (final o in ours) o.gitUrl};
      final commits = {for (final o in ours) o.resolvedRef};
      if (urls.length > 1 || commits.length > 1) {
        f.error(
          'the git sources differ: ${ours.map((o) => '${o.name} ${o.gitUrl} at ${o.resolvedRef}').join('; ')}',
          'give every local_inference package the same url string and the same ref, then pub get',
        );
      } else {
        f.ok(
          '$names ${versions.first}: git ${urls.single} at ${commits.single} '
          '(ref ${{for (final o in ours) o.gitRef}.join(', ')})',
        );
      }
    case 'path':
      final checkouts = {for (final o in ours) p.dirname(p.dirname(p.normalize(p.join(host.rootDir, o.path ?? ''))))};
      if (checkouts.length > 1) {
        f.error(
          'the path dependencies come from different checkouts: ${checkouts.map(host.show).join(', ')}',
          'point every local_inference package at the same checkout',
        );
      } else {
        f.ok('$names ${versions.first}: path dependencies of one checkout (${host.show(checkouts.single)})');
      }
    default:
      f.warning(
        '$names ${versions.first} come from ${sources.single}',
        'depend on them from pub.dev, or from one git url and ref',
      );
  }
  return f.result();
}

/// `sibling-ref`: a host that lists several of the packages from git lists them with one url and one ref, and never
/// local_inference next to a sibling at a ref other than a commit SHA: the sibling brings its own dependency on
/// local_inference, which then does not match the listed one, and pub cannot resolve the host. A lock written for
/// the listing that resolves every listed package to one commit shows that pub did resolve it.
CheckResult checkSiblingRef(DoctorContext c) {
  final f = Findings('sibling-ref', 'how the host lists the local_inference packages');
  final listed = <String, Object?>{};
  for (final section in const ['dependencies', 'dev_dependencies']) {
    final deps = c.host.pubspec[section];
    if (deps is! Map) continue;
    for (final name in ourPackages) {
      if (deps.containsKey(name)) listed[name] = deps[name];
    }
  }
  if (listed.isEmpty) return f.skipped('the host lists none of the local_inference packages itself');
  final git = <String, ({String url, String? ref})>{};
  final descriptions = <String>[];
  for (final MapEntry(key: name, value: spec) in listed.entries) {
    final source = spec is Map ? spec['git'] : null;
    if (source is String || source is Map) {
      final url = source is Map ? '${source['url']}' : '$source';
      final ref = source is Map ? source['ref'] ?? source['tag_pattern'] : null;
      git[name] = (url: url, ref: ref == null ? null : '$ref');
      descriptions.add('$name: git $url${ref == null ? '' : ' ref $ref'}');
    } else if (spec is Map && spec['path'] != null) {
      descriptions.add('$name: path ${spec['path']}');
    } else {
      descriptions.add('$name: ${spec ?? 'any'}');
    }
  }
  var fine = true;
  final lock = c.host.lock;
  final commits = {for (final name in git.keys) lock?[name]?.resolvedRef};
  final lockedAsListed = git.entries.every((e) => lock?[e.key]?.gitRef == (e.value.ref ?? 'HEAD'));
  final resolvedAsListed = lockedAsListed && commits.length == 1 && commits.single != null;
  if (git.length > 1 &&
      ({for (final g in git.values) g.url}.length > 1 || {for (final g in git.values) g.ref}.length > 1)) {
    fine = false;
    // Refs written differently (a tag and its commit) still resolve when the lock, written for this listing, holds
    // one commit for all of them.
    if ({for (final g in git.values) g.url}.length == 1 && resolvedAsListed) {
      f.warning(
        'the refs are written differently (${descriptions.join('; ')}), but pubspec.lock resolves them to one commit, '
            '${commits.single}',
        'give every local_inference package the same ref string, so a later change of one of them cannot split them',
      );
    } else {
      f.error(
        'different url strings or refs: ${descriptions.join('; ')}',
        'give every local_inference package the same url string and the same ref',
      );
    }
  }
  final siblings = git.keys.where((n) => n != 'local_inference').toList();
  if (git.containsKey('local_inference') && siblings.isNotEmpty && !resolvedAsListed) {
    final refs = {for (final g in git.values) g.ref};
    final sha = refs.every((r) => r != null && RegExp(r'^[0-9a-f]{40}$').hasMatch(r));
    if (!sha) {
      fine = false;
      f.error(
        'local_inference is listed next to ${siblings.join(', ')} at '
            '${refs.map((r) => r ?? 'the default branch').join(', ')}, which is not a commit SHA: the sibling\'s own '
            'dependency on local_inference does not resolve to the listed one, and the version solving fails',
        'list only the top-level packages (local_inference_flutter re-exports local_inference); to take '
            'local_inference from the same git ref, put it under dependency_overrides with the same url and ref',
      );
    }
  }
  if (fine) f.ok(descriptions.join('; '));
  return f.result();
}

/// Packages that make llamadart take its libraries elsewhere: its Flutter companions.
final _companion = RegExp(r'^llamadart_[a-z0-9_]+_flutter$');

/// Other on-device model runtimes, each with its own native libraries.
const _otherRuntimes = {'llama_cpp_dart', 'fllama', 'flutter_llama', 'llama_sdk', 'mediapipe_genai', 'aub_ai'};

/// `runtimes`: no llamadart companion package and no second on-device runtime is resolved.
CheckResult checkRuntimes(DoctorContext c) {
  final f = Findings('runtimes', 'companion packages and other on-device runtimes');
  final lock = c.host.lock;
  if (lock == null) return f.skipped(_noLock(c.host));
  for (final name in lock.keys.where(_companion.hasMatch)) {
    f.error(
      '$name is resolved: llamadart then takes its native libraries from the companion and ignores '
          'llamadart_native_runtimes (llamadart_llama_cpp_flutter 0.0.18 does not build on Flutter 3.47)',
      'remove $name (and whatever brings it in): local_inference uses the libraries of llamadart\'s own hook',
    );
  }
  for (final name in lock.keys.where((n) => _otherRuntimes.contains(n) || n.startsWith('flutter_gemma'))) {
    f.warning(
      '$name is another on-device model runtime: the app would carry two runtimes and their native libraries',
      'keep one runtime per app: remove $name unless the app needs it',
    );
  }
  if (!f.hasProblems) {
    f.ok(
      'no llamadart companion (llamadart_*_flutter) and no other on-device runtime (flutter_gemma, llama_cpp_dart, '
      '…)',
    );
  }
  return f.result();
}

/// `litert-lm`: no build of the host selected LiteRT-LM (the hook runs recorded in .dart_tool), and the llamadart
/// copy the host builds with has no LiteRT-LM download (a macOS build loads those libraries from there).
CheckResult checkLiteRt(DoctorContext c) {
  final f = Findings('litert-lm', 'LiteRT-LM left out of the builds');
  final host = c.host;
  final runs = host.hookRuns;
  final bad = <String>[];
  for (final run in runs) {
    final logged = run.selectedRuntimes;
    final fine = logged != null ? logged == _llamaCpp : _llamaCppOnly(run.defines['llamadart_native_runtimes']);
    if (!fine) {
      final selected = logged ?? 'defines ${_yamlText(run.defines['llamadart_native_runtimes'])}';
      bad.add('${run.id} (${run.bundle ?? 'no llama.cpp bundle'}): $selected');
    }
  }
  final hooksRunner = _hooksRunner(host);
  if (bad.isNotEmpty) {
    f.error(
      '${bad.length} of the ${runs.length} llamadart builds in $hooksRunner selected more than llama_cpp:\n'
          '${bad.join('\n')}',
      'put the hooks block in ${host.show(host.hooksPubspecPath)}, then flutter clean (or delete $hooksRunner) and '
          'build again',
    );
  } else if (runs.isEmpty) {
    f.ok('no llamadart build recorded in $hooksRunner yet');
  } else {
    f.ok(
      '${runs.length} llamadart build${runs.length == 1 ? '' : 's'} in $hooksRunner, each selecting llama_cpp alone',
    );
  }
  final llamadart = host.llamadartRoot;
  if (llamadart == null) {
    f.ok('llamadart is not resolved yet (no .dart_tool/package_config.json): its cache was not looked at');
  } else {
    final cache = p.join(llamadart, '.dart_tool', 'llamadart', 'litert_lm');
    if (Directory(cache).existsSync()) {
      f.warning(
        '$cache exists: a build with this copy of llamadart selected LiteRT-LM (a hooks block missing here or in '
            'another project on the same pub cache); a macOS build loads those libraries from there',
        'delete $cache; with the hooks block in place no build fetches it again',
      );
    } else {
      f.ok('no litert_lm folder in ${p.join(llamadart, '.dart_tool', 'llamadart')}');
    }
  }
  return f.result();
}
