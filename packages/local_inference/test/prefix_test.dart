// Prefix states: ModelIdentity and PrefixKey inputs, FilePrefixStateStore (LRU, temporary files, atomic put),
// PrefixCache (build, restore, the contextEpoch rule, a state that fails to load) and the memory store.
import 'dart:async';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

EngineInfo _info({
  String backend = 'Metal',
  String template = 'T',
  RuntimeInfo runtime = LlamadartEngine.defaultRuntime,
  LoadOptions options = const LoadOptions(contextTokens: 4096, gpuLayers: 999, microBatchSize: 0, batchSize: 2048),
}) => EngineInfo(
  modelPath: '/m/model.gguf',
  modelBytes: 1,
  backend: backend,
  gpuLayers: 999,
  contextTokens: options.contextTokens,
  loadMs: 1,
  options: options,
  metadata: {'tokenizer.chat_template': template},
  runtime: runtime,
  addsBos: false,
);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('prefix_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('ModelIdentity', () {
    test('ofFile: the file name, size and modification time; the id joins them', () async {
      final file = File('${tmp.path}/qwen.gguf')..writeAsStringSync('12345');
      file.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(1700000000000));
      final identity = await ModelIdentity.ofFile(file.path);
      expect((identity.fileName, identity.sizeBytes, identity.modifiedMs), ('qwen.gguf', 5, 1700000000000));
      expect(identity.id, 'qwen.gguf|5|1700000000000');
      expect(identity, const ModelIdentity.fixed('qwen.gguf', sizeBytes: 5, modifiedMs: 1700000000000));
      expect(await ModelIdentity.ofFile(file.path), identity, reason: 'the same file, the same identity');
      expect(const ModelIdentity.fixed('m').id, 'm|0|0');
    });

    test('ofFile: a missing file or a folder is an error', () async {
      await expectLater(ModelIdentity.ofFile('${tmp.path}/nope.gguf'), throwsA(isA<FileSystemException>()));
      await expectLater(ModelIdentity.ofFile(tmp.path), throwsA(isA<FileSystemException>()));
    });
  });

  group('PrefixKey', () {
    const model = ModelIdentity.fixed('m.gguf', sizeBytes: 10, modifiedMs: 20);

    test('16 hex digits, the same for the same inputs', () {
      final key = PrefixKey.of(_info(), model, 'prefix');
      expect(key.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(PrefixKey.of(_info(), model, 'prefix'), key);
    });

    test('any input changes it: model, template, runtime, load settings, backend, prefix', () {
      final base = PrefixKey.of(_info(), model, 'prefix');
      const options = LoadOptions(contextTokens: 4096, gpuLayers: 999, microBatchSize: 0, batchSize: 2048);
      final variants = {
        'file name': PrefixKey.of(
          _info(),
          const ModelIdentity.fixed('n.gguf', sizeBytes: 10, modifiedMs: 20),
          'prefix',
        ),
        'size': PrefixKey.of(_info(), const ModelIdentity.fixed('m.gguf', sizeBytes: 11, modifiedMs: 20), 'prefix'),
        'mtime': PrefixKey.of(_info(), const ModelIdentity.fixed('m.gguf', sizeBytes: 10, modifiedMs: 21), 'prefix'),
        'template': PrefixKey.of(_info(template: 'U'), model, 'prefix'),
        'runtime': PrefixKey.of(
          _info(
            runtime: const RuntimeInfo(binding: 'llamadart', bindingVersion: '0.8.24', native: 'llama.cpp v0.4.0'),
          ),
          model,
          'prefix',
        ),
        'context': PrefixKey.of(_info(options: options.copyWith(contextTokens: 8192)), model, 'prefix'),
        'micro-batch': PrefixKey.of(_info(options: options.copyWith(microBatchSize: 128)), model, 'prefix'),
        'batch': PrefixKey.of(_info(options: options.copyWith(batchSize: 512)), model, 'prefix'),
        'kv K': PrefixKey.of(_info(options: options.copyWith(kvCacheK: KvCacheQuant.q8_0)), model, 'prefix'),
        'kv V': PrefixKey.of(_info(options: options.copyWith(kvCacheV: KvCacheQuant.q8_0)), model, 'prefix'),
        'flash attention': PrefixKey.of(_info(options: options.copyWith(flashAttention: false)), model, 'prefix'),
        'gpu layers': PrefixKey.of(_info(options: options.copyWith(gpuLayers: 0)), model, 'prefix'),
        'backend': PrefixKey.of(_info(backend: 'CPU'), model, 'prefix'),
        'prefix': PrefixKey.of(_info(), model, 'prefix '),
      };
      for (final MapEntry(key: input, value: key) in variants.entries) {
        expect(key, isNot(base), reason: input);
      }
      expect({for (final key in variants.values) key.id}.length, variants.length);
      expect(
        PrefixKey.of(_info(options: options.copyWith(threads: 4)), model, 'prefix'),
        base,
        reason: 'threads do not change a state',
      );
    });

    test('the same file loaded again gives the same key; another load setting another key', () async {
      final file = File('${tmp.path}/model.gguf')..writeAsStringSync('x');
      final identity = await ModelIdentity.ofFile(file.path);
      final first = await ScriptedEngine().load(file.path);
      final again = await ScriptedEngine().load(file.path);
      expect(PrefixKey.of(again, identity, 'p'), PrefixKey.of(first, identity, 'p'));
      final other = await ScriptedEngine().load(file.path, const LoadOptions(microBatchSize: 128));
      expect(PrefixKey.of(other, identity, 'p'), isNot(PrefixKey.of(first, identity, 'p')));
    });
  });

  group('FilePrefixStateStore', () {
    const model = ModelIdentity.fixed('m');
    PrefixKey key(String prefix) => PrefixKey.of(_info(), model, prefix);
    late String dir;

    setUp(() => dir = '${tmp.path}/states');

    Future<String> put(FilePrefixStateStore store, String prefix, {int bytes = 4}) =>
        store.put(key(prefix), (temp) async => File(temp).writeAsStringSync('x' * bytes));

    List<String> states() => [
      for (final entity in Directory(dir).listSync())
        if (entity.path.endsWith('.state')) entity.uri.pathSegments.last,
    ]..sort();

    test('put writes prefix_<key>.state through a temporary file renamed into place', () async {
      final store = FilePrefixStateStore(dir);
      String? tempPath;
      final path = await store.put(key('a'), (temp) async {
        tempPath = temp;
        expect(File(store.pathOf(key('a'))).existsSync(), isFalse, reason: 'not in place while being written');
        File(temp).writeAsStringSync('state');
      });
      expect(path, '$dir/prefix_${key('a').id}.state');
      expect(tempPath, '$path.tmp');
      expect(File(tempPath!).existsSync(), isFalse);
      expect(File(path).readAsStringSync(), 'state');
      expect(await store.find(key('a')), path);
      expect(await store.find(key('b')), isNull);
    });

    test('a failed write leaves nothing behind and the error goes to the caller', () async {
      final store = FilePrefixStateStore(dir);
      await expectLater(
        store.put(key('a'), (temp) async {
          File(temp).writeAsStringSync('half');
          throw const StateFileException('disk full');
        }),
        throwsA(isA<StateFileException>()),
      );
      expect(Directory(dir).listSync(), isEmpty);
      expect(await store.find(key('a')), isNull);
    });

    test('LRU by modification time: at most maxEntries states; find marks one used', () async {
      final store = FilePrefixStateStore(dir, maxEntries: 3);
      final a = await put(store, 'a');
      final b = await put(store, 'b');
      final c = await put(store, 'c');
      final old = DateTime(2020);
      File(a).setLastModifiedSync(old.add(const Duration(seconds: 1)));
      File(b).setLastModifiedSync(old.add(const Duration(seconds: 2)));
      File(c).setLastModifiedSync(old.add(const Duration(seconds: 3)));
      expect(await store.find(key('a')), a);
      expect(File(a).lastModifiedSync().isAfter(old.add(const Duration(days: 1))), isTrue, reason: 'touched');
      await put(store, 'd');
      expect(await store.find(key('b')), isNull, reason: 'the least recently used');
      expect(
        states(),
        unorderedEquals([
          for (final p in ['a', 'c', 'd']) 'prefix_${key(p).id}.state',
        ]),
      );
    });

    test('maxBytes: the newest states that fit; the one just put stays whatever its size', () async {
      final store = FilePrefixStateStore(dir, maxEntries: 10, maxBytes: 10);
      final a = await put(store, 'a', bytes: 4);
      File(a).setLastModifiedSync(DateTime(2020));
      final b = await put(store, 'b', bytes: 4);
      File(b).setLastModifiedSync(DateTime(2021));
      await put(store, 'c', bytes: 4);
      expect(states(), unorderedEquals(['prefix_${key('b').id}.state', 'prefix_${key('c').id}.state']));
      await put(store, 'big', bytes: 30);
      expect(states(), ['prefix_${key('big').id}.state']);
    });

    test('states of other keys in the folder age out with the rest; other files stay', () async {
      Directory(dir).createSync(recursive: true);
      final stale = File('$dir/prefix_0123456789abcdef.state')..writeAsStringSync('old key');
      stale.setLastModifiedSync(DateTime(2020));
      final foreign = File('$dir/notes.txt')..writeAsStringSync('keep');
      final store = FilePrefixStateStore(dir, maxEntries: 1);
      await put(store, 'a');
      expect(stale.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
    });

    test('the first call removes the temporary files a previous run left; not other files', () async {
      Directory(dir).createSync(recursive: true);
      final leftover = File('$dir/prefix_0123456789abcdef.state.tmp')..writeAsStringSync('half');
      final other = File('$dir/download.tmp')..writeAsStringSync('not ours');
      expect(await FilePrefixStateStore(dir).find(key('a')), isNull);
      expect(leftover.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });

    test('remove and clear', () async {
      final store = FilePrefixStateStore(dir);
      await put(store, 'a');
      await put(store, 'b');
      await store.remove(key('a'));
      await store.remove(key('missing'));
      expect(states(), ['prefix_${key('b').id}.state']);
      File('$dir/notes.txt').writeAsStringSync('keep');
      await store.clear();
      expect(states(), isEmpty);
      expect(File('$dir/notes.txt').existsSync(), isTrue);
      await FilePrefixStateStore('${tmp.path}/never-created').clear();
    });

    test('temporary() is a folder under the system temp; maxEntries must be positive', () {
      expect(FilePrefixStateStore.temporary().directory, '${Directory.systemTemp.path}/local_inference/prefix_states');
      expect(() => FilePrefixStateStore(dir, maxEntries: 0), throwsArgumentError);
    });

    test('its calls, and ModelIdentity.ofFile, complete with microtasks alone, as in a widget test\'s fake-async '
        'zone: no timer, no I/O callback', () {
      Directory(dir).createSync(recursive: true);
      File('$dir/prefix_0123456789abcdef.state.tmp').writeAsStringSync('half');
      final store = FilePrefixStateStore(dir, maxEntries: 1);
      final model = File('${tmp.path}/m.gguf')..writeAsStringSync('x');
      expect(_completesWithMicrotasks(() => store.find(key('a'))), isNull);
      expect(_completesWithMicrotasks(() => put(store, 'a')), store.pathOf(key('a')));
      expect(_completesWithMicrotasks(() => put(store, 'b')), store.pathOf(key('b')));
      expect(_completesWithMicrotasks(() => store.find(key('b'))), store.pathOf(key('b')));
      expect(states(), ['prefix_${key('b').id}.state']);
      _completesWithMicrotasks(() => store.remove(key('b')));
      _completesWithMicrotasks(store.clear);
      expect(_completesWithMicrotasks(() => ModelIdentity.ofFile(model.path)), isA<ModelIdentity>());
    });
  });

  group('PrefixCache', () {
    late File modelFile;
    late ScriptedEngine engine;
    late InMemoryPrefixStateStore store;

    setUp(() async {
      modelFile = File('${tmp.path}/model.gguf')..writeAsStringSync('model');
      engine = ScriptedEngine();
      await engine.load(modelFile.path);
      store = InMemoryPrefixStateStore('${tmp.path}/memory');
      Directory(store.directory).createSync();
    });

    PrefixCache cache() => PrefixCache(engine: engine, model: const ModelIdentity.fixed('model.gguf'), store: store);

    test('prepare builds the state the first time (onBuild first), then restores it', () async {
      final events = <String>[];
      final built = await cache().prepare('PREFIX', onBuild: () => events.add('build (saves ${engine.saves})'));
      expect((built, engine.saves, engine.loads), (PrefixPreparation.built, 1, 0));
      expect(events, ['build (saves 0)']);
      final key = PrefixKey.of(engine.info!, const ModelIdentity.fixed('model.gguf'), 'PREFIX').id;
      expect(File('${store.directory}/prefix_$key.state').readAsStringSync(), 'PREFIX');
      final restored = await cache().prepare('PREFIX', onBuild: () => events.add('again'));
      expect((restored, engine.saves, engine.loads), (PrefixPreparation.restored, 1, 1));
      expect(events, ['build (saves 0)']);
    });

    test('beforeGeneration restores only when contextEpoch moved since its own restore or build', () async {
      final prefix = cache();
      expect(await prefix.beforeGeneration(), Duration.zero, reason: 'nothing prepared yet');
      await prefix.prepare('PREFIX');
      expect(await prefix.beforeGeneration(), Duration.zero);
      expect(engine.loads, 0, reason: 'the context still holds the prefix it built');
      engine.outputs.add('answer');
      await engine.generate('PREFIX question').result;
      expect(await prefix.beforeGeneration(), greaterThan(Duration.zero));
      expect(engine.loads, 1);
      expect(await prefix.beforeGeneration(), Duration.zero);
      expect(engine.loads, 1);
      await engine.saveState('${tmp.path}/other.state', 'OTHER');
      await prefix.beforeGeneration();
      expect(engine.loads, 2, reason: 'a state save of someone else moves the context too');
    });

    test(
      'the epoch of its own build or restore is the one at the engine call: a call queued behind it counts',
      () async {
        final prefix = cache();
        for (final step in ['build', 'restore']) {
          // A gated generation holds the engine, so the cache's saveState or loadState waits behind it; a generation
          // called meanwhile runs after it and moves the context away from the prefix.
          engine.gate = Completer<void>();
          engine.outputs.addAll(['held', 'after']);
          final held = engine.generate('held').result;
          final before = engine.contextEpoch;
          final prepared = prefix.prepare('PREFIX');
          while (engine.contextEpoch == before) {
            await Future<void>.delayed(Duration.zero);
          }
          final after = engine.generate('after').result;
          engine.gate!.complete();
          expect(await prepared, step == 'build' ? PrefixPreparation.built : PrefixPreparation.restored);
          await Future.wait([held, after]);
          final loads = engine.loads;
          await prefix.beforeGeneration();
          expect(engine.loads, loads + 1, reason: 'the generation after the $step moved the context');
        }
        engine.gate = null;
      },
    );

    test('a state that is missing when needed is built again', () async {
      final prefix = cache();
      await prefix.prepare('PREFIX');
      engine.outputs.add('x');
      await engine.generate('p').result;
      for (final file in Directory(store.directory).listSync()) {
        file.deleteSync();
      }
      await prefix.beforeGeneration();
      expect((engine.saves, engine.loads), (2, 0));
      expect(store.keys, hasLength(1));
      expect(await prefix.beforeGeneration(), Duration.zero);
    });

    test('a state that fails to load is removed and built again: in prepare and before a generation', () async {
      final prefix = cache();
      await prefix.prepare('PREFIX');
      engine.failNextLoadState = 'corrupt';
      expect(await cache().prepare('PREFIX'), PrefixPreparation.built);
      expect((engine.saves, engine.loads, store.removes.length), (2, 1, 1));
      engine.outputs.add('x');
      await engine.generate('p').result;
      engine.failNextLoadState = 'corrupt';
      await prefix.beforeGeneration();
      expect((engine.saves, engine.loads, store.removes.length), (3, 2, 2));
      expect(await prefix.beforeGeneration(), Duration.zero);
    });

    test('an engine that cannot save states: unsupported, and nothing to restore', () async {
      final plain = ScriptedEngine(supportsStatePersistence: false);
      await plain.load(modelFile.path);
      final prefix = PrefixCache(engine: plain, model: const ModelIdentity.fixed('m'), store: store);
      var built = false;
      expect(await prefix.prepare('PREFIX', onBuild: () => built = true), PrefixPreparation.unsupported);
      plain.outputs.add('x');
      await plain.generate('p').result;
      expect(await prefix.beforeGeneration(), Duration.zero);
      expect((built, plain.saves, plain.loads, store.puts.length), (false, 0, 0, 0));
      expect(prefix.prefix, isNull);
    });

    test('prepare needs a loaded model', () async {
      final unloaded = PrefixCache(engine: ScriptedEngine(), model: const ModelIdentity.fixed('m'), store: store);
      await expectLater(unloaded.prepare('p'), throwsStateError);
    });
  });

  group('InMemoryPrefixStateStore', () {
    test('keeps its index in memory, records the calls, counts a deleted file as missing', () async {
      final store = InMemoryPrefixStateStore();
      addTearDown(store.clear);
      final key = PrefixKey.of(_info(), const ModelIdentity.fixed('m'), 'p');
      final path = await store.put(key, (temp) async => File(temp).writeAsStringSync('s'));
      expect(path, startsWith(store.directory));
      expect(await store.find(key), path);
      expect(store.keys, [key.id]);
      File(path).deleteSync();
      expect(await store.find(key), isNull);
      expect(store.keys, isEmpty);
      await store.remove(key);
      expect(
        [store.finds, store.puts, store.removes],
        [
          [key.id, key.id],
          [key.id],
          [key.id],
        ],
      );
      final directory = store.directory;
      await store.clear();
      expect(Directory(directory).existsSync(), isFalse, reason: 'it created the folder, so it deletes it');
    });
  });
}

/// The value of [body]'s future, run in a zone whose microtasks this function runs itself, with no timers: it fails
/// unless the future completes once those microtasks have run, before any event of the real event loop.
Object? _completesWithMicrotasks(Future<Object?> Function() body) {
  final microtasks = <void Function()>[];
  Object? value;
  var done = false;
  runZoned(
    () => body().then((result) {
      value = result;
      done = true;
    }),
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, task) => microtasks.add(task),
      createTimer: (self, parent, zone, duration, callback) => throw StateError('a timer'),
    ),
  );
  while (!done && microtasks.isNotEmpty) {
    microtasks.removeAt(0)();
  }
  if (!done) fail('the future did not complete with microtasks alone');
  return value;
}
