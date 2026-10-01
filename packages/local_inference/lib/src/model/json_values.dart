/// Equality, hashing and copies of decoded JSON values (maps, lists, strings, numbers, booleans, null). Internal.
library;

/// Whether [a] and [b] are equal JSON values: maps by keys and values (not by key order), lists element by element,
/// numbers by value (`1 == 1.0`).
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !jsonEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// A hash consistent with [jsonEquals].
int jsonHash(Object? value) => switch (value) {
  final Map<Object?, Object?> map => Object.hashAllUnordered([
    for (final entry in map.entries) Object.hash(entry.key, jsonHash(entry.value)),
  ]),
  final List<Object?> list => Object.hashAll([for (final item in list) jsonHash(item)]),
  // 1 and 1.0 are equal, so they must hash alike.
  final num n when n is double && n == n.truncateToDouble() && n.isFinite => n.toInt().hashCode,
  _ => value.hashCode,
};

/// A deep copy of a JSON value with `Map<String, Object?>` maps and `List<Object?>` lists, in the same key order.
Object? jsonCopy(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final entry in map.entries) entry.key.toString(): jsonCopy(entry.value),
  },
  final List<Object?> list => [for (final item in list) jsonCopy(item)],
  _ => value,
};
