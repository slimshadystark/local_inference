/// Where a [ModelManager] gets its model list.
library;

import 'package:meta/meta.dart';

import 'manifest.dart';
import 'manifest_fetch.dart';

/// Where the manager's current manifest came from.
enum CatalogOrigin {
  /// The copy that ships with the app.
  bundled,

  /// The copy at the catalog's remote URL.
  remote,

  /// A manifest the host built.
  fixed,
}

/// Where a [ModelManager] reads its manifest: the copy in the app, swapped for a remote one when it answers
/// ([ModelCatalog.bundled]), a manifest the host built ([ModelCatalog.fixed]) or a single entry ([ModelCatalog.single]).
@immutable
sealed class ModelCatalog {
  const ModelCatalog();

  /// The copy that ships with the app, read by [read]; with [remote], swapped for the copy there when it answers
  /// within [timeout] (5 seconds). Before the first model is installed the remote copy is awaited; once one is, the
  /// manager starts on the bundled copy and swaps in the remote one when it arrives, unless a download is under way.
  /// If [read] fails the remote copy alone is used. [fetch] defaults to [fetchManifest].
  const factory ModelCatalog.bundled(
    Future<String> Function() read, {
    Uri? remote,
    Future<String?> Function(Uri url)? fetch,
    Duration timeout,
  }) = BundledCatalog;

  /// A manifest the host built; nothing is fetched.
  const factory ModelCatalog.fixed(ModelManifest manifest) = FixedCatalog;

  /// One model the host describes, such as a URL and a size from its own configuration.
  factory ModelCatalog.single(ModelEntry entry) => FixedCatalog(ModelManifest(models: List.unmodifiable([entry])));
}

/// See [ModelCatalog.bundled].
final class BundledCatalog extends ModelCatalog {
  const BundledCatalog(this.read, {this.remote, this.fetch, this.timeout = const Duration(seconds: 5)});

  /// Returns the bundled manifest's JSON; may throw when the app has none.
  final Future<String> Function() read;

  /// The published manifest, when there is one.
  final Uri? remote;

  /// Returns the body at a URL, or null; null uses [fetchManifest].
  final Future<String?> Function(Uri url)? fetch;

  /// How long the remote copy may take.
  final Duration timeout;
}

/// See [ModelCatalog.fixed] and [ModelCatalog.single].
final class FixedCatalog extends ModelCatalog {
  const FixedCatalog(this.manifest);

  final ModelManifest manifest;
}
