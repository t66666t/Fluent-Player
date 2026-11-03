import 'dart:convert';
import 'package:crypto/crypto.dart';

String podcastHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String podcastCanonicalUrl(String value) {
  final uri = Uri.parse(value.trim());
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        fragment: '',
      )
      .toString();
}

class PodcastMedia {
  const PodcastMedia({
    required this.url,
    this.mimeType = '',
    this.length,
    this.label = '',
  });
  final String url, mimeType, label;
  final int? length;
  bool get isHls =>
      mimeType.toLowerCase().contains('mpegurl') ||
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') == true;
  bool get isStreamManifest =>
      isHls ||
      mimeType.toLowerCase().contains('dash+xml') ||
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.mpd') == true;
  bool get isVideo =>
      mimeType.startsWith('video/') ||
      RegExp(r'\.(mp4|m4v|webm|mov)(\?|$)', caseSensitive: false).hasMatch(url);
  Map<String, dynamic> toJson() => {
    'url': url,
    'mimeType': mimeType,
    'length': length,
    'label': label,
  };
  factory PodcastMedia.fromJson(Map<String, dynamic> j) => PodcastMedia(
    url: j['url'] as String,
    mimeType: j['mimeType'] as String? ?? '',
    length: (j['length'] as num?)?.toInt(),
    label: j['label'] as String? ?? '',
  );
}

class PodcastTranscript {
  const PodcastTranscript({
    required this.url,
    this.type = '',
    this.language = '',
  });
  final String url, type, language;
  Map<String, dynamic> toJson() => {
    'url': url,
    'type': type,
    'language': language,
  };
  factory PodcastTranscript.fromJson(Map<String, dynamic> j) =>
      PodcastTranscript(
        url: j['url'],
        type: j['type'] ?? '',
        language: j['language'] ?? '',
      );
}

class PodcastEpisode {
  const PodcastEpisode({
    required this.id,
    required this.channelId,
    required this.title,
    required this.media,
    this.guid = '',
    this.description = '',
    this.imageUrl = '',
    this.link = '',
    this.publishedMs = 0,
    this.durationMs = 0,
    this.season,
    this.number,
    this.chaptersUrl,
    this.transcripts = const [],
    this.discoveredMs = 0,
  });
  final String id, channelId, title, guid, description, imageUrl, link;
  final List<PodcastMedia> media;
  final int publishedMs, durationMs, discoveredMs;
  final int? season, number;
  final String? chaptersUrl;
  final List<PodcastTranscript> transcripts;
  PodcastMedia preferredMedia(String preference) {
    final matching = media.where(
      (m) => preference == 'audio' ? !m.isVideo : m.isVideo,
    );
    return preference == 'original' || matching.isEmpty
        ? media.first
        : matching.first;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'channelId': channelId,
    'title': title,
    'guid': guid,
    'description': description,
    'imageUrl': imageUrl,
    'link': link,
    'media': media.map((m) => m.toJson()).toList(),
    'publishedMs': publishedMs,
    'durationMs': durationMs,
    'season': season,
    'number': number,
    'chaptersUrl': chaptersUrl,
    'transcripts': transcripts.map((t) => t.toJson()).toList(),
    'discoveredMs': discoveredMs,
  };
  factory PodcastEpisode.fromJson(Map<String, dynamic> j) => PodcastEpisode(
    id: j['id'],
    channelId: j['channelId'],
    title: j['title'] ?? '',
    guid: j['guid'] ?? '',
    description: j['description'] ?? '',
    imageUrl: j['imageUrl'] ?? '',
    link: j['link'] ?? '',
    media: (j['media'] as List)
        .map((m) => PodcastMedia.fromJson(Map<String, dynamic>.from(m)))
        .toList(),
    publishedMs: j['publishedMs'] ?? 0,
    durationMs: j['durationMs'] ?? 0,
    season: j['season'],
    number: j['number'],
    chaptersUrl: j['chaptersUrl'],
    transcripts: (j['transcripts'] as List? ?? [])
        .map((m) => PodcastTranscript.fromJson(Map<String, dynamic>.from(m)))
        .toList(),
    discoveredMs: j['discoveredMs'] ?? 0,
  );
}

class PodcastChannel {
  PodcastChannel({
    required this.id,
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.description = '',
    this.imageUrl = '',
    this.link = '',
    this.language = '',
    this.guid = '',
    this.aliases = const [],
    this.subscribedMs = 0,
    this.checkedMs = 0,
    this.successMs = 0,
    this.seenMs = 0,
    this.error = '',
    this.etag,
    this.lastModified,
    this.failureCount = 0,
    this.nextPage,
    this.active = true,
  });
  final String id;
  String feedUrl, title, author, description, imageUrl, link, language, guid;
  List<String> aliases;
  int subscribedMs, checkedMs, successMs, seenMs, failureCount;
  String error;
  String? etag, lastModified, nextPage;
  bool active;
  Map<String, dynamic> toJson() => {
    'id': id,
    'feedUrl': feedUrl,
    'title': title,
    'author': author,
    'description': description,
    'imageUrl': imageUrl,
    'link': link,
    'language': language,
    'guid': guid,
    'aliases': aliases,
    'subscribedMs': subscribedMs,
    'checkedMs': checkedMs,
    'successMs': successMs,
    'seenMs': seenMs,
    'error': error,
    'etag': etag,
    'lastModified': lastModified,
    'failureCount': failureCount,
    'nextPage': nextPage,
    'active': active,
  };
  factory PodcastChannel.fromJson(Map<String, dynamic> j) => PodcastChannel(
    id: j['id'],
    feedUrl: j['feedUrl'],
    title: j['title'] ?? '',
    author: j['author'] ?? '',
    description: j['description'] ?? '',
    imageUrl: j['imageUrl'] ?? '',
    link: j['link'] ?? '',
    language: j['language'] ?? '',
    guid: j['guid'] ?? '',
    aliases: List<String>.from(j['aliases'] ?? []),
    subscribedMs: j['subscribedMs'] ?? 0,
    checkedMs: j['checkedMs'] ?? 0,
    successMs: j['successMs'] ?? 0,
    seenMs: j['seenMs'] ?? 0,
    error: j['error'] ?? '',
    etag: j['etag'],
    lastModified: j['lastModified'],
    failureCount: j['failureCount'] ?? 0,
    nextPage: j['nextPage'],
    active: j['active'] != false,
  );
}

class PodcastEpisodeState {
  PodcastEpisodeState({
    this.positionMs = 0,
    this.played = false,
    this.favorite = false,
    this.retained = false,
    this.lastPlayedMs = 0,
    this.updatedMs = 0,
    this.playedAtMs = 0,
    this.favoriteUpdatedMs = 0,
  });
  int positionMs, lastPlayedMs, updatedMs, playedAtMs, favoriteUpdatedMs;
  bool played, favorite, retained;

  /// Display bucket shared by filters and row labels. [played] stays the
  /// completion flag; a leftover end position must not look in progress.
  String get listenBucket {
    if (played) return 'played';
    if (positionMs > 0) return 'inProgress';
    return 'unplayed';
  }

  Map<String, dynamic> toJson() => {
    'positionMs': positionMs,
    'played': played,
    'favorite': favorite,
    'retained': retained,
    'lastPlayedMs': lastPlayedMs,
    'updatedMs': updatedMs,
    'playedAtMs': playedAtMs,
    'favoriteUpdatedMs': favoriteUpdatedMs,
  };
  factory PodcastEpisodeState.fromJson(Map<String, dynamic> j) =>
      PodcastEpisodeState(
        positionMs: j['positionMs'] ?? 0,
        played: j['played'] == true,
        favorite: j['favorite'] == true,
        retained: j['retained'] == true,
        lastPlayedMs: j['lastPlayedMs'] ?? 0,
        updatedMs: j['updatedMs'] ?? 0,
        playedAtMs: j['playedAtMs'] ?? 0,
        favoriteUpdatedMs: j['favoriteUpdatedMs'] ?? 0,
      );
}

class PodcastFeed {
  const PodcastFeed(this.channel, this.episodes);
  final PodcastChannel channel;
  final List<PodcastEpisode> episodes;
}

class PodcastSearchResult {
  const PodcastSearchResult({
    required this.title,
    required this.author,
    required this.feedUrl,
    this.imageUrl = '',
    this.appleId,
    this.website = '',
  });
  final String title, author, feedUrl, imageUrl, website;
  final String? appleId;
}

enum PodcastDownloadStatus {
  queued,
  downloading,
  paused,
  waitingNetwork,
  completed,
  failed,
}

/// Structured transfer phase. UI copy is derived from this, not parsed back out.
enum PodcastTransferPhase {
  queued,
  connecting,
  downloading,
  waitingNetwork,
  retrying,
  verifying,
  assembling,
  ready,
}

enum PodcastWaitingReason {
  none,
  concurrency,
  network,
  userPause,
  retry,
  otherWorker,
}

/// Live transfer information; only verified cache blocks are persisted.
class PodcastTransferProgress {
  const PodcastTransferProgress({
    required this.receivedBytes,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.reusedBytes = 0,
    this.message = '',
    this.phase = PodcastTransferPhase.downloading,
    this.waitingReason = PodcastWaitingReason.none,
    this.committedBytes = 0,
    this.inFlightUniqueBytes = 0,
    this.networkBytes = 0,
    this.lastNetworkByteAt,
    this.lastUsefulByteAt,
    this.queuePosition,
  });

  /// Completion position: committed bytes plus non-overlapping in-flight bytes.
  final int receivedBytes, reusedBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final String message;
  final PodcastTransferPhase phase;
  final PodcastWaitingReason waitingReason;
  final int committedBytes, inFlightUniqueBytes, networkBytes;
  final DateTime? lastNetworkByteAt, lastUsefulByteAt;
  final int? queuePosition;
  double get fraction => totalBytes == null || totalBytes! <= 0
      ? 0
      : (receivedBytes / totalBytes!).clamp(0.0, 1.0);
  Duration? get remaining =>
      totalBytes != null && bytesPerSecond > 0 && receivedBytes < totalBytes!
      ? Duration(
          seconds:
              ((totalBytes! - receivedBytes).clamp(0, totalBytes!) /
                      bytesPerSecond)
                  .ceil(),
        )
      : null;
}

class PodcastDownload {
  PodcastDownload({
    required this.episodeId,
    required this.mediaUrl,
    this.status = PodcastDownloadStatus.queued,
    this.received = 0,
    this.total,
    this.error = '',
    this.automatic = false,
    this.manualRetain = false,
    this.preparation = false,
    this.queuedAtMs = 0,
  });
  final String episodeId, mediaUrl;
  PodcastDownloadStatus status;
  int received;
  int? total;
  String error;
  final bool automatic;

  /// User asked to keep the file. AI preparation must not pause this task.
  bool manualRetain;

  /// At least one transcription consumer is waiting on this task.
  bool preparation;
  int queuedAtMs;
  Map<String, dynamic> toJson() => {
    'episodeId': episodeId,
    'mediaUrl': mediaUrl,
    'status': status.name,
    'received': received,
    'total': total,
    'error': error,
    'automatic': automatic,
    'manualRetain': manualRetain,
    'preparation': preparation,
    'queuedAtMs': queuedAtMs,
  };
  factory PodcastDownload.fromJson(Map<String, dynamic> j) => PodcastDownload(
    episodeId: j['episodeId'],
    mediaUrl: j['mediaUrl'],
    // Older versions persisted a Wi-Fi-only wait. Resume through ordinary
    // admission on every network instead of carrying that obsolete policy on.
    status: j['status'] == PodcastDownloadStatus.waitingNetwork.name
        ? PodcastDownloadStatus.queued
        : PodcastDownloadStatus.values.firstWhere(
            (s) => s.name == j['status'],
            orElse: () => PodcastDownloadStatus.paused,
          ),
    received: j['received'] ?? 0,
    total: j['total'],
    error: j['error'] ?? '',
    automatic: j['automatic'] == true,
    // Older rows had no intent flag. A non-automatic task was a user download.
    manualRetain: j.containsKey('manualRetain')
        ? j['manualRetain'] == true
        : j['automatic'] != true && j['preparation'] != true,
    preparation: j['preparation'] == true,
    queuedAtMs: j['queuedAtMs'] ?? 0,
  );
}
