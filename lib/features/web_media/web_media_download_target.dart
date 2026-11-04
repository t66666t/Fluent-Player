import '../../utils/bilibili_url_parser.dart';
import 'web_media_resource.dart';

/// A user-selected video, rather than whichever request happened most recently.
enum WebMediaTargetKind { card, player, page, resource }

class WebMediaDownloadTarget {
  const WebMediaDownloadTarget({
    required this.kind,
    required this.sourcePage,
    required this.identity,
    this.videoPage,
    this.title,
    this.playerId,
    this.playerSourceKey,
    this.expectVideo = true,
    this.resources = const [],
    this.currentUrl,
    this.height,
    this.duration,
    this.audioLanguage,
  });

  final WebMediaTargetKind kind;
  final Uri sourcePage;
  final String identity;
  final Uri? videoPage;
  final String? title;
  final String? playerId;
  final String? playerSourceKey;
  final bool expectVideo;
  final List<WebMediaResource> resources;
  final String? currentUrl;
  final int? height;
  final Duration? duration;
  final String? audioLanguage;
}

/// Explicit resource choices stay independent of the player's current track.
WebMediaDownloadTarget webMediaResourceDownloadTarget(
  WebMediaResource resource, {
  WebMediaPagePlayer? player,
  Iterable<WebMediaResource> companions = const [],
}) => WebMediaDownloadTarget(
  kind: WebMediaTargetKind.resource,
  sourcePage: resource.sourcePage,
  identity: '${resource.sourcePage}|resource:${_resourceIdentity(resource)}',
  videoPage: webMediaVideoPage(player?.videoPageUrl),
  title: resource.title.isNotEmpty ? resource.title : player?.title,
  playerId: player?.id,
  playerSourceKey: player?.sourceKey,
  currentUrl: resource.url,
  height: resource.metadata.height,
  duration: resource.duration,
  audioLanguage: player?.audioLanguage,
  expectVideo: !resource.isAudio,
  resources: _resourceRows(resource, companions),
);

String _resourceIdentity(WebMediaResource resource) =>
    '${webMediaResourceIdentity(webMediaDownloadUrl(resource.url))}|${resource.representationId ?? ''}';

List<WebMediaResource> _resourceRows(
  WebMediaResource selected,
  Iterable<WebMediaResource> companions,
) {
  final rows = <String, WebMediaResource>{selected.selectionKey: selected};
  if (selected.isAudio) return rows.values.toList();
  for (final audio in companions) {
    if (!audio.isAudio ||
        audio.sourcePage != selected.sourcePage ||
        !audio.playerIds.any(selected.playerIds.contains) ||
        selected.audioGroup != null &&
            audio.audioGroup != selected.audioGroup) {
      continue;
    }
    final expected = selected.duration, actual = audio.duration;
    if (expected != null &&
        actual != null &&
        (expected - actual).inMilliseconds.abs() >
            (expected.inMilliseconds / 100).clamp(2000, double.infinity)) {
      continue;
    }
    rows[audio.selectionKey] = audio;
  }
  return rows.values.toList();
}

/// Capture refreshes can update signing context or add matching audio, but must
/// never replace an explicit resource with the player's newly selected quality.
WebMediaDownloadTarget refreshWebMediaResourceTarget(
  WebMediaDownloadTarget target,
  Iterable<WebMediaResource> captured,
) {
  final selected = target.resources.first;
  final fresh =
      captured
          .where(
            (resource) =>
                resource.sourcePage == selected.sourcePage &&
                _resourceIdentity(resource) == _resourceIdentity(selected),
          )
          .firstOrNull ??
      selected;
  return WebMediaDownloadTarget(
    kind: target.kind,
    sourcePage: target.sourcePage,
    identity: target.identity,
    videoPage: target.videoPage,
    title: target.title,
    playerId: target.playerId,
    playerSourceKey: target.playerSourceKey,
    expectVideo: target.expectVideo,
    currentUrl: fresh.url,
    height: fresh.metadata.height ?? target.height,
    duration: fresh.duration ?? target.duration,
    audioLanguage: target.audioLanguage,
    resources: _resourceRows(fresh, [...target.resources, ...captured]),
  );
}

/// A blob player may reveal its manifest after the download click. Permit that
/// source change only for a waiting task with the same player and known video.
bool webMediaPlayerMatchesTarget(
  WebMediaPagePlayer player,
  WebMediaDownloadTarget target, {
  bool awaitingResources = false,
}) {
  if (!player.isVisible) return false;
  final expected = webMediaVideoPage(target.videoPage);
  final actual = webMediaVideoPage(player.videoPageUrl);
  if (expected != null && actual != expected) return false;
  if (target.playerId == null) return expected != null && actual == expected;
  if (player.id != target.playerId) return false;
  if (target.playerSourceKey == null ||
      player.sourceKey == target.playerSourceKey) {
    return true;
  }
  if (!awaitingResources || target.currentUrl != null) return false;
  if (expected != null) return actual == expected;
  // For other sites, the exact same blob source may gain a proven manifest.
  // Do not relax this to arbitrary reuse of a DOM player or a duration match.
  final source = target.playerSourceKey;
  if (source == null ||
      !source.contains('|blob:') ||
      player.sourceKey?.startsWith('$source|') != true) {
    return false;
  }
  final before = target.duration, after = player.duration;
  return before == null ||
      after == null ||
      (before - after).inSeconds.abs() <= 2;
}

/// Canonical page identity only; never a replacement for captured media.
Uri? webMediaVideoPage(Uri? page) {
  if (page == null || safeWebMediaUri(page.toString()) == null) return null;
  final host = page.host.toLowerCase();
  if (const [
        'xiaoe-tech.com',
        'xiaoeknow.com',
        'xiaoecloud.com',
        'xet.pomoho.com',
        'xet.citv.cn',
      ].any((domain) => host == domain || host.endsWith('.$domain')) &&
      RegExp(r'^/p/course/video/v_[\w-]+/?$').hasMatch(page.path)) {
    return Uri(
      scheme: page.scheme,
      host: page.host,
      port: page.hasPort ? page.port : null,
      path: page.path,
    );
  }
  if (host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com')) {
    String? id;
    final parts = page.pathSegments;
    if (host == 'youtu.be') {
      id = parts.firstOrNull;
    } else if (page.path == '/watch') {
      id = page.queryParameters['v'];
    } else if (parts.length >= 2 &&
        ['embed', 'shorts', 'live'].contains(parts[0])) {
      id = parts[1];
    }
    return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)
        ? Uri.https('www.youtube.com', '/watch', {'v': id})
        : null;
  }
  if (isBilibiliVideoHost(host)) {
    final target = parseBilibiliLink(page.toString());
    if (target?.bvid != null) {
      return Uri.https(
        'www.bilibili.com',
        '/video/${target!.bvid}/',
        target.pageOrFirst > 1 ? {'p': '${target.pageOrFirst}'} : null,
      );
    }
    if (target?.bangumiId?.startsWith('ep') == true) {
      return Uri.https(
        'www.bilibili.com',
        '/bangumi/play/${target!.bangumiId}',
      );
    }
  }
  if (host == 'ted.com' || host.endsWith('.ted.com')) {
    final parts = page.pathSegments.where((p) => p.isNotEmpty).toList();
    final talks = parts.indexOf('talks');
    if (talks >= 0) {
      final slugIndex = parts.elementAtOrNull(talks + 1) == 'lang'
          ? talks + 3
          : talks + 1;
      if (parts.length > slugIndex) {
        return Uri.https('www.ted.com', '/talks/${parts[slugIndex]}');
      }
    }
  }
  return null;
}

bool webMediaIsVideoSite(Uri? page) {
  if (page == null) return false;
  final host = page.host.toLowerCase();
  return isBilibiliVideoHost(host) ||
      host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');
}

class WebMediaResourceGroup {
  WebMediaResourceGroup(this.id, this.player, this.resources);
  final String id;
  final WebMediaPagePlayer? player;
  final List<WebMediaResource> resources;
}

/// Shared by the toolbar, fullscreen controls and resource list.
List<WebMediaResourceGroup> webMediaResourceGroups(
  List<WebMediaPagePlayer> players,
  List<WebMediaResource> resources,
) {
  final groups = <String, WebMediaResourceGroup>{};
  final owners = <String, String>{};
  for (final player in players) {
    final id = webMediaVideoPage(player.videoPageUrl)?.toString() ?? player.id;
    owners[player.id] = id;
    groups.putIfAbsent(id, () => WebMediaResourceGroup(id, player, []));
  }
  for (final resource in resources) {
    final id = resource.playerIds.map((id) => owners[id]).nonNulls.firstOrNull;
    final key = id ?? 'unmatched';
    final group = groups.putIfAbsent(
      key,
      () => WebMediaResourceGroup(key, null, []),
    );
    if (!group.resources.any((r) => r.url == resource.url)) {
      group.resources.add(resource);
    }
  }
  // A discovered player without a captured resource is still a real media
  // identity (blob/MSE players appear before their manifest). Keep it so the
  // waiting state is visible instead of silently missing.
  return groups.values.toList();
}
