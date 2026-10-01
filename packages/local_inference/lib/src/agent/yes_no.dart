/// Reading a yes or a no in a reply to a question.
library;

import 'package:meta/meta.dart';

/// Tells whether a text answers yes, no, or neither.
abstract interface class YesNoParser {
  /// true for a yes, false for a no, null for anything else.
  bool? parse(String text);

  /// English: "yes", "ok", "sure", "go ahead", …; "no", "cancel", "not now", …; each may be followed by "please",
  /// "thanks" and the like.
  static const YesNoParser english = PhraseYesNoParser(
    yes: ['yes', 'y', 'yeah', 'yep', 'ok', 'okay', 'sure', 'confirm', 'go ahead', 'do it', 'of course', 'please do'],
    no: ['no', 'n', 'nope', 'cancel', 'stop', 'not now', 'never mind', "don't", 'do not'],
    fillers: ['please', 'thanks', 'thank', 'you', 'very', 'much'],
  );

  /// Italian: "sì", "ok", "va bene", "certo", "procedi", …; "no", "annulla", "non ora", …; each may be followed by
  /// "grazie", "mille", "pure". A neutral pack; a domain preset may pass a parser of its own.
  static const YesNoParser italian = PhraseYesNoParser(
    yes: [
      'sì',
      'si',
      'sí',
      'ok',
      'okay',
      'va bene',
      'certo',
      'confermo',
      'conferma',
      'procedi',
      'vai',
      'esatto',
      "d'accordo",
    ],
    no: ['no', 'annulla', 'lascia stare', 'lascia perdere', 'non ora', 'niente'],
    fillers: ['grazie', 'mille', 'pure'],
  );
}

/// A [YesNoParser] over phrase lists, for any language written with letters.
///
/// The text is lower-cased; combining marks are dropped (a decomposed "sì" reads as "si"); every character that is
/// not a letter, a digit or an apostrophe becomes a space; spaces are collapsed and trimmed. It is a yes when it
/// starts with a [yes] phrase and every word after it is a [fillers] word (or another yes phrase), and likewise for
/// [no]: "yes 2" or "yes, but tomorrow" say more than yes, and are neither.
@immutable
final class PhraseYesNoParser implements YesNoParser {
  const PhraseYesNoParser({required this.yes, required this.no, this.fillers = const []});

  /// Phrases that mean yes, lower-case, words separated by one space.
  final List<String> yes;

  /// Phrases that mean no.
  final List<String> no;

  /// Words that may follow the phrase ("thanks").
  final List<String> fillers;

  static final RegExp _marks = RegExp(r'\p{M}', unicode: true);
  static final RegExp _others = RegExp(r"[^\p{L}\p{N}']+", unicode: true);

  @override
  bool? parse(String text) {
    final words = _words(text);
    if (words.isEmpty) return null;
    if (_answers(words, yes)) return true;
    if (_answers(words, no)) return false;
    return null;
  }

  bool _answers(List<String> words, List<String> phrases) {
    for (final phrase in phrases) {
      final head = _words(phrase);
      if (head.isEmpty || head.length > words.length) continue;
      var matches = true;
      for (var i = 0; i < head.length && matches; i++) {
        matches = words[i] == head[i];
      }
      if (matches && _onlyFillers(words.sublist(head.length), phrases)) return true;
    }
    return false;
  }

  /// Whether [rest] is made of filler words and more [phrases] (`sì sì`, `yes yes please`).
  bool _onlyFillers(List<String> rest, List<String> phrases) {
    var i = 0;
    outer:
    while (i < rest.length) {
      if (fillers.contains(rest[i])) {
        i++;
        continue;
      }
      for (final phrase in phrases) {
        final head = _words(phrase);
        if (head.isEmpty || i + head.length > rest.length) continue;
        var matches = true;
        for (var k = 0; k < head.length && matches; k++) {
          matches = rest[i + k] == head[k];
        }
        if (matches) {
          i += head.length;
          continue outer;
        }
      }
      return false;
    }
    return true;
  }

  static List<String> _words(String text) {
    final cleaned = text.toLowerCase().replaceAll(_marks, '').replaceAll('’', "'").replaceAll(_others, ' ');
    return [
      for (final word in cleaned.split(' '))
        if (word.isNotEmpty && word != "'") _stripQuotes(word),
    ].where((word) => word.isNotEmpty).toList();
  }

  /// A word without the apostrophes around it ('ok' quoted, "si'").
  static String _stripQuotes(String word) {
    var start = 0;
    var end = word.length;
    while (start < end && word[start] == "'") {
      start++;
    }
    while (end > start && word[end - 1] == "'") {
      end--;
    }
    return word.substring(start, end);
  }

  @override
  String toString() => 'PhraseYesNoParser(${yes.length} yes, ${no.length} no)';
}
