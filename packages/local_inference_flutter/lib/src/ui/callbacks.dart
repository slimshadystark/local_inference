/// What the chat UI asks the host: the UI's own events only. Turns, phases, models, conversations and analytics
/// come from the long-lived objects (`AssistantController.events` and `.analytics`,
/// `ModelSetupController.analytics`), so they arrive whether a chat view is on screen or not.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../adapters/screen_request_dispatcher.dart';
import 'compliance/report.dart';

/// The chat UI's callbacks.
@immutable
final class ChatCallbacks {
  const ChatCallbacks({
    this.onScreenRequest,
    this.onStaleScreenRequest,
    this.onLinkTap,
    this.onReport,
    this.onCopy,
    this.beforeSend,
    this.onDisclosureDismissed,
  });

  /// Opens the screen a reply asks for (`ScreenRequest`): after a reply, 600 ms later and once the turn ended, and
  /// from a reply's chip. Without it, screen requests are ignored and no chip shows.
  final ScreenRequestHandler? onScreenRequest;

  /// A chip whose list item changed meanwhile was tapped; null shows the chat's note
  /// (`ChatStrings.staleScreenRequest`) in a SnackBar.
  final StaleScreenRequestHandler? onStaleScreenRequest;

  /// Makes http(s) links in replies tappable.
  final void Function(Uri uri)? onLinkTap;

  /// Receives a reported reply. With it, replies can be reported (`ChatFeatures.reportAffordance`).
  final ReportHandler? onReport;

  /// The user copied [text] from a message.
  final void Function(String text)? onCopy;

  /// Runs before a message is sent; false keeps it in the composer, unsent.
  final FutureOr<bool> Function(String text)? beforeSend;

  /// The user closed the dismissible AI disclosure; the host may remember it (and pass `AiDisclosureMode.none`).
  final VoidCallback? onDisclosureDismissed;
}
