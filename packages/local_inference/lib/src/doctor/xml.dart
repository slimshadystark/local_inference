/// A small XML reader for the files the doctor inspects (XML property lists, AndroidManifest.xml): elements,
/// attributes, text, comments, CDATA and the five named entities plus numeric ones. No namespaces are resolved: an
/// attribute keeps its prefix (`android:name`).
library;

/// An element: its name, attributes, child elements and text.
final class XmlElement {
  XmlElement(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;
  final List<XmlElement> children = [];
  final StringBuffer _text = StringBuffer();

  /// The element's own text, without its children's.
  String get text => _text.toString();

  /// The child elements named [name].
  Iterable<XmlElement> childrenNamed(String name) => children.where((c) => c.name == name);

  /// This element and every element under it, in document order.
  Iterable<XmlElement> get descendants sync* {
    yield this;
    for (final child in children) {
      yield* child.descendants;
    }
  }
}

/// Parses [text] and returns its root element; throws [FormatException].
XmlElement parseXml(String text) => _XmlParser(text).parse();

final class _XmlParser {
  _XmlParser(this.s);

  final String s;
  int i = 0;

  Never _fail(String what) => throw FormatException(what, s, i);

  XmlElement parse() {
    final stack = <XmlElement>[];
    XmlElement? root;
    while (i < s.length) {
      final lt = s.indexOf('<', i);
      final end = lt < 0 ? s.length : lt;
      if (stack.isNotEmpty) stack.last._text.write(_unescape(s.substring(i, end)));
      i = end;
      if (lt < 0) break;
      if (s.startsWith('<!--', i)) {
        i = _after('-->', 'unterminated comment');
      } else if (s.startsWith('<![CDATA[', i)) {
        final close = s.indexOf(']]>', i);
        if (close < 0) _fail('unterminated CDATA');
        if (stack.isNotEmpty) stack.last._text.write(s.substring(i + 9, close));
        i = close + 3;
      } else if (s.startsWith('<?', i)) {
        i = _after('?>', 'unterminated processing instruction');
      } else if (s.startsWith('<!', i)) {
        i = _afterDeclaration();
      } else if (s.startsWith('</', i)) {
        final close = s.indexOf('>', i);
        if (close < 0) _fail('unterminated end tag');
        final name = s.substring(i + 2, close).trim();
        if (stack.isEmpty || stack.last.name != name) _fail('unexpected </$name>');
        stack.removeLast();
        i = close + 1;
      } else {
        final element = _startTag();
        if (stack.isNotEmpty) {
          stack.last.children.add(element);
        } else if (root == null) {
          root = element;
        } else {
          _fail('a second root element');
        }
        if (!_selfClosed) stack.add(element);
      }
    }
    if (stack.isNotEmpty) _fail('<${stack.last.name}> is not closed');
    return root ?? _fail('no root element');
  }

  bool _selfClosed = false;

  int _after(String marker, String error) {
    final at = s.indexOf(marker, i);
    if (at < 0) _fail(error);
    return at + marker.length;
  }

  /// Skips `<!DOCTYPE …>`, including an internal subset in brackets.
  int _afterDeclaration() {
    var depth = 0;
    for (var j = i + 2; j < s.length; j++) {
      final c = s[j];
      if (c == '[') depth++;
      if (c == ']') depth--;
      if (c == '>' && depth <= 0) return j + 1;
    }
    _fail('unterminated declaration');
  }

  static final _name = RegExp(r'[A-Za-z_:][-A-Za-z0-9_:.]*');
  static final _attribute = RegExp(r'''\s*([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("[^"]*"|'[^']*')''');

  XmlElement _startTag() {
    i++;
    final name = _name.matchAsPrefix(s, i);
    if (name == null) _fail('an element name was expected');
    i = name.end;
    final attributes = <String, String>{};
    while (true) {
      final attribute = _attribute.matchAsPrefix(s, i);
      if (attribute == null) break;
      final raw = attribute[2]!;
      attributes[attribute[1]!] = _unescape(raw.substring(1, raw.length - 1));
      i = attribute.end;
    }
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r')) {
      i++;
    }
    if (s.startsWith('/>', i)) {
      _selfClosed = true;
      i += 2;
    } else if (i < s.length && s[i] == '>') {
      _selfClosed = false;
      i++;
    } else {
      _fail('unterminated start tag <${name[0]}>');
    }
    return XmlElement(name[0]!, attributes);
  }

  static final _entity = RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos);');

  static String _unescape(String text) => text.replaceAllMapped(_entity, (m) {
    final e = m[1]!;
    return switch (e) {
      'lt' => '<',
      'gt' => '>',
      'amp' => '&',
      'quot' => '"',
      'apos' => "'",
      _ when e.startsWith('#x') => String.fromCharCode(int.parse(e.substring(2), radix: 16)),
      _ => String.fromCharCode(int.parse(e.substring(1))),
    };
  });
}

/// The value of an XML property list (Info.plist, .entitlements, PrivacyInfo.xcprivacy): maps, lists, strings,
/// booleans, ints and doubles (a date or data stays text). Throws [FormatException] for another format, such as a
/// binary property list.
Object? parsePlist(String text) {
  final root = parseXml(text);
  if (root.name != 'plist') throw FormatException('the root element is <${root.name}>, not <plist>');
  if (root.children.length != 1) throw const FormatException('<plist> must hold exactly one value');
  return _plistValue(root.children.single);
}

Object? _plistValue(XmlElement e) {
  switch (e.name) {
    case 'dict':
      final map = <String, Object?>{};
      for (var k = 0; k < e.children.length; k += 2) {
        final key = e.children[k];
        if (key.name != 'key' || k + 1 >= e.children.length) throw const FormatException('a <dict> key has no value');
        map[key.text] = _plistValue(e.children[k + 1]);
      }
      return map;
    case 'array':
      return [for (final child in e.children) _plistValue(child)];
    case 'true':
      return true;
    case 'false':
      return false;
    case 'integer':
      return int.tryParse(e.text.trim()) ?? (throw FormatException('bad <integer> ${e.text}'));
    case 'real':
      return double.tryParse(e.text.trim()) ?? (throw FormatException('bad <real> ${e.text}'));
    case 'string' || 'date' || 'data':
      return e.text;
    default:
      throw FormatException('unknown property list element <${e.name}>');
  }
}
