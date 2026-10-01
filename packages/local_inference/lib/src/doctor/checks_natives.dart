/// The checks of the llama.cpp native libraries: the bundles the builds take (vendored through
/// `llamadart_native_path`, or downloaded by the hook into the pub cache) and the libraries the builds bundled.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'natives.dart';
import 'report.dart';

/// The bundles the host's builds need, with why, and whether a build fails without them.
Map<String, ({String why, bool required})> neededBundles(DoctorContext c) {
  final needs = <String, ({String why, bool required})>{
    c.machineBundle: (why: 'dart test, flutter test and dart run on this computer', required: true),
  };
  for (final platform in c.host.platforms) {
    switch (platform) {
      case 'ios':
        needs['ios-arm64'] = (why: 'iOS devices', required: true);
        needs['ios-arm64-sim'] = (why: 'the iOS simulator on Apple silicon', required: false);
      case 'macos':
        needs['macos-arm64'] = (why: 'macOS builds', required: true);
        needs['macos-x86_64'] = (why: 'macOS release builds, which are universal', required: true);
      case 'android':
        final filters = c.abiFilters;
        if (filters == null) {
          needs['android-arm64'] = (why: 'Android arm64-v8a builds', required: true);
          needs['android-x64'] = (why: 'Android x86_64 builds (no abiFilters)', required: true);
        } else {
          for (final abi in filters.abis) {
            final bundle = androidBundleForAbi(abi);
            if (bundle != null) needs[bundle] = (why: 'Android $abi builds (abiFilters)', required: true);
          }
          if (filters.unreadable.isNotEmpty) {
            for (final bundle in const ['android-arm64', 'android-x64']) {
              needs.putIfAbsent(
                bundle,
                () => (why: 'Android builds (abiFilters the doctor cannot read)', required: false),
              );
            }
          }
        }
    }
  }
  return needs;
}

/// The natives fetch script of the local_inference the host resolves (absolute: for a hosted or git dependency it is in
/// the pub cache), or its path in the package.
String fetchScript(DoctorContext c) {
  final root = c.host.packageRoot('local_inference');
  final script = root == null ? null : p.join(root, 'tool', 'native', 'fetch_llamadart_native.sh');
  return script != null && File(script).existsSync()
      ? script
      : 'local_inference\'s tool/native/fetch_llamadart_native.sh';
}

String _fetchFix(DoctorContext c, String folder, Iterable<String> bundles) => bundles.isEmpty
    ? 'fetch the bundles the host builds for with ${fetchScript(c)} --dest ${c.host.show(folder)} <bundle>... (it '
          'writes the guard file and checks each file against the manifest), then flutter clean'
    : 'fetch them with ${fetchScript(c)} --dest ${c.host.show(folder)} ${bundles.join(' ')} (it checks each file '
          'against the manifest), then flutter clean';

/// `natives`: with `llamadart_native_path`, the folder holds the bundles the host builds for (and the guard file); with
/// `--verify-natives`, every file of the vendored folder, or of the hook's download cache, matches the manifest.
CheckResult checkNatives(DoctorContext c) {
  final f = Findings('natives', 'the llama.cpp native bundles');
  final host = c.host;
  final manifest = c.manifest;
  final vendored = host.nativePath;
  if (host.llamadartDefines == null) {
    return f.skipped('no hooks block: see hooks-block');
  }
  if (vendored != null) {
    final shown = host.show(vendored);
    if (!Directory(vendored).existsSync()) {
      f.error('$shown (llamadart_native_path) does not exist', _fetchFix(c, vendored, neededBundles(c).keys));
      return f.result();
    }
    final folder = Directory(vendored).resolveSymbolicLinksSync();
    final needs = neededBundles(c);
    final present = [
      for (final bundle in manifest.bundles)
        if (Directory(p.join(folder, bundle)).existsSync()) bundle,
    ];
    for (final MapEntry(key: bundle, value: need) in needs.entries) {
      if (present.contains(bundle)) continue;
      final found = '$bundle is missing from $shown (needed by ${need.why}; such a build stops on the guard file)';
      if (need.required) {
        f.error(found, _fetchFix(c, vendored, [bundle]));
      } else {
        f.warning(found, _fetchFix(c, vendored, [bundle]));
      }
    }
    if (!File(p.join(folder, NativeManifest.guardPath)).existsSync()) {
      f.warning(
        '$shown has no ${NativeManifest.guardPath}: a build for a bundle that is not vendored takes the libraries of '
        'the others',
        _fetchFix(c, vendored, present),
      );
    }
    f.ok('vendored in $shown: ${present.isEmpty ? 'no bundle' : present.join(', ')}');
    if (c.verifyNatives) {
      _verifyFolder(c, f, folder, shown, archiveOptional: false, strays: true);
    } else {
      f.ok('not hashed: --verify-natives checks every file against the manifest');
    }
    return f.result();
  }
  final llamadart = host.llamadartRoot;
  f.ok(
    'no llamadart_native_path: the hook downloads each bundle from GitHub (leehack/llamadart-native '
    '${manifest.tag}) and checks no hash',
  );
  if (llamadart == null) {
    f.ok('llamadart is not resolved yet: nothing to look at');
    return f.result();
  }
  final cache = p.join(llamadart, '.dart_tool', 'llamadart', 'native_bundles', manifest.tag);
  if (!c.verifyNatives) {
    f.ok('not hashed: --verify-natives checks the downloads in $cache against the manifest');
  } else if (!Directory(cache).existsSync()) {
    f.ok('nothing downloaded into $cache yet: build once, then run --verify-natives again');
  } else {
    _verifyFolder(c, f, cache, cache, archiveOptional: true, strays: false);
  }
  return f.result();
}

void _verifyFolder(
  DoctorContext c,
  Findings f,
  String folder,
  String shown, {
  required bool archiveOptional,
  required bool strays,
}) {
  final manifest = c.manifest;
  final verified = <String>[];
  final entries = Directory(folder).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entries) {
    final name = p.basename(entity.path);
    if (name == '.DS_Store') continue;
    if (name == 'extracted') {
      if (!strays) continue;
      final guard = p.join(folder, NativeManifest.guardPath);
      final others = [
        for (final e in Directory(entity.path).listSync())
          if (p.basename(e.path) != '.DS_Store' && !p.equals(e.path, guard)) p.basename(e.path),
      ];
      const fix = 'delete the extracted folder and fetch again: the hook bundles every library it finds there';
      if (others.isNotEmpty) {
        f.error('$shown/extracted holds ${others.join(', ')} next to the guard file', fix);
      } else if (File(guard).existsSync() && sha256OfFile(guard) != manifest.sha256ByPath[NativeManifest.guardPath]) {
        f.error('$shown/${NativeManifest.guardPath} is not the empty guard file', fix);
      }
      continue;
    }
    if (entity is! Directory || !manifest.bundles.contains(name)) {
      if (strays) {
        f.error('$shown/$name is not in the manifest', 'remove it: only the manifest\'s bundles belong in $shown');
      }
      continue;
    }
    final check = verifyBundleFolder(manifest, name, entity.path, archiveOptional: archiveOptional);
    if (check.problems.isEmpty) {
      verified.add('$name (${check.matched} file${check.matched == 1 ? '' : 's'})');
    } else {
      // The hook downloads a bundle again only when it builds again; the fetch script rebuilds one that fails.
      final again = strays
          ? 'fetch it again with ${fetchScript(c)} --dest $shown $name (it replaces a bundle that does not match)'
          : 'delete ${entity.path}, then flutter clean (or delete '
                '${c.host.show(p.join(c.host.rootDir, '.dart_tool', 'hooks_runner'))}) and build again, so the hook '
                'downloads it again';
      f.error(
        'in $shown: ${check.problems.join('; ')}',
        '$again; a mismatch that comes back means the release changed: stop and compare with upstream SHA256SUMS '
            '(local_inference\'s tool/native/README.md)',
      );
    }
  }
  if (verified.isNotEmpty) f.ok('match the manifest (${manifest.tag}): ${verified.join(', ')}');
}

/// `native-output`: with `--verify-natives`, each library the host's builds bundled (the hook's output in
/// .dart_tool, not the app: a macOS build rewrites and signs its copy) is the manifest's file for that target.
CheckResult checkNativeOutput(DoctorContext c) {
  final f = Findings('native-output', 'the libraries the builds bundled');
  if (!c.verifyNatives) return f.skipped('run with --verify-natives to hash them');
  final runs = c.host.hookRuns.where((r) => r.assets.isNotEmpty).toList();
  if (runs.isEmpty) return f.skipped('no llamadart build recorded in .dart_tool/hooks_runner yet: build once');
  final matched = <String, int>{};
  for (final run in runs) {
    final bundle = run.bundle;
    for (final asset in run.assets) {
      if (!File(asset).existsSync()) continue;
      final name = p.basename(asset);
      final want = bundle == null ? null : c.manifest.extractedSha256(bundle, name);
      if (want == null) {
        f.error(
          '$name of build ${run.id} (${bundle ?? 'no llama.cpp bundle'}) is not a file of the manifest',
          'flutter clean, then build again with the hooks block in place',
        );
        continue;
      }
      final got = sha256OfFile(asset);
      if (got != want) {
        f.error(
          '${c.host.show(asset)}: SHA-256 $got, the manifest says $want for $bundle/extracted/$name',
          'flutter clean, check the bundle with --verify-natives, then build again',
        );
      } else {
        matched[bundle!] = (matched[bundle] ?? 0) + 1;
      }
    }
  }
  if (matched.isNotEmpty) {
    final libraries = matched.values.fold(0, (a, b) => a + b);
    final counted = libraries == 1 ? '1 library' : '$libraries libraries';
    final builds = runs.length == 1 ? '1 build' : '${runs.length} builds';
    f.ok(
      '$counted of $builds match${libraries == 1 ? 'es' : ''} the manifest: '
      '${matched.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
    );
  } else if (!f.hasProblems) {
    return f.skipped('the recorded builds\' libraries are gone: build again');
  }
  return f.result();
}
