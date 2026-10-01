/// Opening the screens that replies ask for, at the right moment.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:local_inference/local_inference.dart';

import 'analytics.dart';
import 'assistant_controller.dart';

/// Who asked to open a screen.
enum ScreenRequestOrigin {
  /// The assistant, after a reply.
  assistant,

  /// The user, from a reply's chip.
  chip,
}

/// What happens to the assistant's request when the chat is not the visible page at the moment it would open.
enum HiddenChatScreenRequest {
  /// It is dropped: the user went elsewhere (the default).
  drop,

  /// It waits until the chat is visible again (the latest one only).
  deferUntilVisible,
}

/// One screen to open: the request, who asked, and the reply it came with.
@immutable
final class ScreenRequestDispatch {
  const ScreenRequestDispatch({required this.bound, required this.origin, this.message});

  /// The request with what its item number named.
  final BoundScreenRequest bound;
  final ScreenRequestOrigin origin;

  /// The reply that asked for it, when known.
  final ChatItem? message;

  /// The host's request (cast it to its own type).
  ScreenRequest get request => bound.request;

  @override
  String toString() => 'ScreenRequestDispatch(${origin.name}, ${request.label})';
}

/// Opens [dispatch]'s screen from [context] (a push onto the chat's Navigator, a tab switch).
typedef ScreenRequestHandler = FutureOr<void> Function(BuildContext context, ScreenRequestDispatch dispatch);

/// A chip's item changed meanwhile, so nothing opened; tell the user.
typedef StaleScreenRequestHandler = void Function(BuildContext context, ScreenRequestDispatch dispatch);

/// When the assistant's screen requests open.
@immutable
final class ScreenRequestPolicy {
  const ScreenRequestPolicy({
    this.delay = const Duration(milliseconds: 600),
    this.deferWhileBusy = true,
    this.whenHidden = HiddenChatScreenRequest.drop,
    this.isVisible,
    this.expireAfter,
  });

  /// The pause after the reply, so the user reads it before the screen opens.
  final Duration delay;

  /// While a turn runs the request waits for its end (only the latest one waits): what the user does on a screen
  /// joins the conversation, which must not happen in the middle of a reply.
  final bool deferWhileBusy;

  final HiddenChatScreenRequest whenHidden;

  /// Whether the chat is the visible page; null: its route is the current one (`ModalRoute.isCurrent`, true without
  /// a route). A tab host passes whether the chat's tab is selected; a chat view asks again whenever it rebuilds (a
  /// host that switches tabs with setState rebuilds it), so a request waiting for it opens then.
  final bool Function(BuildContext context)? isVisible;

  /// A request that waited longer than this is dropped; null never drops one for its age.
  final Duration? expireAfter;

  @override
  bool operator ==(Object other) =>
      other is ScreenRequestPolicy &&
      other.delay == delay &&
      other.deferWhileBusy == deferWhileBusy &&
      other.whenHidden == whenHidden &&
      other.isVisible == isVisible &&
      other.expireAfter == expireAfter;

  @override
  int get hashCode => Object.hash(delay, deferWhileBusy, whenHidden, isVisible, expireAfter);
}

/// Opens the screens the assistant asks for ([ScreenRequestedEvent]) after [ScreenRequestPolicy.delay], once the turn
/// ended and only while the chat is visible, and the screens of the replies' chips, unless their item changed.
///
/// A chat view makes one when `ChatCallbacks.onScreenRequest` is set; a custom UI makes its own, [attach]es it under
/// the chat's route and calls [openFromChip].
final class ScreenRequestDispatcher {
  ScreenRequestDispatcher({
    required this.controller,
    required this.onScreenRequest,
    this.policy = const ScreenRequestPolicy(),
    this.onStale,
  }) {
    _subscription = controller.events.listen(_onEvent);
    controller.phase.addListener(_onPhase);
  }

  final AssistantController controller;
  final ScreenRequestHandler onScreenRequest;

  /// When requests open; a chat view gives it the policy of its latest build, and the requests already waiting stay.
  ScreenRequestPolicy policy;

  /// Tells the user that a chip's item changed; null does nothing.
  final StaleScreenRequestHandler? onStale;

  late final StreamSubscription<AssistantEvent> _subscription;
  final Set<Timer> _timers = {};
  BuildContext? _context;
  ScreenRequestDispatch? _waitingForTurn;
  DateTime? _waitingSince;
  ScreenRequestDispatch? _waitingForView;
  DateTime? _hiddenSince;
  bool _disposed = false;

  /// Uses [context] (under the chat's route) to check visibility and to open screens; call it again when the chat
  /// may have become visible (`didChangeDependencies` for a route, a rebuild for a tab): a request waiting for the
  /// chat opens after the current frame (a build cannot push a route).
  void attach(BuildContext context) {
    _context = context;
    final waiting = _waitingForView;
    if (waiting == null || !_isVisible(context)) return;
    _waitingForView = null;
    if (_expired(_hiddenSince)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final context = _context;
      if (_disposed || context == null || !context.mounted) return;
      _open(context, waiting);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Stops using [context].
  void detach(BuildContext context) {
    if (identical(_context, context)) _context = null;
  }

  /// A tap on [message]'s chip: nothing while a turn runs; the stale note when the item its number named changed;
  /// else the screen opens. True when it opened.
  bool openFromChip(BuildContext context, ChatItem message) {
    final bound = message.screenRequest;
    if (_disposed || bound == null || controller.phase.value == AssistantPhase.busy) return false;
    final dispatch = ScreenRequestDispatch(bound: bound, origin: ScreenRequestOrigin.chip, message: message);
    if (!controller.isScreenRequestCurrent(bound)) {
      controller.track(StaleScreenRequestBlockedEvent());
      onStale?.call(context, dispatch);
      return false;
    }
    _open(context, dispatch);
    return true;
  }

  void _onEvent(AssistantEvent event) {
    if (event is! ScreenRequestedEvent || _disposed) return;
    final dispatch = ScreenRequestDispatch(
      bound: event.request,
      origin: ScreenRequestOrigin.assistant,
      message: controller.state.value.item(event.itemId),
    );
    late final Timer timer;
    timer = Timer(policy.delay, () {
      _timers.remove(timer);
      _arrived(dispatch);
    });
    _timers.add(timer);
  }

  void _arrived(ScreenRequestDispatch dispatch) {
    if (_disposed) return;
    if (policy.deferWhileBusy && controller.phase.value == AssistantPhase.busy) {
      _waitingForTurn = dispatch;
      _waitingSince = DateTime.now();
      return;
    }
    _deliver(dispatch);
  }

  void _onPhase() {
    final waiting = _waitingForTurn;
    if (_disposed || waiting == null || controller.phase.value == AssistantPhase.busy) return;
    _waitingForTurn = null;
    if (_expired(_waitingSince)) return;
    // Not inside the assistant's notification: the handler may act on the assistant.
    scheduleMicrotask(() {
      if (!_disposed) _deliver(waiting);
    });
  }

  void _deliver(ScreenRequestDispatch dispatch) {
    final context = _context;
    if (context != null && context.mounted && _isVisible(context)) {
      _open(context, dispatch);
    } else if (policy.whenHidden == HiddenChatScreenRequest.deferUntilVisible) {
      _waitingForView = dispatch;
      _hiddenSince = DateTime.now();
    }
  }

  bool _isVisible(BuildContext context) =>
      policy.isVisible?.call(context) ?? (ModalRoute.of(context)?.isCurrent ?? true);

  bool _expired(DateTime? since) {
    final limit = policy.expireAfter;
    return limit != null && since != null && DateTime.now().difference(since) > limit;
  }

  void _open(BuildContext context, ScreenRequestDispatch dispatch) {
    controller.track(ScreenRequestOpenedEvent(origin: dispatch.origin));
    final opening = onScreenRequest(context, dispatch);
    if (opening is Future<void>) unawaited(opening);
  }

  /// Cancels the waiting requests and stops listening.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_subscription.cancel());
    controller.phase.removeListener(_onPhase);
    _context = null;
  }
}
