/// Scrolling of a chat: follow new text only while the user is at the bottom.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The scroll controller of a chat's message list. While the list is at the bottom (within [stickThreshold] of it)
/// new text keeps it there: a post-frame jump as a reply grows, a short animation for a new message. When the user
/// scrolls toward older messages, following stops at once and nothing moves: the text they read stays put and
/// [hasUnseen] turns true until they come back down, by hand or with [jumpToLatest]. Content that shrinks under them
/// down to its end (a new conversation) is followed again.
///
/// [stickThreshold] `double.infinity` always follows new text (the behavior before the UI kit).
final class ChatScrollController extends ScrollController {
  ChatScrollController({
    this.stickThreshold = 48,
    this.structuralAnimation = const Duration(milliseconds: 180),
    super.debugLabel,
  });

  /// How close to the bottom counts as at the bottom, in logical pixels.
  final double stickThreshold;

  /// The animation to a new message; zero jumps.
  final Duration structuralAnimation;

  final ValueNotifier<bool> _atBottom = ValueNotifier(true);
  final ValueNotifier<bool> _hasUnseen = ValueNotifier(false);

  /// Scrolls of this controller in flight (a later one ends an earlier one's animation).
  int _moving = 0;

  /// Counts the scrolls to the bottom: an earlier one whose animation a later one ended leaves the decisions to it.
  int _runs = 0;
  bool _scheduled = false;
  bool _animateNext = false;
  int _attempts = 0;

  bool get _autoScrolling => _moving > 0;

  /// Whether the list is at the bottom and follows new text.
  ValueListenable<bool> get atBottom => _atBottom;

  /// Whether new text arrived below while the user was reading further up.
  ValueListenable<bool> get hasUnseen => _hasUnseen;

  /// Whether new text is followed at the bottom; false never scrolls by itself (a chat whose auto-scroll is off).
  bool following = true;

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    position.addListener(_onScroll);
  }

  @override
  void detach(ScrollPosition position) {
    position.removeListener(_onScroll);
    super.detach(position);
  }

  void _onScroll() {
    if (_autoScrolling || !hasClients) return;
    // The user moving toward older messages reads back: stop following at once, even within the threshold, so a
    // slow drag is not pulled back to the bottom by the next token.
    if (stickThreshold.isFinite && position.userScrollDirection == ScrollDirection.forward) {
      _atBottom.value = false;
      return;
    }
    final bottom = position.extentAfter <= stickThreshold;
    _atBottom.value = bottom;
    if (bottom) _hasUnseen.value = false;
  }

  /// The chat changed: a reply grew, or messages were added or removed ([structural]). At the bottom the list
  /// follows; else [hasUnseen] turns true.
  void contentChanged({bool structural = false}) {
    if (following && _atBottom.value) {
      _animateNext |= structural;
      _attempts = 0;
      _schedule();
      return;
    }
    _hasUnseen.value = true;
    if (_atBottom.value) {
      // Not following: the new text may still fit on screen.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (hasClients && position.extentAfter <= stickThreshold) _hasUnseen.value = false;
      });
    }
  }

  /// The list's size changed (the keyboard, a rotation, lazy extents measured): stay at the bottom when there. Content
  /// that shrank under a reader who is not scrolling (the list clamped to its new end) is at the bottom again.
  void metricsChanged() {
    if (!hasClients || _autoScrolling) return;
    if (_atBottom.value) {
      if (following) _schedule();
      return;
    }
    if (position.userScrollDirection == ScrollDirection.idle && position.extentAfter <= _end) {
      _atBottom.value = true;
      _hasUnseen.value = false;
    }
  }

  /// Closer to the end than this counts as the end itself.
  static const double _end = 0.5;

  /// Scrolls to the newest message.
  Future<void> jumpToLatest({bool animate = true}) async {
    _atBottom.value = true;
    _hasUnseen.value = false;
    _animateNext = animate;
    _attempts = 0;
    await _stick();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      unawaited(_stick());
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Future<void> _stick() async {
    if (!hasClients || !_atBottom.value) return;
    final run = ++_runs;
    final animate = _animateNext && structuralAnimation > Duration.zero;
    _animateNext = false;
    final target = position.maxScrollExtent;
    if (position.pixels < target) {
      _moving++;
      try {
        if (animate) {
          await animateTo(target, duration: structuralAnimation, curve: Curves.easeOut);
        } else {
          jumpTo(target);
        }
      } finally {
        _moving--;
      }
      if (run != _runs || !hasClients) return;
      // Stopped short of its target: the user took the list (a touch, a drag), which stays where they took it.
      if ((position.pixels - target).abs() > _end) {
        _onScroll();
        return;
      }
    }
    // A lazy list's extent is an estimate until its last items are laid out: the target was the estimated end, so go
    // on until the true end.
    if (hasClients && _atBottom.value && position.extentAfter > _end && _attempts++ < 12) _schedule();
  }

  @override
  void dispose() {
    _atBottom.dispose();
    _hasUnseen.dispose();
    super.dispose();
  }
}
