// The string packs, byte for byte: the Italian model-setup texts (consent, progress, problems, errors, the model
// list) and the codes of local_inference that map to them; the English pack says the same in English. Also the
// chat's texts, what screen readers say, and the packs' resolution.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

void main() {
  const it = ModelSetupStrings.italian;
  const formats = LocalizedFormats.italian;

  test('the texts of the consent, progress, mobile-data, model-list and first-launch views', () {
    final texts = {
      it.consentTitle('Ada'): 'Avvia la sperimentazione di Ada',
      it.sizeApprox('3,1 GB'): '≈ 3,1 GB',
      it.consentBody('Ada'):
          'Per provare Ada scarica il suo modello di intelligenza artificiale. Funziona sul tuo dispositivo, quindi si '
          'scarica una volta sola: un file di qualche GB, meglio sotto Wi-Fi. Poi risponde anche senza connessione.',
      it.downloadButton: 'Scarica e prova',
      it.retryButton: 'Riprova',
      it.chooseOther: 'Scegli un altro modello',
      it.recommendedForDevice: 'consigliato per questo telefono',
      it.progressDownloading: "Scarico l'assistente…",
      it.progressVerifying: 'Verifico il file…',
      it.progressWaitingForWifi: 'In attesa del Wi-Fi…',
      it.progressWaitingForNetwork: 'In attesa di connessione…',
      it.progressPaused: 'Download in pausa',
      it.progressFailed: 'Download non riuscito',
      it.progressSemanticsLabel: 'Scaricamento',
      it.downloadHint:
          "Ti consigliamo di non chiudere l'app: il download è di qualche GB. Tieni il dispositivo acceso e resta sotto "
          'Wi-Fi; se la connessione cade riprende da solo.',
      it.pause: 'Metti in pausa',
      it.resume: 'Riprendi',
      it.useCellular: 'Usa la rete mobile',
      it.cancel: 'Annulla',
      it.cellularTitle: 'Sei su rete mobile',
      it.cellularBody('3,1 GB'): 'Il modello pesa 3,1 GB: scaricarlo senza Wi-Fi consuma il tuo traffico dati.',
      it.cellularAction: 'Scarica',
      it.libraryUnavailable: 'Elenco modelli non disponibile.',
      it.libraryTitle: 'Modelli sul dispositivo',
      it.libraryNone: 'Nessuno',
      it.wifiOnly: 'Scarica solo con Wi-Fi',
      it.catalogOrigin(CatalogOrigin.remote): 'Elenco modelli: online',
      it.catalogOrigin(CatalogOrigin.bundled): "Elenco modelli: incluso nell'app",
      it.tileNotDownloaded: 'Non scaricato',
      it.tileWaitingForNetwork: 'In attesa di connessione',
      it.tileQueued: 'In coda',
      it.tileDownloading('42%'): 'Scarico… 42%',
      it.tilePaused('42%'): 'In pausa · 42%',
      it.tileWaitingForWifi: 'In attesa del Wi-Fi',
      it.tileVerifying: 'Verifico il file…',
      it.tileInUse: 'In uso',
      it.tileReady: 'Pronto',
      it.tileFailed: 'Download non riuscito',
      it.actionDownload: 'Scarica',
      it.actionPause: 'Pausa',
      it.actionResume: 'Riprendi',
      it.actionCancel: 'Annulla',
      it.actionUseCellular: 'Usa la rete mobile',
      it.actionUse: 'Usa',
      it.actionDelete: 'Elimina',
      it.recommendedBadge: 'Consigliato',
      it.deleteTitle: 'Elimino il modello?',
      it.deleteBody: 'Lo spazio torna libero subito.',
      it.deleteAction: 'Elimina',
      it.noneOfferedTitle: 'Al momento non ci sono modelli da scaricare',
      it.noneOfferedSubtitle: 'Riprova più tardi.',
      it.downloadStartFailed(StateError('x')): 'Non riesco ad avviare il download: Bad state: x',
    };
    for (final MapEntry(key: actual, value: expected) in texts.entries) {
      expect(actual, expected);
    }
    expect(it.catalogOrigin(CatalogOrigin.fixed), "Elenco modelli: incluso nell'app");
  });

  test('problems: the reasons of problemFor, with the sizes of a 4B and a 2B', () {
    expect(it.problem(const NotOffered(), formats), 'Questo modello non è più disponibile.');
    expect(it.problem(const NotEnoughRam(7000), formats), 'Serve un telefono con almeno 8 GB di memoria.');
    expect(it.problem(const NotEnoughRam(5500), formats), 'Serve un telefono con almeno 6 GB di memoria.');
    expect(
      it.problem(const NotEnoughMemory(3800, 2000), formats),
      'Memoria disponibile insufficiente: servono 4,0 GB, disponibili 2,1 GB.',
    );
    expect(
      it.problem(const NotEnoughDisk(3726, 1200), formats),
      'Spazio libero insufficiente: servono 3,9 GB, disponibili 1,3 GB.',
    );
    expect(it.problem(const HostRefused('Solo sui telefoni aziendali.'), formats), 'Solo sui telefoni aziendali.');
  });

  test('errors: the manager\'s own and the downloader\'s', () {
    String model(ModelErrorCode code) => it.error(ModelError(code));
    String download(DownloadErrorCode code, {int? status}) => it.error(
      ModelError(
        ModelErrorCode.download,
        download: DownloadError(code, httpStatus: status, detail: 'x'),
      ),
    );
    expect(model(ModelErrorCode.integrity), 'Il file scaricato non è integro: riprova.');
    expect(model(ModelErrorCode.fileMissing), 'Il file scaricato non si trova: riprova.');
    expect(model(ModelErrorCode.cannotVerify), 'Non riesco a verificare il file: riprova.');
    expect(model(ModelErrorCode.cannotSave), 'Non riesco a salvare il modello: riprova.');
    expect(model(ModelErrorCode.cannotStart), 'Non riesco ad avviare il download: riprova.');
    expect(model(ModelErrorCode.cannotResume), 'Non riesco a riprendere il download: riprova.');
    expect(model(ModelErrorCode.notAModelFile), 'Il file scaricato non è un modello: riprova più tardi.');
    expect(model(ModelErrorCode.download), 'Download non riuscito: riprova.');
    expect(download(DownloadErrorCode.notFound), 'Il file del modello non è sul server: riprova più tardi.');
    expect(
      download(DownloadErrorCode.httpStatus, status: 403),
      'Il server ha risposto con un errore (403): riprova più tardi.',
    );
    expect(download(DownloadErrorCode.connection), 'Connessione interrotta: riprova.');
    expect(download(DownloadErrorCode.diskFull), 'Spazio libero insufficiente: libera spazio e riprova.');
    expect(download(DownloadErrorCode.fileSystem), 'Non riesco a salvare il file: riprova.');
    expect(download(DownloadErrorCode.cannotStart), 'Non riesco ad avviare il download: riprova.');
    expect(download(DownloadErrorCode.cannotResume), 'Non riesco a riprendere il download: riprova.');
    expect(download(DownloadErrorCode.unknown), 'Download non riuscito: riprova.');
    expect(
      download(DownloadErrorCode.webPageInsteadOfFile),
      'Il server ha inviato una pagina web invece del modello: riprova più tardi.',
    );
    expect(it.downloadError(null), 'Download non riuscito: riprova.');
  });

  test('every code of local_inference has a text in both packs', () {
    const problems = [
      NotOffered(),
      NotEnoughRam(7000),
      NotEnoughMemory(3800, 2000),
      NotEnoughDisk(3726, 1200),
      HostRefused('Solo sui telefoni aziendali.'),
    ];
    for (final (strings, formats) in [
      (ModelSetupStrings.italian, LocalizedFormats.italian),
      (ModelSetupStrings.english, LocalizedFormats.english),
    ]) {
      for (final code in ModelErrorCode.values) {
        expect(strings.error(ModelError(code)), isNotEmpty, reason: '$code');
        for (final download in DownloadErrorCode.values) {
          final error = ModelError(code, download: DownloadError(download, httpStatus: 503, detail: 'x'));
          expect(strings.error(error), isNotEmpty, reason: '$code, $download');
        }
      }
      for (final code in DownloadErrorCode.values) {
        expect(strings.downloadError(DownloadError(code)), isNotEmpty, reason: '$code');
      }
      for (final problem in problems) {
        expect(strings.problem(problem, formats), isNotEmpty, reason: '$problem');
      }
    }
    // The failures of a finished download: a web page or no model at all, and a resume the kept data could not serve.
    expect(it.error(ModelError(ModelErrorCode.download, download: DownloadError.notAGgufFile)), isNotEmpty);
    expect(
      it.error(const ModelError(ModelErrorCode.notAModelFile, download: DownloadError.notAGgufFile)),
      'Il file scaricato non è un modello: riprova più tardi.',
    );
    expect(
      it.error(
        const ModelError(
          ModelErrorCode.download,
          download: DownloadError(DownloadErrorCode.webPageInsteadOfFile, httpStatus: 200),
        ),
      ),
      'Il server ha inviato una pagina web invece del modello: riprova più tardi.',
    );
    expect(
      ModelSetupStrings.english.error(const ModelError(ModelErrorCode.notAModelFile, detail: 'a web page')),
      'The downloaded file is not a model: try again later.',
    );
  });

  test('speed and time labels', () {
    expect(formats.speed(12.345e6), '12,3 MB/s');
    expect(formats.speed(0.85e6), '850 kB/s');
    expect(formats.speed(-1), isNull);
    expect(formats.speed(null), isNull);
    expect(formats.remaining(const Duration(seconds: 30)), 'meno di un minuto');
    expect(formats.remaining(const Duration(minutes: 4, seconds: 10)), 'circa 5 min');
    expect(formats.remaining(const Duration(hours: 1, minutes: 20)), 'circa 1 h 20 min');
    expect(formats.remaining(const Duration(hours: 2)), 'circa 2 h');
    expect(formats.remaining(const Duration(seconds: -1)), isNull);
    expect(formats.remaining(Duration.zero), isNull);
  });

  test('Italian size labels', () {
    expect(formats.bytes(3074986592), '3,1 GB');
    expect(formats.bytes(1454787104), '1,5 GB');
    expect(formats.bytes(850000000), '850 MB');
    expect(formats.megabytes(3726), '3,9 GB');
    expect(formats.ramLabel(7000), '8 GB');
    expect(formats.ramLabel(5500), '6 GB');
    expect(formats.ramLabel(3500), '4 GB');
    expect(formats.ramLabel(70000), '69 GB');
    expect(formats.percent(0.429), '42%');
    expect(formats.gigabytesPair(1291494368, 3074986592), '1,3 / 3,1 GB');
  });

  test('the Italian notification texts name the app; the complete one is neutral', () {
    final named = DownloadNotifications.italian(appName: 'Ada');
    expect(named.running, const DownloadNotificationText('Scarico Ada', '{progress}'));
    expect(named.paused, const DownloadNotificationText('Download di Ada in pausa', "Apri l'app per riprenderlo."));
    // The system posts it when the transfer ends, before the file is checked: it does not say "Ada scaricato".
    expect(
      named.complete,
      const DownloadNotificationText('Download di Ada terminato', "Apri l'app per controllarlo e iniziare."),
    );
    expect(named.error, const DownloadNotificationText('Download di Ada non riuscito', "Apri l'app per riprovare."));
    expect(named.actionLabels, {'Cancel': 'Annulla', 'Pause': 'Pausa', 'Resume': 'Riprendi'});
    expect(named.progressBar, isTrue);
    expect(const BackgroundDownloadConfig(appName: 'Ada').resolvedNotifications, named);
    expect(DownloadNotifications.italian().running!.title, 'Scarico il modello');
    expect(DownloadNotifications.italian().complete!.title, 'Download del modello terminato');
    expect(DownloadNotifications.english(appName: 'Ada').complete!.title, 'Ada download finished');
    expect(DownloadNotifications.english().actionLabels, isNull);
  });

  test('the English pack speaks English; copyWith replaces single texts and formats', () {
    const en = ModelSetupStrings.english;
    const enFormats = LocalizedFormats.english;
    expect(enFormats.bytes(3074986592), '3.1 GB');
    expect(enFormats.speed(12.345e6), '12.3 MB/s');
    expect(enFormats.remaining(const Duration(minutes: 4, seconds: 10)), 'about 5 min');
    expect(enFormats.gigabytesPair(1291494368, 3074986592), '1.3 / 3.1 GB');
    expect(
      en.problem(const NotEnoughDisk(3726, 1200), enFormats),
      'Not enough free space: 3.9 GB needed, 1.3 GB available.',
    );
    expect(en.error(const ModelError(ModelErrorCode.integrity)), 'The downloaded file is damaged: try again.');
    expect(en.consentTitle('Ada'), 'Start trying Ada');
    final replaced = it.copyWith(retryButton: 'Di nuovo', tileDownloading: (percent) => '… $percent');
    expect((replaced.retryButton, replaced.tileDownloading('1%'), replaced.cancel), ('Di nuovo', '… 1%', 'Annulla'));
    final kilo = formats.copyWith(bytes: (bytes) => '$bytes B');
    expect((kilo.bytes(5), kilo.megabytes(1)), ('5 B', '1 MB'), reason: 'each format is replaced on its own');
  });

  group('chat', () {
    const chat = ChatStrings.italian;

    test('the Italian chat texts are byte-equal', () {
      final texts = {
        chat.preparingTitle: "Preparo l'assistente…",
        chat.preparingFirstTime:
            'Solo la prima volta con questo modello: leggo le istruzioni e gli strumenti una volta e le salvo sul '
            'dispositivo.',
        chat.loadFailedTitle: 'Si è verificato un errore',
        chat.retry: 'Riprova',
        chat.noModelTitle: 'Nessun modello sul dispositivo',
        chat.refresh: 'Aggiorna',
        chat.composerHint: 'Scrivi un messaggio…',
        chat.staleScreenRequest: "Nel frattempo l'elenco è cambiato: chiedimelo di nuovo in chat.",
        chat.thinking: 'Sto pensando…',
        chat.detailsGuardedPrefix: '⚠︎ risposta sostituita: ',
        chat.report: 'Segnala risposta',
        A11yStrings.italian.send: 'Invia',
        A11yStrings.italian.stop: 'Interrompi',
        A11yStrings.italian.newConversation: 'Nuova conversazione',
      };
      for (final MapEntry(key: actual, value: expected) in texts.entries) {
        expect(actual, expected);
      }
      expect(chat.confirmLabel, isNull, reason: 'the buttons say the assistant\'s own Yes and No');
      expect(chat.declineLabel, isNull);
    });

    test('the texts the adopted improvements add, in both packs', () {
      expect(
        chat.disclosure,
        "Le risposte sono generate da un'intelligenza artificiale sul tuo dispositivo e possono contenere errori.",
      );
      expect(
        ChatStrings.english.disclosure,
        'Replies are generated by an AI running on your device and may contain mistakes.',
      );
      for (final pack in [ChatStrings.italian, ChatStrings.english]) {
        for (final reason in ReportReason.values) {
          expect(pack.reportReason(reason), isNotEmpty);
        }
        for (final text in [pack.reportTitle, pack.reportQuestion, pack.reportThanks, pack.aiGeneratedBadge]) {
          expect(text, isNotEmpty);
        }
      }
      expect(A11yStrings.italian.jumpToLatest, "Vai all'ultimo messaggio");
      expect(A11yStrings.italian.aiGeneratedHint, "Risposta generata dall'intelligenza artificiale");
    });

    test('the panel of a model that is there but not loaded, in both packs', () {
      expect((chat.notLoadedTitle, chat.load), ('Il modello non è caricato', 'Carica'));
      expect((ChatStrings.english.notLoadedTitle, ChatStrings.english.load), ('The model is not loaded', 'Load'));
      expect(chat.copyWith(load: 'Avvia').load, 'Avvia');
    });

    test('a failed load is named by its kind, never by the raw exception', () {
      for (final pack in [ChatStrings.italian, ChatStrings.english]) {
        final texts = {
          pack.loadFailed(const UnsupportedModelException('secret detail')),
          pack.loadFailed(const ModelLoadException('secret detail')),
          pack.loadFailed(StateError('secret detail')),
        };
        expect(texts, hasLength(3));
        expect(texts.join(), isNot(contains('secret')));
      }
      expect(chat.loadFailed(StateError('x')), "Non riesco a preparare l'assistente: riprova.");
    });

    test('screen readers: emoji are not read; the announcement names the assistant', () {
      const a11y = A11yStrings.italian;
      expect(a11y.toolStatus('📦 Cerco i tuoi ordini...'), 'Cerco i tuoi ordini...');
      expect(a11y.toolStatus('⏳ Un momento...'), 'Un momento...');
      expect(A11yStrings.stripEmoji('👍🏽 ok 1️⃣ 🇮🇹 👩‍💻 fine'), 'ok 1 fine');
      expect(a11y.replyAnnouncement('Ada', 'Ecco 📅 i tuoi appuntamenti.'), 'Ada: Ecco i tuoi appuntamenti.');
      expect(a11y.assistantMessage('Ada'), 'Ada');
    });

    test('packs, copyWith and forLocale', () {
      expect(LocalInferenceStrings.italian.chat, same(ChatStrings.italian));
      expect(LocalInferenceStrings.italian.setup, same(ModelSetupStrings.italian));
      expect(LocalInferenceStrings.english.a11y, same(A11yStrings.english));
      expect(LocalInferenceStrings.english.formats, same(LocalizedFormats.english));
      final custom = LocalInferenceStrings.italian.copyWith(
        chat: ChatStrings.italian.copyWith(composerHint: 'Chiedi…', confirmLabel: 'Conferma'),
        a11y: A11yStrings.italian.copyWith(send: 'Manda'),
      );
      expect(
        (custom.chat.composerHint, custom.chat.confirmLabel, custom.chat.retry),
        ('Chiedi…', 'Conferma', 'Riprova'),
      );
      expect((custom.a11y.send, custom.a11y.stop), ('Manda', 'Interrompi'));
      expect(custom.setup, same(ModelSetupStrings.italian));
      expect(LocalInferenceStrings.forLocale(const Locale('it')), same(LocalInferenceStrings.italian));
      expect(LocalInferenceStrings.forLocale(const Locale('en', 'US')), same(LocalInferenceStrings.english));
      expect(LocalInferenceLocalizations.supportedLocales, const [Locale('it'), Locale('en')]);
    });

    test('the confirmation dialogs\' buttons and the status message', () {
      expect((it.dialogCancel, it.dialogOk), ('Annulla', 'Ok'));
      expect((ModelSetupStrings.english.dialogCancel, ModelSetupStrings.english.dialogOk), ('Cancel', 'OK'));
      expect(
        it.statusMessage(const ModelStatus(state: ModelState.failed, problem: NotEnoughRam(7000)), formats),
        'Serve un telefono con almeno 8 GB di memoria.',
      );
      expect(
        it.statusMessage(
          const ModelStatus(state: ModelState.failed, error: ModelError(ModelErrorCode.integrity)),
          formats,
        ),
        'Il file scaricato non è integro: riprova.',
      );
      expect(it.statusMessage(const ModelStatus(state: ModelState.downloading), formats), isNull);
    });
  });
}
