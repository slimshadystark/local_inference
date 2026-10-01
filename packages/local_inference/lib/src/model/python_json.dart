/// JSON text with Python's `json.dumps` defaults.
library;

import 'dart:convert';

/// [value] as Python's `json.dumps(value, ensure_ascii=False)` writes it: item separator `", "`, key separator
/// `": "`, insertion order kept, non-ASCII left as is, whole doubles with a trailing `.0`.
///
/// Hugging Face's `apply_chat_template` renders `tojson` this way, so a model fine-tuned on its prompts read tool
/// declarations in this form; Dart's `jsonEncode` and dinja's `tojson` write compact JSON (`,` and `:`), which
/// tokenizes differently. Throws [ArgumentError] for a value that is not JSON (a map, a list, a string, a number,
/// a boolean or null).
///
/// The text is Python's except for some doubles and strings: a non-zero magnitude below 1e-4 (Python `1e-05`,
/// `1e-07`; here `0.00001`, `1e-7`), a magnitude from 1e16 up to 1e21 (Python `1e+16`; here `10000000000000000.0`),
/// -0.0 (here `0.0`), and a lone surrogate (escaped here, raw in Python). Tool declarations rarely hold any of them.
String pythonJson(Object? value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Object? value, StringBuffer out) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int) {
    out.write(value.toString());
  } else if (value is double) {
    // Python prints floats with repr(); integral doubles get a trailing ".0".
    out.write(value == value.roundToDouble() && value.abs() < 1e16 ? '${value.toInt()}.0' : value.toString());
  } else if (value is String) {
    out.write(_pyString(value));
  } else if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) out.write(', ');
      first = false;
      out.write(_pyString(entry.key.toString()));
      out.write(': ');
      _write(entry.value, out);
    }
    out.write('}');
  } else if (value is Iterable) {
    out.write('[');
    var first = true;
    for (final item in value) {
      if (!first) out.write(', ');
      first = false;
      _write(item, out);
    }
    out.write(']');
  } else {
    throw ArgumentError('pythonJson: unsupported type ${value.runtimeType}');
  }
}

/// Python escapes `"`, `\` and control characters (with the short forms for \b \f \n \r \t, `\u00XX` otherwise) and,
/// with ensure_ascii=False, nothing else. Dart's encoder does the same for that set, so it is reused.
String _pyString(String s) => jsonEncode(s);
