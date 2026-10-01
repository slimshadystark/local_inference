/// Keys of the UI kit's widgets, for tests and for hosts that drive the UI.
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

import 'compliance/report.dart';

/// The keys the UI kit puts on its widgets: `find.byKey(LocalInferenceKeys.sendButton)`.
abstract final class LocalInferenceKeys {
  static const composerField = ValueKey<String>('local_inference.composerField');
  static const sendButton = ValueKey<String>('local_inference.sendButton');
  static const stopButton = ValueKey<String>('local_inference.stopButton');
  static const newConversation = ValueKey<String>('local_inference.newConversation');
  static const titleArea = ValueKey<String>('local_inference.titleArea');
  static const messageList = ValueKey<String>('local_inference.messageList');
  static const welcome = ValueKey<String>('local_inference.welcome');
  static const disclosureBanner = ValueKey<String>('local_inference.disclosureBanner');
  static const disclosureDismiss = ValueKey<String>('local_inference.disclosureDismiss');
  static const jumpToLatest = ValueKey<String>('local_inference.jumpToLatest');
  static const statusPanel = ValueKey<String>('local_inference.statusPanel');
  static const retryLoad = ValueKey<String>('local_inference.retryLoad');
  static const loadModel = ValueKey<String>('local_inference.loadModel');
  static const setupDownload = ValueKey<String>('local_inference.setupDownload');
  static const setupChooseOther = ValueKey<String>('local_inference.setupChooseOther');
  static const progressPause = ValueKey<String>('local_inference.progressPause');
  static const progressResume = ValueKey<String>('local_inference.progressResume');
  static const progressCancel = ValueKey<String>('local_inference.progressCancel');
  static const progressUseCellular = ValueKey<String>('local_inference.progressUseCellular');
  static const wifiOnlySwitch = ValueKey<String>('local_inference.wifiOnlySwitch');
  static const reportSheet = ValueKey<String>('local_inference.reportSheet');
  static const reportComment = ValueKey<String>('local_inference.reportComment');
  static const reportSend = ValueKey<String>('local_inference.reportSend');

  /// The message of item [id].
  static ValueKey<String> message(int id) => ValueKey('local_inference.message.$id');

  /// The suggestion chip at [index].
  static ValueKey<String> suggestion(int index) => ValueKey('local_inference.suggestion.$index');

  /// The confirmation button of [kind].
  static ValueKey<String> confirmAction(ChatActionKind kind) => ValueKey('local_inference.confirmAction.${kind.name}');

  /// The screen chip of item [id].
  static ValueKey<String> screenChip(int id) => ValueKey('local_inference.screenChip.$id');

  /// The report button of item [id].
  static ValueKey<String> reportAction(int id) => ValueKey('local_inference.reportAction.$id');

  /// The choice of [reason] in the report sheet.
  static ValueKey<String> reportReason(ReportReason reason) => ValueKey('local_inference.reportReason.${reason.name}');

  /// The model list's card of model [id], and its use and delete buttons.
  static ValueKey<String> libraryTile(String id) => ValueKey('local_inference.libraryTile.$id');
  static ValueKey<String> libraryUse(String id) => ValueKey('local_inference.libraryUse.$id');
  static ValueKey<String> libraryDelete(String id) => ValueKey('local_inference.libraryDelete.$id');

  /// The model picker's row of model [id].
  static ValueKey<String> pickerEntry(String id) => ValueKey('local_inference.pickerEntry.$id');
}
