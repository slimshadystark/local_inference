/// Internal: the column of a conversation, where large text cannot squeeze the messages out.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// What a part of [ConversationColumn] is.
enum ConversationPart {
  /// Keeps its height (a header, the composer).
  fixed,

  /// Keeps its height unless the messages would get less than their share; then it gives way (it scrolls).
  yielding,

  /// The messages: the height that is left.
  messages,
}

/// Marks [child] as a [part] of a [ConversationColumn].
class ConversationSlot extends ParentDataWidget<ConversationSlotData> {
  const ConversationSlot({super.key, required this.part, required super.child});

  final ConversationPart part;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as ConversationSlotData;
    if (data.part == part) return;
    data.part = part;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => ConversationColumn;
}

/// A column of [ConversationSlot]s, top to bottom, filling its (bounded) height. The fixed and yielding parts keep
/// their own heights and the messages get the rest, as in a Column with the messages Expanded; but when the messages
/// would get less than [minMessagesShare] of the height (large text on a small screen), the yielding parts shrink
/// in proportion to their heights, so they must scroll.
class ConversationColumn extends MultiChildRenderObjectWidget {
  const ConversationColumn({super.key, this.minMessagesShare = 0.3, required super.children});

  final double minMessagesShare;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderConversationColumn(minMessagesShare);

  @override
  void updateRenderObject(BuildContext context, RenderConversationColumn renderObject) =>
      renderObject.minMessagesShare = minMessagesShare;
}

/// Where a [ConversationColumn] keeps a part's role and offset.
class ConversationSlotData extends ContainerBoxParentData<RenderBox> {
  ConversationPart part = ConversationPart.fixed;
}

/// The render object of [ConversationColumn].
class RenderConversationColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, ConversationSlotData>,
        RenderBoxContainerDefaultsMixin<RenderBox, ConversationSlotData> {
  RenderConversationColumn(this._minMessagesShare);

  double _minMessagesShare;

  set minMessagesShare(double value) {
    if (value == _minMessagesShare) return;
    _minMessagesShare = value;
    markNeedsLayout();
  }

  bool _overflows = false;
  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ConversationSlotData) child.parentData = ConversationSlotData();
  }

  static ConversationPart _partOf(RenderBox child) => (child.parentData! as ConversationSlotData).part;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    assert(
      constraints.hasBoundedHeight,
      'A chat view needs a bounded height (in a Scaffold, an Expanded, a SizedBox).',
    );
    final size = constraints.biggest;
    BoxConstraints upTo(double height) =>
        BoxConstraints(minWidth: size.width, maxWidth: size.width, maxHeight: math.max(0, height));

    var fixed = 0.0;
    var yielding = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      switch (_partOf(child)) {
        case ConversationPart.messages:
          break;
        case ConversationPart.fixed:
          child.layout(upTo(size.height), parentUsesSize: true);
          fixed += child.size.height;
        case ConversationPart.yielding:
          child.layout(upTo(size.height), parentUsesSize: true);
          yielding += child.size.height;
      }
    }
    // The room the yielding parts may take while the messages keep their share.
    final room = math.max(0.0, size.height * (1 - _minMessagesShare) - fixed);
    if (yielding > room) {
      final ratio = room / yielding;
      yielding = 0;
      for (var child = firstChild; child != null; child = childAfter(child)) {
        if (_partOf(child) != ConversationPart.yielding) continue;
        child.layout(upTo(child.size.height * ratio), parentUsesSize: true);
        yielding += child.size.height;
      }
    }
    final left = math.max(0.0, size.height - fixed - yielding);
    var y = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (_partOf(child) == ConversationPart.messages) {
        child.layout(BoxConstraints.tightFor(width: size.width, height: left), parentUsesSize: true);
      }
      (child.parentData! as ConversationSlotData).offset = Offset(0, y);
      y += child.size.height;
    }
    _overflows = y > size.height;
    this.size = size;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_overflows) {
      _clip.layer = null;
      defaultPaint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      oldLayer: _clip.layer,
    );
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) => _overflows ? Offset.zero & size : null;

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
