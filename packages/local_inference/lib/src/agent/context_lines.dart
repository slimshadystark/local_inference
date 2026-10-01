/// Date lines for the newest user message of a prompt.
library;

/// Lines that tell the model the conversation's date, for `PromptLayout.contextLine`.
abstract final class ContextLines {
  static const List<String> _weekdaysEn = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<String> _monthsEn = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const List<String> _weekdaysIt = [
    'lunedì',
    'martedì',
    'mercoledì',
    'giovedì',
    'venerdì',
    'sabato',
    'domenica',
  ];

  static const List<String> _monthsIt = [
    'gennaio',
    'febbraio',
    'marzo',
    'aprile',
    'maggio',
    'giugno',
    'luglio',
    'agosto',
    'settembre',
    'ottobre',
    'novembre',
    'dicembre',
  ];

  /// `'Today is Friday, 4 September 2026.'`
  static String english(DateTime day) =>
      'Today is ${_weekdaysEn[day.weekday - 1]}, ${day.day} ${_monthsEn[day.month - 1]} ${day.year}.';

  /// `'Today is 2026-09-04.'`
  static String iso(DateTime day) =>
      'Today is ${day.year.toString().padLeft(4, '0')}-${_two(day.month)}-${_two(day.day)}.';

  /// `'venerdì 4 settembre 2026'`.
  static String italianDate(DateTime day) =>
      '${_weekdaysIt[day.weekday - 1]} ${day.day} ${_monthsIt[day.month - 1]} ${day.year}';

  /// `'Oggi è venerdì 4 settembre 2026.'`
  static String italian(DateTime day) => 'Oggi è ${italianDate(day)}.';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
