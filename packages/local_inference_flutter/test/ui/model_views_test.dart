// The download views: consent with the size, progress with pause, resume and cancel, the mobile-data prompt, and a
// narrow phone with large text; in Italian and in English.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

/// A 4B entry (a fine-tuned Qwen3.5 4B): 3,1 GB, for an 8 GB phone.
final ModelEntry big = ModelManifest.parse(
  jsonEncode({
    'schemaVersion': 1,
    'manifestVersion': '2026-09-17',
    'models': [
      {
        'id': 'qwen35-4b-tuned',
        'version': 1,
        'displayName': 'Assistant 4B (Qwen3.5, Q5_K_M)',
        'params': '4B',
        'quant': 'Q5_K_M',
        'format': 'gguf',
        'status': 'active',
        'recommended': true,
        'file': {'url': 'https://example.org/test-4b.gguf', 'sizeBytes': 3074986592, 'sha256': 'a' * 64},
        'requirements': {'minPhysicalRamMB': 7000, 'minAvailableMemoryMB': 3800, 'minFreeDiskMB': 3726},
      },
    ],
  }),
).models.single;

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  LocalInferenceStrings strings = LocalInferenceStrings.italian,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(
      LocalInferenceScope(
        strings: strings,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  const it = ModelSetupStrings.italian;

  testWidgets('consent shows the size and asks before downloading', (tester) async {
    var downloads = 0;
    var others = 0;
    await _show(
      tester,
      ModelConsentView(entry: big, assistantName: 'Ada', onDownload: () => downloads++, onChooseOther: () => others++),
    );
    expect(find.text('Avvia la sperimentazione di Ada'), findsOneWidget);
    expect(find.text('≈ 3,1 GB'), findsOneWidget);
    expect(find.textContaining('Per provare Ada scarica il suo modello'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    await tester.tap(find.text('Scarica e prova'));
    await tester.tap(find.byKey(LocalInferenceKeys.setupChooseOther));
    expect((downloads, others), (1, 1));

    await _show(
      tester,
      ModelConsentView(
        entry: big,
        assistantName: 'Ada',
        onDownload: () => downloads++,
        problem: 'Serve un telefono con almeno 8 GB di memoria.',
      ),
    );
    expect(find.text('Serve un telefono con almeno 8 GB di memoria.'), findsOneWidget);
    expect(find.text(it.chooseOther), findsNothing);
    await tester.tap(find.text('Scarica e prova'));
    expect(downloads, 1, reason: 'the button is off when the phone cannot run the model');

    await _show(
      tester,
      ModelConsentView(
        entry: big,
        assistantName: 'Ada',
        onDownload: () => downloads++,
        notice: 'Connessione interrotta: riprova.',
        onChooseOther: () => others++,
      ),
    );
    expect(find.text('Connessione interrotta: riprova.'), findsOneWidget);
    expect(find.text('Scarica e prova'), findsNothing);
    await tester.tap(find.byKey(LocalInferenceKeys.setupDownload));
    expect(downloads, 2, reason: 'a failed attempt does not stop a new one');
    expect(find.text('Riprova'), findsOneWidget);
  });

  testWidgets('progress: percent, gigabytes, speed, hint and the buttons of each state', (tester) async {
    final taps = <String>[];
    Widget view(ModelStatus status) => ModelProgressView(
      entry: big,
      status: status,
      onPause: () => taps.add('pause'),
      onResume: () => taps.add('resume'),
      onCancel: () => taps.add('cancel'),
      onUseCellular: () => taps.add('cellular'),
    );

    await _show(
      tester,
      view(
        const ModelStatus(
          state: ModelState.downloading,
          progress: 0.42,
          bytesDone: 1291494368,
          bytesTotal: 3074986592,
          bytesPerSecond: 12.5e6,
          timeRemaining: Duration(minutes: 3),
        ),
      ),
    );
    expect(find.text("Scarico l'assistente…"), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('1,3 / 3,1 GB'), findsOneWidget);
    expect(find.text('12,5 MB/s · circa 3 min'), findsOneWidget);
    expect(find.text(it.downloadHint), findsOneWidget);
    expect(find.text('Riprendi'), findsNothing);
    await tester.tap(find.text('Metti in pausa'));
    await tester.tap(find.text('Annulla'));

    await _show(tester, view(const ModelStatus(state: ModelState.queued)));
    expect(find.text("Scarico l'assistente…"), findsOneWidget);
    expect(find.text('Metti in pausa'), findsNothing, reason: 'a queued download has nothing to pause');
    expect(find.text('Annulla'), findsOneWidget);

    await _show(tester, view(const ModelStatus(state: ModelState.queued, progress: 0.1, waitingForNetwork: true)));
    expect(find.text('In attesa di connessione…'), findsOneWidget);
    expect(find.text('Usa la rete mobile'), findsNothing, reason: 'offline, mobile data would not help either');

    await _show(tester, view(const ModelStatus(state: ModelState.paused, progress: 0.42, bytesDone: 1291494368)));
    expect(find.text('Download in pausa'), findsOneWidget);
    await tester.tap(find.text('Riprendi'));

    await _show(tester, view(const ModelStatus(state: ModelState.waitingForWifi, progress: 0.1)));
    expect(find.text('In attesa del Wi-Fi…'), findsOneWidget);
    await tester.tap(find.byKey(LocalInferenceKeys.progressUseCellular));

    await _show(tester, view(const ModelStatus(state: ModelState.verifying, progress: 1, bytesDone: 3074986592)));
    expect(find.text('Verifico il file…'), findsOneWidget);
    expect(find.text('Annulla'), findsNothing);

    await _show(tester, view(const ModelStatus(state: ModelState.failed, error: ModelError(ModelErrorCode.integrity))));
    expect(find.text('Il file scaricato non è integro: riprova.'), findsOneWidget);
    await tester.tap(find.text('Riprova'));

    expect(taps, ['pause', 'cancel', 'resume', 'cellular', 'resume']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mobile-data prompt shows the size; a presenter can replace it', (tester) async {
    bool? answer;
    await _show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showCellularDialog(context, big),
          child: const Text('apri'),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    expect(find.text('Sei su rete mobile'), findsOneWidget);
    expect(find.textContaining('3,1 GB'), findsOneWidget);
    expect(find.text('Annulla'), findsOneWidget);
    await tester.tap(find.text('Scarica'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);

    final asked = <ConfirmDialogRequest>[];
    await _show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showCellularDialog(
            context,
            big,
            presenter: (context, request) async {
              asked.add(request);
              return false;
            },
          ),
          child: const Text('apri'),
        ),
      ),
      strings: LocalInferenceStrings.english,
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(asked.single.title, "You're on mobile data");
    expect(asked.single.message, 'The model is 3.1 GB: downloading it without Wi-Fi uses your mobile data.');
  });

  testWidgets('English: the same views speak English', (tester) async {
    await _show(
      tester,
      ModelConsentView(entry: big, assistantName: 'Helper', onDownload: () {}),
      strings: LocalInferenceStrings.english,
    );
    expect(find.text('Start trying Helper'), findsOneWidget);
    expect(find.text('≈ 3.1 GB'), findsOneWidget);
    expect(find.text('Download and try'), findsOneWidget);
  });

  testWidgets('a narrow phone with large text: no overflow in consent and progress', (tester) async {
    Future<void> narrow(Widget child) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          LocalInferenceScope(
            strings: LocalInferenceStrings.italian,
            child: MediaQuery.withClampedTextScaling(
              minScaleFactor: 1.3,
              maxScaleFactor: 1.3,
              child: Scaffold(body: child),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await narrow(
      ModelConsentView(
        entry: big,
        assistantName: 'Ada',
        onDownload: () {},
        problem: 'Serve un telefono con almeno 8 GB di memoria.',
        onChooseOther: () {},
      ),
    );
    expect(find.text('Serve un telefono con almeno 8 GB di memoria.'), findsOneWidget);
    await narrow(
      ModelProgressView(
        entry: big,
        status: const ModelStatus(
          state: ModelState.failed,
          progress: 0.99,
          bytesDone: 3044236726,
          bytesTotal: 3074986592,
          error: ModelError(
            ModelErrorCode.download,
            download: DownloadError(DownloadErrorCode.httpStatus, httpStatus: 503),
          ),
        ),
        onResume: () {},
        onCancel: () {},
      ),
    );
  });
}
