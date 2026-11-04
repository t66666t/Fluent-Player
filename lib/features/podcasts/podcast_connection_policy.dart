import 'dart:async';
import 'dart:io';

import '../../services/network/network_models.dart';

/// Stable per-host routing. A transport failure may try the other device route
/// once in ten minutes; HTTP refusals and rate limits never trigger switching.
class PodcastConnectionPolicy {
  PodcastConnectionPolicy({DateTime Function()? now})
    : now = now ?? DateTime.now;
  final DateTime Function() now;
  final _alternates = <String, DateTime>{};
  int generation = 0;

  NetworkMode modeFor(Uri uri) {
    final domestic =
        NetworkSites.forPodcast(uri) == NetworkScope.podcastsDomestic;
    final alternate = _alternates[uri.host];
    final flipped = alternate != null && now().isBefore(alternate);
    return domestic != flipped ? NetworkMode.direct : NetworkMode.system;
  }

  bool connectionFailed(Uri uri, Object error) {
    if (NetworkSites.isLoopback(uri.host) ||
        (error is! SocketException && error is! TimeoutException)) {
      return false;
    }
    final previous = _alternates[uri.host];
    if (previous != null && now().isBefore(previous)) return false;
    _alternates[uri.host] = now().add(const Duration(minutes: 10));
    generation++;
    return true;
  }
}
