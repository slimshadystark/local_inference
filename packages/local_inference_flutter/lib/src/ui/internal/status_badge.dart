/// Internal: a pill-shaped label (not exported).
library;

import 'package:flutter/material.dart';

import '../theme/local_inference_theme.dart';

/// A pill with [label] on [color] (default: the accent).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color ?? style.accent, borderRadius: BorderRadius.circular(24)),
      child: Text(label, style: TextStyle(color: style.onAccent, fontSize: 12)),
    );
  }
}
