/// What a reply shows before its text: "Thinking…" and a running tool's label. Both are live regions.
library;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// "Thinking…" with a light sweeping across it; still text when animations are off. A live region reads
/// [A11yStrings.thinking].
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key, this.text});

  /// The text; null uses [ChatStrings.thinking].
  final String? text;

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator> with SingleTickerProviderStateMixin {
  AnimationController? _sweep;

  @override
  void dispose() {
    _sweep?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final label = Text(widget.text ?? strings.chat.thinking, style: style.thinkingStyle);
    final Widget shown;
    if (MediaQuery.disableAnimationsOf(context)) {
      _sweep?.stop();
      shown = label;
    } else {
      final sweep = _sweep ??= AnimationController(vsync: this);
      if (sweep.duration != style.shimmerPeriod || !sweep.isAnimating) {
        sweep
          ..duration = style.shimmerPeriod
          ..repeat();
      }
      final base = style.shimmerBase;
      final highlight = style.shimmerHighlight;
      shown = AnimatedBuilder(
        animation: sweep,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) {
            final x = sweep.value * 3 - 1;
            return LinearGradient(
              colors: [base, highlight, base],
              stops: [(x - 0.3).clamp(0.0, 1.0), x.clamp(0.0, 1.0), (x + 0.3).clamp(0.0, 1.0)],
            ).createShader(rect);
          },
          child: child,
        ),
        child: label,
      );
    }
    return Semantics(
      liveRegion: true,
      label: strings.a11y.thinking,
      child: ExcludeSemantics(child: shown),
    );
  }
}

/// A running tool's label after a small spinner, dimmed. A live region reads the label without its emoji.
class ToolStatusIndicator extends StatelessWidget {
  const ToolStatusIndicator({super.key, required this.label});

  /// The tool's status label, as the assistant's config writes it (it may hold emoji).
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    return Semantics(
      liveRegion: true,
      label: strings.a11y.toolStatus(label),
      child: ExcludeSemantics(
        child: Opacity(
          opacity: 0.7,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: style.statusStyle.color ?? style.onAssistant,
                  backgroundColor: Colors.transparent,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(label, style: style.statusStyle)),
            ],
          ),
        ),
      ),
    );
  }
}
