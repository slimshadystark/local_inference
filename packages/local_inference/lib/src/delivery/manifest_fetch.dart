/// GET of a published model manifest.
library;

import 'dart:convert';
import 'dart:io';

/// GET [url] as UTF-8 text; null unless the server answers 200 with at most [maxBytes]. Asks caches not to answer
/// (`Cache-Control: no-cache`) so an edited manifest reaches phones at their next launch.
Future<String?> fetchManifest(
  Uri url, {
  Duration connectTimeout = const Duration(seconds: 5),
  int maxBytes = 1024 * 1024,
}) async {
  final client = HttpClient()..connectionTimeout = connectTimeout;
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) return null;
    }
    return utf8.decode(bytes);
  } on IOException {
    return null;
  } finally {
    client.close(force: true);
  }
}
