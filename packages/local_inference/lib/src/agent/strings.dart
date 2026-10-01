/// The fixed texts an assistant writes into a conversation.
library;

import 'package:meta/meta.dart';

import 'yes_no.dart';

/// The conversation texts the app writes itself. They enter the history, and so the next prompts: a host that must
/// keep its prompts stable pins its own copy instead of borrowing a pack.
@immutable
final class AssistantStrings {
  const AssistantStrings({
    required this.error,
    required this.interrupted,
    required this.notUnderstood,
    required this.missingData,
    required this.declined,
    required this.offerDeclined,
    required this.listChanged,
    required this.yes,
    required this.no,
    required this.confirmDefault,
    required this.working,
    required this.done,
    required this.toolFailed,
    required this.yesNo,
  });

  /// The reply of a turn that failed.
  final String error;

  /// The reply of a turn stopped before any text.
  final String interrupted;

  /// The reply to an empty or malformed answer of the model.
  final String notUnderstood;

  /// The reply to a call with missing or invalid arguments.
  final String missingData;

  /// The reply to a no, and the history text of a question left unanswered.
  final String declined;

  /// The reply to a no to an offer.
  final String offerDeclined;

  /// The reply to a yes whose item number no longer names the item the question named.
  final String listChanged;

  /// The yes button, and the user's text of a tap on it.
  final String yes;

  /// The no button, and the user's text of a tap on it.
  final String no;

  /// The question of a call whose tool has none of its own.
  final String confirmDefault;

  /// The status of a running tool that has no label of its own.
  final String working;

  /// The reply to a recorded action with `ModelWrittenReplies` and no text of its own.
  final String done;

  /// The message of a tool failure the assistant makes (a timeout, a tool's exception under
  /// `ToolErrorPolicy.reportToModel`).
  final String toolFailed;

  /// Reads a yes or a no in a reply to a question or an offer.
  final YesNoParser yesNo;

  /// English.
  static const AssistantStrings english = AssistantStrings(
    error: 'Something went wrong. Please try again.',
    interrupted: 'Stopped.',
    notUnderstood: "I didn't quite understand: could you rephrase?",
    missingData: 'I need one more detail to go ahead: can you tell me more?',
    declined: 'All right, I did nothing.',
    offerDeclined: 'All right. Tell me if you need anything else.',
    listChanged: 'The list changed in the meantime, so I did nothing. Tell me again what you want to do.',
    yes: 'Yes',
    no: 'No',
    confirmDefault: 'Do you want to go ahead?',
    working: '⏳ One moment...',
    done: 'Done.',
    toolFailed: 'That did not work.',
    yesNo: YesNoParser.english,
  );

  /// Italian, neutral; a domain preset may pass texts of its own.
  static const AssistantStrings italian = AssistantStrings(
    error: 'Si è verificato un errore. Riprova.',
    interrupted: 'Interrotto.',
    notUnderstood: 'Non ho capito bene: puoi riformulare?',
    missingData: 'Mi manca un dato per procedere: puoi dirmi qualcosa in più?',
    declined: 'Va bene, non ho fatto nulla.',
    offerDeclined: 'Va bene. Dimmi pure se ti serve altro.',
    listChanged: "Nel frattempo l'elenco è cambiato: non ho fatto nulla. Dimmi di nuovo cosa vuoi fare.",
    yes: 'Sì',
    no: 'No',
    confirmDefault: 'Vuoi procedere?',
    working: '⏳ Un momento...',
    done: 'Fatto.',
    toolFailed: "Non sono riuscito a completare l'operazione.",
    yesNo: YesNoParser.italian,
  );

  /// The pack of the language [code] (`it`, `it-IT`, `it_IT`: [italian]); [english] for any other.
  static AssistantStrings forLanguage(String code) {
    final language = code.toLowerCase().split(RegExp('[-_]')).first;
    return language == 'it' ? italian : english;
  }

  /// A copy with the given texts replaced.
  AssistantStrings copyWith({
    String? error,
    String? interrupted,
    String? notUnderstood,
    String? missingData,
    String? declined,
    String? offerDeclined,
    String? listChanged,
    String? yes,
    String? no,
    String? confirmDefault,
    String? working,
    String? done,
    String? toolFailed,
    YesNoParser? yesNo,
  }) => AssistantStrings(
    error: error ?? this.error,
    interrupted: interrupted ?? this.interrupted,
    notUnderstood: notUnderstood ?? this.notUnderstood,
    missingData: missingData ?? this.missingData,
    declined: declined ?? this.declined,
    offerDeclined: offerDeclined ?? this.offerDeclined,
    listChanged: listChanged ?? this.listChanged,
    yes: yes ?? this.yes,
    no: no ?? this.no,
    confirmDefault: confirmDefault ?? this.confirmDefault,
    working: working ?? this.working,
    done: done ?? this.done,
    toolFailed: toolFailed ?? this.toolFailed,
    yesNo: yesNo ?? this.yesNo,
  );

  @override
  String toString() => 'AssistantStrings($yes/$no)';
}
