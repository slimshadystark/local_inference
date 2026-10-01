/// Screens a tool result asks the host to open.
library;

import 'package:meta/meta.dart';

import 'lists.dart';
import 'tool_result.dart';

/// Something the host should open (a screen, a page) after a tool call. The host's own subclass carries what it
/// needs; the assistant reads only [label] and [itemRef].
abstract class ScreenRequest {
  const ScreenRequest();

  /// A short label for a chip that opens it again ("Open order A-17").
  String get label;

  /// The list item the screen shows by number; non-null makes opening it again depend on that number still naming
  /// the same item.
  ItemRef? get itemRef => null;
}

/// The screen an executed call asks for, or null. The assistant asks it after the calls of the model, of the user's
/// yes to a question and of an offer; never after a follow-up, a host's call or a recorded action.
typedef ScreenRequestMapper = ScreenRequest? Function(ToolOutcome outcome);

/// A screen request with what its item number named when the reply was written.
@immutable
final class BoundScreenRequest {
  const BoundScreenRequest(this.request, {this.binding});

  /// The request.
  final ScreenRequest request;

  /// What [ScreenRequest.itemRef] named then; null when the request names no item.
  final ItemBinding? binding;

  @override
  String toString() => 'BoundScreenRequest(${request.label}${binding == null ? '' : ', $binding'})';
}

/// Turns the host's screen requests into JSON and back, for conversation snapshots.
abstract interface class ScreenRequestCodec {
  /// [request] as JSON.
  Map<String, Object?> encode(ScreenRequest request);

  /// The request [json] encodes; null when it cannot be read.
  ScreenRequest? decode(Map<String, Object?> json);
}

/// A screen request as a conversation snapshot keeps it: its label, its item and, when a codec was given, the codec's
/// JSON. A snapshot restored without a codec (or one that cannot decode it) keeps requests of this type.
@immutable
final class StoredScreenRequest extends ScreenRequest {
  const StoredScreenRequest({required this.label, this.itemRef, this.data});

  @override
  final String label;

  @override
  final ItemRef? itemRef;

  /// What the codec wrote; null without one.
  final Map<String, Object?>? data;

  @override
  String toString() => 'StoredScreenRequest($label)';
}
