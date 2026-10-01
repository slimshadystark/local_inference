/// The AI disclosure (EU AI Act, art. 50(1)) and the report sheet (Google Play's AI-content policy).
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../features.dart';
import '../internal/icon_action.dart';
import '../internal/resolved.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';
import 'report.dart';

/// A banner saying that the replies come from an AI on the device and may be wrong; with [onDismiss], a close
/// button.
class AiDisclosureBanner extends StatelessWidget {
  const AiDisclosureBanner({super.key = LocalInferenceKeys.disclosureBanner, this.text, this.onDismiss});

  /// The text; null uses [ChatStrings.disclosure].
  final String? text;

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final onDismiss = this.onDismiss;
    return Material(
      color: style.disclosureBackground,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(16, 8, onDismiss == null ? 16 : 4, 8),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(Icons.auto_awesome_outlined, size: 18, color: style.onDisclosure)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text ?? strings.chat.disclosure, style: TextStyle(fontSize: 13, color: style.onDisclosure)),
            ),
            if (onDismiss != null)
              labelledIconButton(
                label: strings.a11y.dismiss,
                tooltips: features.tooltips,
                build: (tooltip) => IconButton(
                  key: LocalInferenceKeys.disclosureDismiss,
                  tooltip: tooltip,
                  icon: const Icon(Icons.close),
                  iconSize: 18,
                  color: style.onDisclosure,
                  onPressed: onDismiss,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks why [message] is reported (a reason and an optional comment) in a bottom sheet; the report, or null when
/// the user closes the sheet.
Future<ReportRequest?> showReportSheet(
  BuildContext context, {
  required AssistantController controller,
  required ChatItem message,
}) async {
  final style = LocalInferenceStyle.of(context);
  final answer = await showModalBottomSheet<(ReportReason, String)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: style.background,
    builder: (sheet) => ResolvedLook.carry(context, const ReportSheet()),
  );
  if (answer == null) return null;
  final state = controller.assistant.state;
  return ReportRequest.of(state, state.item(message.id) ?? message, reason: answer.$1, comment: answer.$2);
}

/// The report sheet's content: the reasons as chips, a comment field, cancel and send. It pops with the reason and
/// the comment.
class ReportSheet extends StatefulWidget {
  const ReportSheet({super.key = LocalInferenceKeys.reportSheet});

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  final TextEditingController _comment = TextEditingController();
  ReportReason? _reason;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context).chat;
    final reason = _reason;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.reportTitle, style: style.panelTitleStyle.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(strings.reportQuestion, style: style.panelBodyStyle),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in ReportReason.values)
                  ChoiceChip(
                    key: LocalInferenceKeys.reportReason(option),
                    label: Text(strings.reportReason(option)),
                    selected: option == reason,
                    onSelected: (_) => setState(() => _reason = option),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: LocalInferenceKeys.reportComment,
              controller: _comment,
              minLines: 1,
              maxLines: 4,
              style: style.composerStyle,
              decoration: InputDecoration(hintText: strings.reportCommentHint, hintStyle: style.hintStyle),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  style: style.textButton,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(strings.reportCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: LocalInferenceKeys.reportSend,
                  style: FilledButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
                  onPressed: reason == null ? null : () => Navigator.of(context).pop((reason, _comment.text)),
                  child: Text(strings.reportSend),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
