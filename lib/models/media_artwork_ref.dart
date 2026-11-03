import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Where a cover request is allowed to send its own headers.
///
/// Bilibili keeps its Referer. Podcast requests must not borrow those headers,
/// and two private images are not merged just because the URL looks similar.
enum ArtworkAdapter { podcast, bilibili, local, generic }

enum ArtworkPriority { player, visible, palette, prefetch }

/// One network identity. Display size is intentionally absent: every widget
/// that shows the same bytes must share one download.
class ArtworkRequest {
  const ArtworkRequest({
    required this.url,
    required this.adapter,
    this.authPartition = 'public',
    this.headers = const {},
  });

  final String url;
  final ArtworkAdapter adapter;

  /// Separates public covers from credentialed ones without storing the secret.
  final String authPartition;
  final Map<String, String> headers;

  bool get isEmpty => url.trim().isEmpty;

  /// Full URL, adapter, partition and content-affecting headers.
  /// Query strings stay intact; different signatures are different requests.
  String get requestKey {
    final lines =
        headers.entries
            .map((entry) => '${entry.key.toLowerCase()}=${entry.value}')
            .toList()
          ..sort();
    return sha256
        .convert(
          utf8.encode('${adapter.name}\n$authPartition\n$url\n${lines.join('\n')}'),
        )
        .toString();
  }

  String get host {
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) return '';
    return parsed.host.toLowerCase();
  }
}

/// A cover someone on screen, or a saved channel/episode, is responsible for.
class ArtworkRef {
  const ArtworkRef({
    required this.ownerKind,
    required this.ownerId,
    this.primary,
    this.fallbacks = const [],
    this.temporary = false,
  });

  final String ownerKind;
  final String ownerId;
  final ArtworkRequest? primary;
  final List<ArtworkRequest> fallbacks;

  /// Search previews expire. Channel and episode covers do not.
  final bool temporary;

  List<ArtworkRequest> get chain {
    final seen = <String>{};
    final result = <ArtworkRequest>[];
    for (final ArtworkRequest? request in [primary, ...fallbacks]) {
      if (request == null || request.isEmpty) continue;
      if (seen.add(request.requestKey)) result.add(request);
    }
    return result;
  }
}

/// Decode sizes. Floating layout pixels must not create extra cache entries.
const artworkSizeBuckets = <int>[64, 128, 256, 512, 1024, 1600];

int artworkSizeBucket(double logicalPixels, double devicePixelRatio) {
  final pixels = logicalPixels * devicePixelRatio;
  for (final bucket in artworkSizeBuckets) {
    if (pixels <= bucket) return bucket;
  }
  return artworkSizeBuckets.last;
}

enum ArtworkPhase { ready, placeholder, failed }

class ArtworkSnapshot {
  const ArtworkSnapshot({
    required this.phase,
    this.localPath,
    this.memoryBytes,
    this.blobHash,
    this.requestKey,
    this.format,
    this.reason = '',
    this.fromDisk = false,
  });

  final ArtworkPhase phase;
  final String? localPath;
  final List<int>? memoryBytes;
  final String? blobHash;
  final String? requestKey;
  final String? format;

  /// Short, user-safe cause such as `http`, `decode` or `empty`. No URLs.
  final String reason;
  final bool fromDisk;

  bool get hasImage =>
      phase == ArtworkPhase.ready &&
      ((localPath != null && localPath!.isNotEmpty) ||
          (memoryBytes != null && memoryBytes!.isNotEmpty));
}

/// Podcast episode art, then the channel art. The same URL is not tried twice.
ArtworkRef podcastArtworkRef({
  required String ownerKind,
  required String ownerId,
  required String primaryUrl,
  String fallbackUrl = '',
  bool temporary = false,
}) {
  ArtworkRequest? requestFor(String url) => url.trim().isEmpty
      ? null
      : ArtworkRequest(url: url.trim(), adapter: ArtworkAdapter.podcast);
  return ArtworkRef(
    ownerKind: ownerKind,
    ownerId: ownerId,
    primary: requestFor(primaryUrl),
    fallbacks: [?requestFor(fallbackUrl)],
    temporary: temporary,
  );
}
