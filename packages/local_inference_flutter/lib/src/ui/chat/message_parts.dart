/// The parts under a reply's text: the chip that opens its screen again, and the technical details.
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// An outlined chip in the accent color that opens [request]'s screen again; disabled without [onOpen].
class ScreenRequestChip extends StatelessWidget {
  const ScreenRequestChip({super.key, required this.request, this.onOpen});

  final BoundScreenRequest request;

  /// Opens the screen; null disables the chip (during a turn).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    // Merged, so the hint is on the chip's own node, not on the message around it.
    return MergeSemantics(
      child: Semantics(
        hint: strings.a11y.screenChipHint,
        child: ActionChip(
          avatar: Icon(Icons.open_in_new, size: 16, color: style.accent),
          label: Text(request.request.label, style: TextStyle(color: style.accent)),
          side: BorderSide(color: style.accent),
          backgroundColor: style.background,
          onPressed: onOpen,
        ),
      ),
    );
  }
}

/// A reply's technical details, verbatim: the timing line and raw output of each generation and the `[tool]`,
/// `[validation]` and `[guard]` lines, after the guarded prefix when a guard replaced the answer.
class MessageDetails extends StatelessWidget {
  const MessageDetails({super.key, required this.message});

  final ChatItem message;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final details = message.details?.trim() ?? '';
    return Text('${message.guarded ? strings.chat.detailsGuardedPrefix : ''}$details', style: style.detailsStyle);
  }
}
