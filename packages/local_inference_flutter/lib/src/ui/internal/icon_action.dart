/// Internal: an icon button whose label is a tooltip, or only a semantic label when tooltips are off.
library;

import 'package:flutter/material.dart';

/// An [IconButton] (or the one [build] returns) labelled [label]: as a tooltip when [tooltips], else for screen
/// readers only, on the button's own node (the one that can be tapped).
Widget labelledIconButton({
  required String label,
  required bool tooltips,
  required IconButton Function(String? tooltip) build,
}) {
  final button = build(tooltips ? label : null);
  return tooltips
      ? button
      : MergeSemantics(
          child: Semantics(label: label, child: button),
        );
}
