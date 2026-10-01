/// What the host's own screens use to act on the same tools, lists and conversation as the assistant.
library;

import '../model/tool_call.dart';
import 'lists.dart';
import 'replies.dart';
import 'screen_requests.dart';
import 'tool_result.dart';

/// The host's side of an assistant: its screens run the same tools on the same lists, and what the user does there
/// joins the conversation.
abstract interface class ToolHost {
  /// Runs [call] for the host (`ToolCallSource.host`): no coercion, validation or question; the list it shows
  /// becomes the last list of its collection (annotations included), so a later "the second one" in the chat means
  /// what the user just saw on the screen. Writes no reply and asks for no screen.
  Future<ToolResult> runTool(ToolCall call);

  /// Joins what the user did on a screen to the conversation: an exchange of [userText] and the reply ([reply], or
  /// the writer's reply to [call] and [result], with no annotations) goes into the chat and the history. Returns the
  /// reply; its follow-up and offer are ignored, and no list is recorded.
  ///
  /// While a turn runs, the exchange goes before that turn's user item and into the history at once; the question
  /// or offer the turn ends with stays open. Otherwise the offer is dropped, an open question is closed (its buttons
  /// go, and the history gets its user text with `AssistantStrings.declined`), then the exchange is added.
  ToolReply recordAction(String userText, ToolCall call, ToolResult result, {String? reply});

  /// Whether [collection]'s last list came from [call] (same arguments in the same order): a screen that shows its
  /// own list runs it again before reading an item number when another list replaced it.
  bool isLastList(String collection, ToolCall call);

  /// Whether [request] can still be opened as it was: its item number still names the item it named.
  bool isScreenRequestCurrent(BoundScreenRequest request);

  /// The lists shown so far.
  ShownLists get lists;

  /// Grows whenever items join or leave the chat: a screen compares it before and after a page to know whether the
  /// conversation recorded something meanwhile.
  int get revision;
}
