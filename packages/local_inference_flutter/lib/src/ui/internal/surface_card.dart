/// Internal: the rounded card of the model list (not exported, so no host name collides with it).
library;

import 'package:flutter/material.dart';

import '../theme/local_inference_theme.dart';

/// A rounded card in the style's surface color.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(12), this.margin});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final radius = BorderRadius.circular(style.cardRadius);
    return Container(
      margin: margin,
      child: Material(
        color: style.surface,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
