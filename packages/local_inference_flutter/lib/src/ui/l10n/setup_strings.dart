/// The texts of the model setup: first-launch consent, download progress, the mobile-data prompt, the model list,
/// and the words for the codes of local_inference's delivery (problems and errors).
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

import 'formats.dart';

/// Model-setup texts in one language, [italian] or [english] (the same set in English). Templates are functions, so
/// the packs stay constant; [copyWith] replaces any of them.
@immutable
final class ModelSetupStrings {
  const ModelSetupStrings({
    required this.consentTitle,
    required this.sizeApprox,
    required this.consentBody,
    required this.downloadButton,
    required this.retryButton,
    required this.chooseOther,
    required this.recommendedForDevice,
    required this.progressDownloading,
    required this.progressVerifying,
    required this.progressWaitingForWifi,
    required this.progressWaitingForNetwork,
    required this.progressPaused,
    required this.progressFailed,
    required this.progressSemanticsLabel,
    required this.downloadHint,
    required this.pause,
    required this.resume,
    required this.useCellular,
    required this.cancel,
    required this.cellularTitle,
    required this.cellularBody,
    required this.cellularAction,
    required this.libraryUnavailable,
    required this.libraryTitle,
    required this.libraryNone,
    required this.wifiOnly,
    required this.catalogOnline,
    required this.catalogBundled,
    required this.tileNotDownloaded,
    required this.tileWaitingForNetwork,
    required this.tileQueued,
    required this.tileDownloading,
    required this.tilePaused,
    required this.tileWaitingForWifi,
    required this.tileVerifying,
    required this.tileInUse,
    required this.tileReady,
    required this.tileFailed,
    required this.actionDownload,
    required this.actionPause,
    required this.actionResume,
    required this.actionCancel,
    required this.actionUseCellular,
    required this.actionUse,
    required this.actionDelete,
    required this.recommendedBadge,
    required this.deleteTitle,
    required this.deleteBody,
    required this.deleteAction,
    required this.dialogCancel,
    required this.dialogOk,
    required this.noneOfferedTitle,
    required this.noneOfferedSubtitle,
    required this.downloadStartFailed,
    required this.notOffered,
    required this.notEnoughRam,
    required this.notEnoughMemory,
    required this.notEnoughDisk,
    required this.integrityError,
    required this.notAModelFileError,
    required this.fileMissingError,
    required this.cannotVerifyError,
    required this.cannotSaveError,
    required this.cannotStartError,
    required this.cannotResumeError,
    required this.downloadFailedError,
    required this.notFoundError,
    required this.httpStatusError,
    required this.connectionError,
    required this.diskFullError,
    required this.fileSystemError,
    required this.webPageError,
  });

  /// Italian.
  static const italian = ModelSetupStrings(
    consentTitle: _itConsentTitle,
    sizeApprox: _approx,
    consentBody: _itConsentBody,
    downloadButton: 'Scarica e prova',
    retryButton: 'Riprova',
    chooseOther: 'Scegli un altro modello',
    recommendedForDevice: 'consigliato per questo telefono',
    progressDownloading: "Scarico l'assistente…",
    progressVerifying: 'Verifico il file…',
    progressWaitingForWifi: 'In attesa del Wi-Fi…',
    progressWaitingForNetwork: 'In attesa di connessione…',
    progressPaused: 'Download in pausa',
    progressFailed: 'Download non riuscito',
    progressSemanticsLabel: 'Scaricamento',
    downloadHint:
        "Ti consigliamo di non chiudere l'app: il download è di qualche GB. Tieni il dispositivo "
        'acceso e resta sotto Wi-Fi; se la connessione cade riprende da solo.',
    pause: 'Metti in pausa',
    resume: 'Riprendi',
    useCellular: 'Usa la rete mobile',
    cancel: 'Annulla',
    cellularTitle: 'Sei su rete mobile',
    cellularBody: _itCellularBody,
    cellularAction: 'Scarica',
    libraryUnavailable: 'Elenco modelli non disponibile.',
    libraryTitle: 'Modelli sul dispositivo',
    libraryNone: 'Nessuno',
    wifiOnly: 'Scarica solo con Wi-Fi',
    catalogOnline: 'Elenco modelli: online',
    catalogBundled: "Elenco modelli: incluso nell'app",
    tileNotDownloaded: 'Non scaricato',
    tileWaitingForNetwork: 'In attesa di connessione',
    tileQueued: 'In coda',
    tileDownloading: _itTileDownloading,
    tilePaused: _itTilePaused,
    tileWaitingForWifi: 'In attesa del Wi-Fi',
    tileVerifying: 'Verifico il file…',
    tileInUse: 'In uso',
    tileReady: 'Pronto',
    tileFailed: 'Download non riuscito',
    actionDownload: 'Scarica',
    actionPause: 'Pausa',
    actionResume: 'Riprendi',
    actionCancel: 'Annulla',
    actionUseCellular: 'Usa la rete mobile',
    actionUse: 'Usa',
    actionDelete: 'Elimina',
    recommendedBadge: 'Consigliato',
    deleteTitle: 'Elimino il modello?',
    deleteBody: 'Lo spazio torna libero subito.',
    deleteAction: 'Elimina',
    dialogCancel: 'Annulla',
    dialogOk: 'Ok',
    noneOfferedTitle: 'Al momento non ci sono modelli da scaricare',
    noneOfferedSubtitle: 'Riprova più tardi.',
    downloadStartFailed: _itDownloadStartFailed,
    notOffered: 'Questo modello non è più disponibile.',
    notEnoughRam: _itNotEnoughRam,
    notEnoughMemory: _itNotEnoughMemory,
    notEnoughDisk: _itNotEnoughDisk,
    integrityError: 'Il file scaricato non è integro: riprova.',
    notAModelFileError: 'Il file scaricato non è un modello: riprova più tardi.',
    fileMissingError: 'Il file scaricato non si trova: riprova.',
    cannotVerifyError: 'Non riesco a verificare il file: riprova.',
    cannotSaveError: 'Non riesco a salvare il modello: riprova.',
    cannotStartError: 'Non riesco ad avviare il download: riprova.',
    cannotResumeError: 'Non riesco a riprendere il download: riprova.',
    downloadFailedError: 'Download non riuscito: riprova.',
    notFoundError: 'Il file del modello non è sul server: riprova più tardi.',
    httpStatusError: _itHttpStatus,
    connectionError: 'Connessione interrotta: riprova.',
    diskFullError: 'Spazio libero insufficiente: libera spazio e riprova.',
    fileSystemError: 'Non riesco a salvare il file: riprova.',
    webPageError: 'Il server ha inviato una pagina web invece del modello: riprova più tardi.',
  );

  /// The same texts in English.
  static const english = ModelSetupStrings(
    consentTitle: _enConsentTitle,
    sizeApprox: _approx,
    consentBody: _enConsentBody,
    downloadButton: 'Download and try',
    retryButton: 'Try again',
    chooseOther: 'Choose another model',
    recommendedForDevice: 'recommended for this phone',
    progressDownloading: 'Downloading the assistant…',
    progressVerifying: 'Checking the file…',
    progressWaitingForWifi: 'Waiting for Wi-Fi…',
    progressWaitingForNetwork: 'Waiting for a connection…',
    progressPaused: 'Download paused',
    progressFailed: 'Download failed',
    progressSemanticsLabel: 'Downloading',
    downloadHint:
        'Keep the app open: the download is a few GB. Keep the device on and stay on Wi-Fi; if the '
        'connection drops, it resumes by itself.',
    pause: 'Pause',
    resume: 'Resume',
    useCellular: 'Use mobile data',
    cancel: 'Cancel',
    cellularTitle: "You're on mobile data",
    cellularBody: _enCellularBody,
    cellularAction: 'Download',
    libraryUnavailable: 'Model list unavailable.',
    libraryTitle: 'Models on this device',
    libraryNone: 'None',
    wifiOnly: 'Download on Wi-Fi only',
    catalogOnline: 'Model list: online',
    catalogBundled: 'Model list: included in the app',
    tileNotDownloaded: 'Not downloaded',
    tileWaitingForNetwork: 'Waiting for a connection',
    tileQueued: 'Queued',
    tileDownloading: _enTileDownloading,
    tilePaused: _enTilePaused,
    tileWaitingForWifi: 'Waiting for Wi-Fi',
    tileVerifying: 'Checking the file…',
    tileInUse: 'In use',
    tileReady: 'Ready',
    tileFailed: 'Download failed',
    actionDownload: 'Download',
    actionPause: 'Pause',
    actionResume: 'Resume',
    actionCancel: 'Cancel',
    actionUseCellular: 'Use mobile data',
    actionUse: 'Use',
    actionDelete: 'Delete',
    recommendedBadge: 'Recommended',
    deleteTitle: 'Delete the model?',
    deleteBody: 'The space is freed at once.',
    deleteAction: 'Delete',
    dialogCancel: 'Cancel',
    dialogOk: 'OK',
    noneOfferedTitle: 'No models to download right now',
    noneOfferedSubtitle: 'Try again later.',
    downloadStartFailed: _enDownloadStartFailed,
    notOffered: 'This model is no longer available.',
    notEnoughRam: _enNotEnoughRam,
    notEnoughMemory: _enNotEnoughMemory,
    notEnoughDisk: _enNotEnoughDisk,
    integrityError: 'The downloaded file is damaged: try again.',
    notAModelFileError: 'The downloaded file is not a model: try again later.',
    fileMissingError: 'The downloaded file cannot be found: try again.',
    cannotVerifyError: 'The file could not be checked: try again.',
    cannotSaveError: 'The model could not be saved: try again.',
    cannotStartError: 'The download could not start: try again.',
    cannotResumeError: 'The download could not resume: try again.',
    downloadFailedError: 'Download failed: try again.',
    notFoundError: 'The model file is not on the server: try again later.',
    httpStatusError: _enHttpStatus,
    connectionError: 'Connection lost: try again.',
    diskFullError: 'Not enough free space: free some space and try again.',
    fileSystemError: 'The file could not be saved: try again.',
    webPageError: 'The server sent a web page instead of the model: try again later.',
  );

  // Consent.
  final String Function(String assistant) consentTitle;
  final String Function(String size) sizeApprox;
  final String Function(String assistant) consentBody;
  final String downloadButton;
  final String retryButton;
  final String chooseOther;
  final String recommendedForDevice;

  // Progress.
  final String progressDownloading;
  final String progressVerifying;
  final String progressWaitingForWifi;
  final String progressWaitingForNetwork;
  final String progressPaused;
  final String progressFailed;

  /// The progress bar's label for screen readers.
  final String progressSemanticsLabel;
  final String downloadHint;
  final String pause;
  final String resume;
  final String useCellular;
  final String cancel;

  // Mobile-data prompt.
  final String cellularTitle;
  final String Function(String size) cellularBody;
  final String cellularAction;

  // Model list.
  final String libraryUnavailable;
  final String libraryTitle;
  final String libraryNone;
  final String wifiOnly;
  final String catalogOnline;
  final String catalogBundled;
  final String tileNotDownloaded;
  final String tileWaitingForNetwork;
  final String tileQueued;
  final String Function(String percent) tileDownloading;
  final String Function(String percent) tilePaused;
  final String tileWaitingForWifi;
  final String tileVerifying;
  final String tileInUse;
  final String tileReady;
  final String tileFailed;
  final String actionDownload;
  final String actionPause;
  final String actionResume;
  final String actionCancel;
  final String actionUseCellular;
  final String actionUse;
  final String actionDelete;
  final String recommendedBadge;
  final String deleteTitle;
  final String deleteBody;
  final String deleteAction;

  // The confirmation dialogs (mobile data, delete): the button that closes one, and the only button of a notice.
  final String dialogCancel;
  final String dialogOk;

  // First launch.
  final String noneOfferedTitle;
  final String noneOfferedSubtitle;
  final String Function(Object error) downloadStartFailed;

  // Problems (ModelProblem); HostRefused shows its own reason.
  final String notOffered;
  final String Function(String ram) notEnoughRam;
  final String Function(String required, String available) notEnoughMemory;
  final String Function(String required, String available) notEnoughDisk;

  // Errors (ModelErrorCode, DownloadErrorCode).
  final String integrityError;
  final String notAModelFileError;
  final String fileMissingError;
  final String cannotVerifyError;
  final String cannotSaveError;
  final String cannotStartError;
  final String cannotResumeError;

  /// A download that failed without a known reason.
  final String downloadFailedError;
  final String notFoundError;
  final String Function(int? status) httpStatusError;
  final String connectionError;
  final String diskFullError;
  final String fileSystemError;
  final String webPageError;

  /// Why [problem] stops the download, with the sizes in [formats].
  String problem(ModelProblem problem, LocalizedFormats formats) => switch (problem) {
    NotOffered() => notOffered,
    NotEnoughRam(:final requiredMB) => notEnoughRam(formats.ramLabel(requiredMB)),
    NotEnoughMemory(:final requiredMB, :final availableMB) => notEnoughMemory(
      formats.megabytes(requiredMB),
      formats.megabytes(availableMB),
    ),
    NotEnoughDisk(:final requiredMB, :final availableMB) => notEnoughDisk(
      formats.megabytes(requiredMB),
      formats.megabytes(availableMB),
    ),
    HostRefused(:final reason) => reason,
  };

  /// Why a download or its check failed.
  String error(ModelError error) => switch (error.code) {
    ModelErrorCode.integrity => integrityError,
    ModelErrorCode.notAModelFile => notAModelFileError,
    ModelErrorCode.fileMissing => fileMissingError,
    ModelErrorCode.cannotVerify => cannotVerifyError,
    ModelErrorCode.cannotSave => cannotSaveError,
    ModelErrorCode.cannotStart => cannotStartError,
    ModelErrorCode.cannotResume => cannotResumeError,
    ModelErrorCode.download => downloadError(error.download),
  };

  /// Why the downloader failed; [downloadFailedError] when it gave no reason.
  String downloadError(DownloadError? error) => switch (error?.code) {
    null || DownloadErrorCode.unknown => downloadFailedError,
    DownloadErrorCode.notFound => notFoundError,
    DownloadErrorCode.httpStatus => httpStatusError(error?.httpStatus),
    DownloadErrorCode.connection => connectionError,
    DownloadErrorCode.diskFull => diskFullError,
    DownloadErrorCode.fileSystem => fileSystemError,
    DownloadErrorCode.cannotStart => cannotStartError,
    DownloadErrorCode.cannotResume => cannotResumeError,
    DownloadErrorCode.webPageInsteadOfFile => webPageError,
  };

  /// Where the model list came from.
  String catalogOrigin(CatalogOrigin origin) => origin == CatalogOrigin.remote ? catalogOnline : catalogBundled;

  /// Why the download of [status] failed: its problem or its error; null when it has neither.
  String? statusMessage(ModelStatus status, LocalizedFormats formats) {
    final problem = status.problem;
    if (problem != null) return this.problem(problem, formats);
    final error = status.error;
    return error == null ? null : this.error(error);
  }

  ModelSetupStrings copyWith({
    String Function(String assistant)? consentTitle,
    String Function(String size)? sizeApprox,
    String Function(String assistant)? consentBody,
    String? downloadButton,
    String? retryButton,
    String? chooseOther,
    String? recommendedForDevice,
    String? progressDownloading,
    String? progressVerifying,
    String? progressWaitingForWifi,
    String? progressWaitingForNetwork,
    String? progressPaused,
    String? progressFailed,
    String? progressSemanticsLabel,
    String? downloadHint,
    String? pause,
    String? resume,
    String? useCellular,
    String? cancel,
    String? cellularTitle,
    String Function(String size)? cellularBody,
    String? cellularAction,
    String? libraryUnavailable,
    String? libraryTitle,
    String? libraryNone,
    String? wifiOnly,
    String? catalogOnline,
    String? catalogBundled,
    String? tileNotDownloaded,
    String? tileWaitingForNetwork,
    String? tileQueued,
    String Function(String percent)? tileDownloading,
    String Function(String percent)? tilePaused,
    String? tileWaitingForWifi,
    String? tileVerifying,
    String? tileInUse,
    String? tileReady,
    String? tileFailed,
    String? actionDownload,
    String? actionPause,
    String? actionResume,
    String? actionCancel,
    String? actionUseCellular,
    String? actionUse,
    String? actionDelete,
    String? recommendedBadge,
    String? deleteTitle,
    String? deleteBody,
    String? deleteAction,
    String? dialogCancel,
    String? dialogOk,
    String? noneOfferedTitle,
    String? noneOfferedSubtitle,
    String Function(Object error)? downloadStartFailed,
    String? notOffered,
    String Function(String ram)? notEnoughRam,
    String Function(String required, String available)? notEnoughMemory,
    String Function(String required, String available)? notEnoughDisk,
    String? integrityError,
    String? notAModelFileError,
    String? fileMissingError,
    String? cannotVerifyError,
    String? cannotSaveError,
    String? cannotStartError,
    String? cannotResumeError,
    String? downloadFailedError,
    String? notFoundError,
    String Function(int? status)? httpStatusError,
    String? connectionError,
    String? diskFullError,
    String? fileSystemError,
    String? webPageError,
  }) => ModelSetupStrings(
    consentTitle: consentTitle ?? this.consentTitle,
    sizeApprox: sizeApprox ?? this.sizeApprox,
    consentBody: consentBody ?? this.consentBody,
    downloadButton: downloadButton ?? this.downloadButton,
    retryButton: retryButton ?? this.retryButton,
    chooseOther: chooseOther ?? this.chooseOther,
    recommendedForDevice: recommendedForDevice ?? this.recommendedForDevice,
    progressDownloading: progressDownloading ?? this.progressDownloading,
    progressVerifying: progressVerifying ?? this.progressVerifying,
    progressWaitingForWifi: progressWaitingForWifi ?? this.progressWaitingForWifi,
    progressWaitingForNetwork: progressWaitingForNetwork ?? this.progressWaitingForNetwork,
    progressPaused: progressPaused ?? this.progressPaused,
    progressFailed: progressFailed ?? this.progressFailed,
    progressSemanticsLabel: progressSemanticsLabel ?? this.progressSemanticsLabel,
    downloadHint: downloadHint ?? this.downloadHint,
    pause: pause ?? this.pause,
    resume: resume ?? this.resume,
    useCellular: useCellular ?? this.useCellular,
    cancel: cancel ?? this.cancel,
    cellularTitle: cellularTitle ?? this.cellularTitle,
    cellularBody: cellularBody ?? this.cellularBody,
    cellularAction: cellularAction ?? this.cellularAction,
    libraryUnavailable: libraryUnavailable ?? this.libraryUnavailable,
    libraryTitle: libraryTitle ?? this.libraryTitle,
    libraryNone: libraryNone ?? this.libraryNone,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    catalogOnline: catalogOnline ?? this.catalogOnline,
    catalogBundled: catalogBundled ?? this.catalogBundled,
    tileNotDownloaded: tileNotDownloaded ?? this.tileNotDownloaded,
    tileWaitingForNetwork: tileWaitingForNetwork ?? this.tileWaitingForNetwork,
    tileQueued: tileQueued ?? this.tileQueued,
    tileDownloading: tileDownloading ?? this.tileDownloading,
    tilePaused: tilePaused ?? this.tilePaused,
    tileWaitingForWifi: tileWaitingForWifi ?? this.tileWaitingForWifi,
    tileVerifying: tileVerifying ?? this.tileVerifying,
    tileInUse: tileInUse ?? this.tileInUse,
    tileReady: tileReady ?? this.tileReady,
    tileFailed: tileFailed ?? this.tileFailed,
    actionDownload: actionDownload ?? this.actionDownload,
    actionPause: actionPause ?? this.actionPause,
    actionResume: actionResume ?? this.actionResume,
    actionCancel: actionCancel ?? this.actionCancel,
    actionUseCellular: actionUseCellular ?? this.actionUseCellular,
    actionUse: actionUse ?? this.actionUse,
    actionDelete: actionDelete ?? this.actionDelete,
    recommendedBadge: recommendedBadge ?? this.recommendedBadge,
    deleteTitle: deleteTitle ?? this.deleteTitle,
    deleteBody: deleteBody ?? this.deleteBody,
    deleteAction: deleteAction ?? this.deleteAction,
    dialogCancel: dialogCancel ?? this.dialogCancel,
    dialogOk: dialogOk ?? this.dialogOk,
    noneOfferedTitle: noneOfferedTitle ?? this.noneOfferedTitle,
    noneOfferedSubtitle: noneOfferedSubtitle ?? this.noneOfferedSubtitle,
    downloadStartFailed: downloadStartFailed ?? this.downloadStartFailed,
    notOffered: notOffered ?? this.notOffered,
    notEnoughRam: notEnoughRam ?? this.notEnoughRam,
    notEnoughMemory: notEnoughMemory ?? this.notEnoughMemory,
    notEnoughDisk: notEnoughDisk ?? this.notEnoughDisk,
    integrityError: integrityError ?? this.integrityError,
    notAModelFileError: notAModelFileError ?? this.notAModelFileError,
    fileMissingError: fileMissingError ?? this.fileMissingError,
    cannotVerifyError: cannotVerifyError ?? this.cannotVerifyError,
    cannotSaveError: cannotSaveError ?? this.cannotSaveError,
    cannotStartError: cannotStartError ?? this.cannotStartError,
    cannotResumeError: cannotResumeError ?? this.cannotResumeError,
    downloadFailedError: downloadFailedError ?? this.downloadFailedError,
    notFoundError: notFoundError ?? this.notFoundError,
    httpStatusError: httpStatusError ?? this.httpStatusError,
    connectionError: connectionError ?? this.connectionError,
    diskFullError: diskFullError ?? this.diskFullError,
    fileSystemError: fileSystemError ?? this.fileSystemError,
    webPageError: webPageError ?? this.webPageError,
  );
}

String _approx(String size) => '≈ $size';

String _itConsentTitle(String assistant) => 'Avvia la sperimentazione di $assistant';

String _itConsentBody(String assistant) =>
    'Per provare $assistant scarica il suo modello di intelligenza artificiale. Funziona sul tuo dispositivo, '
    'quindi si scarica una volta sola: un file di qualche GB, meglio sotto Wi-Fi. Poi risponde anche senza '
    'connessione.';

String _itCellularBody(String size) => 'Il modello pesa $size: scaricarlo senza Wi-Fi consuma il tuo traffico dati.';

String _itTileDownloading(String percent) => 'Scarico… $percent';

String _itTilePaused(String percent) => 'In pausa · $percent';

String _itDownloadStartFailed(Object error) => 'Non riesco ad avviare il download: $error';

String _itNotEnoughRam(String ram) => 'Serve un telefono con almeno $ram di memoria.';

String _itNotEnoughMemory(String required, String available) =>
    'Memoria disponibile insufficiente: servono $required, '
    'disponibili $available.';

String _itNotEnoughDisk(String required, String available) =>
    'Spazio libero insufficiente: servono $required, '
    'disponibili $available.';

String _itHttpStatus(int? status) => 'Il server ha risposto con un errore ($status): riprova più tardi.';

String _enConsentTitle(String assistant) => 'Start trying $assistant';

String _enConsentBody(String assistant) =>
    'To try $assistant, download its AI model. It runs on your device, so it downloads only once: a file of a few '
    'GB, best on Wi-Fi. Then it answers even offline.';

String _enCellularBody(String size) => 'The model is $size: downloading it without Wi-Fi uses your mobile data.';

String _enTileDownloading(String percent) => 'Downloading… $percent';

String _enTilePaused(String percent) => 'Paused · $percent';

String _enDownloadStartFailed(Object error) => 'The download could not start: $error';

String _enNotEnoughRam(String ram) => 'This needs a phone with at least $ram of memory.';

String _enNotEnoughMemory(String required, String available) =>
    'Not enough memory available: $required needed, $available available.';

String _enNotEnoughDisk(String required, String available) =>
    'Not enough free space: $required needed, $available available.';

String _enHttpStatus(int? status) => 'The server answered with an error ($status): try again later.';
