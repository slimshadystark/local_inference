/// Numbers as the model setup shows them: sizes, speeds, times, percentages.
library;

import 'package:flutter/foundation.dart';

/// Formats of sizes, speeds and times in one language. Sizes use decimal units, as iOS and Android show storage;
/// a probe value in MB counts 1024 * 1024 bytes. Every format is a function a host may replace.
@immutable
final class LocalizedFormats {
  const LocalizedFormats({
    required this.bytes,
    required this.megabytes,
    required this.ramLabel,
    required this.speed,
    required this.remaining,
    required this.percent,
    required this.gigabytesPair,
  });

  /// "3,1 GB", "850 MB".
  static const italian = LocalizedFormats(
    bytes: _itBytes,
    megabytes: _itMegabytes,
    ramLabel: nominalRamLabel,
    speed: _itSpeed,
    remaining: _itRemaining,
    percent: wholePercent,
    gigabytesPair: _itGigabytesPair,
  );

  /// "3.1 GB", "850 MB".
  static const english = LocalizedFormats(
    bytes: _enBytes,
    megabytes: _enMegabytes,
    ramLabel: nominalRamLabel,
    speed: _enSpeed,
    remaining: _enRemaining,
    percent: wholePercent,
    gigabytesPair: _enGigabytesPair,
  );

  /// A size in bytes: gigabytes with one decimal from 1 GB, whole megabytes below.
  final String Function(int bytes) bytes;

  /// [bytes] of a probe value in MB (1024 * 1024 bytes).
  final String Function(int mb) megabytes;

  /// The marketed RAM a phone needs to report at least `mb` ("8 GB" for 7000: an 8 GB iPhone reports about 7600 MB).
  final String Function(int mb) ramLabel;

  /// A download speed, or null when unknown or not positive.
  final String? Function(double? bytesPerSecond) speed;

  /// The time a download still needs, or null when unknown or not positive.
  final String? Function(Duration? remaining) remaining;

  /// A 0..1 fraction as a whole percentage, rounded down: "42%".
  final String Function(double fraction) percent;

  /// Bytes done and total as gigabytes: "1,3 / 3,1 GB".
  final String Function(int done, int total) gigabytesPair;

  LocalizedFormats copyWith({
    String Function(int bytes)? bytes,
    String Function(int mb)? megabytes,
    String Function(int mb)? ramLabel,
    String? Function(double? bytesPerSecond)? speed,
    String? Function(Duration? remaining)? remaining,
    String Function(double fraction)? percent,
    String Function(int done, int total)? gigabytesPair,
  }) => LocalizedFormats(
    bytes: bytes ?? this.bytes,
    megabytes: megabytes ?? this.megabytes,
    ramLabel: ramLabel ?? this.ramLabel,
    speed: speed ?? this.speed,
    remaining: remaining ?? this.remaining,
    percent: percent ?? this.percent,
    gigabytesPair: gigabytesPair ?? this.gigabytesPair,
  );
}

/// The marketed RAM tier a phone needs to report at least [mb]: "8 GB" for 7000.
String nominalRamLabel(int mb) {
  const tiers = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64];
  for (final gb in tiers) {
    if (gb * 1024 >= mb) return '$gb GB';
  }
  return '${(mb / 1024).ceil()} GB';
}

/// "42%" for 0.429.
String wholePercent(double fraction) => '${(fraction * 100).floor()}%';

/// "3,1 GB" (decimal units, as iOS and Android show storage), "850 MB" below one gigabyte.
String _itBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(1).replaceAll('.', ',')} GB';
  return '${(bytes / 1e6).round()} MB';
}

String _itMegabytes(int mb) => _itBytes(mb * 1024 * 1024);

/// "12,5 MB/s" or "850 kB/s"; null when unknown.
String? _itSpeed(double? bytesPerSecond) {
  final megabytesPerSecond = bytesPerSecond == null ? null : bytesPerSecond / 1e6;
  if (megabytesPerSecond == null || megabytesPerSecond <= 0) return null;
  if (megabytesPerSecond >= 1) return '${megabytesPerSecond.toStringAsFixed(1).replaceAll('.', ',')} MB/s';
  return '${(megabytesPerSecond * 1000).round()} kB/s';
}

/// "meno di un minuto", "circa 4 min", "circa 1 h 20 min"; null when unknown.
String? _itRemaining(Duration? remaining) {
  if (remaining == null || remaining.isNegative || remaining == Duration.zero) return null;
  if (remaining.inSeconds < 60) return 'meno di un minuto';
  final minutes = (remaining.inSeconds / 60).ceil();
  if (minutes < 60) return 'circa $minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? 'circa $hours h' : 'circa $hours h $rest min';
}

/// "1,3 / 3,1 GB".
String _itGigabytesPair(int done, int total) => '${_itGigabytes(done)} / ${_itGigabytes(total)} GB';

/// "1,3" for 1.3 GB.
String _itGigabytes(int bytes) => (bytes / 1e9).toStringAsFixed(1).replaceAll('.', ',');

String _enBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  return '${(bytes / 1e6).round()} MB';
}

String _enMegabytes(int mb) => _enBytes(mb * 1024 * 1024);

String? _enSpeed(double? bytesPerSecond) {
  final megabytesPerSecond = bytesPerSecond == null ? null : bytesPerSecond / 1e6;
  if (megabytesPerSecond == null || megabytesPerSecond <= 0) return null;
  if (megabytesPerSecond >= 1) return '${megabytesPerSecond.toStringAsFixed(1)} MB/s';
  return '${(megabytesPerSecond * 1000).round()} kB/s';
}

String? _enRemaining(Duration? remaining) {
  if (remaining == null || remaining.isNegative || remaining == Duration.zero) return null;
  if (remaining.inSeconds < 60) return 'less than a minute';
  final minutes = (remaining.inSeconds / 60).ceil();
  if (minutes < 60) return 'about $minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? 'about $hours h' : 'about $hours h $rest min';
}

String _enGigabytesPair(int done, int total) =>
    '${(done / 1e9).toStringAsFixed(1)} / ${(total / 1e9).toStringAsFixed(1)} GB';
