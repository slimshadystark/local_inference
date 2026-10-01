/// Internal: the default confirmation dialog of the model setup (not exported).
library;

import 'package:flutter/material.dart';

import '../builders.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// Shows [request] with [presenter], else as an AlertDialog: a title, a message, the cancel button and the action
/// (or one OK button). True when the user confirms.
Future<bool> showConfirmDialog(
  BuildContext context,
  ConfirmDialogRequest request, {
  ConfirmDialogPresenter? presenter,
}) async {
  if (presenter != null) return presenter(context, request);
  final strings = LocalInferenceStrings.of(context).setup;
  final style = LocalInferenceStyle.of(context);
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(request.title),
      content: Text(request.message),
      actions: [
        if (request.action != null)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(strings.dialogCancel)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: request.destructive ? TextButton.styleFrom(foregroundColor: style.error) : null,
          child: Text(request.action ?? strings.dialogOk),
        ),
      ],
    ),
  );
  return answer ?? false;
}
