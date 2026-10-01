// LocalInferencePaths.resolve per platform: Application Support on iOS and macOS,
// Android's no-backup folder from the plugin unless models already sit in Application Support, prefix states in the
// caches folder.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('local_inference_flutter/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  late String support;
  late String caches;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('paths_test');
    support = p.join(tmp.path, 'Application Support');
    caches = p.join(tmp.path, 'Caches');
    PathProviderPlatform.instance = FakePathProvider(support, caches);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methods, null);
    tmp.deleteSync(recursive: true);
  });

  void noBackupDirectory(String? path) =>
      messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'noBackupDirectory' ? path : null);

  test('iOS and macOS: Application Support, relative task folders, prefix states in the caches folder', () async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = platform;
      final paths = await LocalInferencePaths.resolve();
      expect(
        paths,
        LocalInferencePaths(
          modelsRoot: support,
          prefixStates: p.join(caches, 'prefix_states'),
          downloadLocation: const ModelStorageLocation.applicationSupport(),
        ),
        reason: '$platform',
      );
    }
  });

  test('Android: the no-backup folder, with the partial downloads under it', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    noBackupDirectory('/data/user/0/app/no_backup');
    expect(
      await LocalInferencePaths.resolve(),
      LocalInferencePaths(
        modelsRoot: '/data/user/0/app/no_backup',
        prefixStates: p.join(caches, 'prefix_states'),
        downloadLocation: const ModelStorageLocation.absolute('/data/user/0/app/no_backup'),
        backupExcludedByLocation: true,
        androidTempDirectory: '/data/user/0/app/no_backup/models/.partial',
      ),
    );
  });

  test('Android: Application Support when models are already there, or without the plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final legacy = LocalInferencePaths(
      modelsRoot: support,
      prefixStates: p.join(caches, 'prefix_states'),
      downloadLocation: const ModelStorageLocation.applicationSupport(),
      androidTempDirectory: p.join(support, 'models', '.partial'),
    );
    noBackupDirectory(null);
    expect(await LocalInferencePaths.resolve(), legacy, reason: 'no plugin answer');

    noBackupDirectory('/data/user/0/app/no_backup');
    File(p.join(support, 'models', 'index.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    expect(await LocalInferencePaths.resolve(), legacy, reason: 'a legacy index keeps the models where they are');
    expect(await LocalInferencePaths.resolve(models: ModelStoragePreference.applicationSupport), legacy);
  });

  test('Android: an earlier download under way, or only its settings, also keep Application Support', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    noBackupDirectory('/data/user/0/app/no_backup');
    final models = Directory(p.join(support, 'models'))..createSync(recursive: true);
    expect(
      (await LocalInferencePaths.resolve()).modelsRoot,
      '/data/user/0/app/no_backup',
      reason: 'an empty folder holds nothing to keep',
    );
    for (final leftover in ['.partial/test-2b.part', 'test-2b/', 'settings.json']) {
      models.deleteSync(recursive: true);
      final path = p.join(models.path, leftover);
      if (leftover.endsWith('/')) {
        Directory(path).createSync(recursive: true);
      } else {
        File(path).createSync(recursive: true);
      }
      final paths = await LocalInferencePaths.resolve();
      expect(
        (paths.modelsRoot, paths.downloadLocation, paths.androidTempDirectory),
        (support, const ModelStorageLocation.applicationSupport(), p.join(support, 'models', '.partial')),
        reason: leftover,
      );
    }
  });

  test('a custom folder: absolute task folders; it must be given', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final paths = await LocalInferencePaths.resolve(models: ModelStoragePreference.custom, customModelsRoot: '/models');
    expect((paths.modelsRoot, paths.downloadLocation), ('/models', const ModelStorageLocation.absolute('/models')));
    await expectLater(LocalInferencePaths.resolve(models: ModelStoragePreference.custom), throwsArgumentError);
  });
}
