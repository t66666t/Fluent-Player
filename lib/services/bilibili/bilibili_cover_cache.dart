import 'dart:async';
import 'dart:io';
import 'package:video_player_app/services/network/network_http.dart';

import '../../models/media_artwork_ref.dart';
import '../media_artwork_repository.dart';

import 'package:path/path.dart' as p;

import '../../debug/developer_log.dart' as developer;
import '../../utils/bilibili_image_url.dart';

/// One cover file per Bilibili video, outside any single watch-only card.
///
/// Watch-only cards are thrown away when they leave the queue, and that used
/// to delete the only copy of the cover. The playlist then came back as a
/// blank row. This directory keeps the picture so the next lightweight entry
/// can point at it without another request, including after a restart.
class BilibiliCoverCache {
  BilibiliCoverCache(this.root);

  final Directory root;

  static const String folderName = 'bilibili_covers';

  /// Same headers the play API uses. The image CDN rejects a request with
  /// no Referer.
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String _referer = 'https://www.bilibili.com/';

  static const List<String> _extensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
  ];

  Directory get directory =>
      Directory(p.join(root.path, 'thumbnails', folderName));

  /// True when [path] is the shared cover, not a card's own thumbnail.
  static bool isSharedCoverPath(String path) {
    return p.split(p.normalize(path)).contains(folderName);
  }

  /// A cover already saved for [bvid], or null.
  String? existingPath(String bvid) {
    final safe = _safe(bvid);
    if (safe.isEmpty) return null;
    for (final ext in _extensions) {
      final file = File(p.join(directory.path, '$safe$ext'));
      if (file.existsSync() && file.lengthSync() > 0) return file.path;
    }
    return null;
  }

  /// Copies [sourcePath] into the shared slot for [bvid] unless that slot
  /// already has a picture. Returns the shared path, or null if [sourcePath]
  /// could not be read.
  Future<String?> remember(String bvid, String sourcePath) async {
    final safe = _safe(bvid);
    if (safe.isEmpty) return null;
    final source = File(sourcePath);
    if (!await source.exists() || await source.length() == 0) {
      return existingPath(bvid);
    }
    final ext = _extensionOf(sourcePath);
    final dest = File(p.join(directory.path, '$safe$ext'));
    if (_sameFile(dest.path, source.path)) return dest.path;
    if (await dest.exists() && await dest.length() > 0) return dest.path;
    try {
      await dest.parent.create(recursive: true);
      await source.copy(dest.path);
      _shareWithArtworkStore(bvid, dest.path, '');
      return dest.path;
    } catch (error) {
      developer.log('Bilibili cover not kept', error: error);
      return existingPath(bvid);
    }
  }

  /// Downloads the list-sized cover of [bvid] when it is not on disk yet.
  Future<String?> download(String bvid, String url) async {
    final existing = existingPath(bvid);
    if (existing != null) return existing;
    final normalized = bilibiliCoverThumbnailUrl(url);
    if (normalized == null) return null;
    final safe = _safe(bvid);
    if (safe.isEmpty) return null;
    final client = NetworkHttp.instance.createClient(
      scope: NetworkScope.bilibili,
    );
    try {
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await openNetworkRequest(
        client,
        'GET',
        Uri.parse(normalized),
        timeout: const Duration(seconds: 8),
      );
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.refererHeader, _referer);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.listen((_) {}).cancel();
        return null;
      }
      final bytes = await readNetworkResponseBytes(
        response,
        maxBytes: 8 * 1024 * 1024,
        idleTimeout: const Duration(seconds: 12),
        totalTimeout: const Duration(seconds: 30),
      );
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
      final dest = File(
        p.join(directory.path, '$safe${_extensionOf(normalized)}'),
      );
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(bytes, flush: true);
      _shareWithArtworkStore(bvid, dest.path, normalized);
      return dest.path;
    } catch (error) {
      developer.log('Bilibili cover not downloaded', error: error);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Registers the existing Bilibili file with the shared cover store.
  /// The original file stays where playlist rows already point.
  static void _shareWithArtworkStore(String bvid, String path, String url) {
    final repository = MediaArtworkRepository.active;
    if (repository == null || url.isEmpty) return;
    unawaited(
      repository.adoptFile(
        request: ArtworkRequest(
          url: url,
          adapter: ArtworkAdapter.bilibili,
          authPartition: 'bilibili',
          headers: const {'user-agent': _userAgent, 'referer': _referer},
        ),
        file: File(path),
        ownerKind: 'bilibili',
        ownerId: bvid,
      ),
    );
  }

  static String _safe(String bvid) {
    return bvid.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static String _extensionOf(String pathOrUrl) {
    final raw = p
        .extension(Uri.tryParse(pathOrUrl)?.path ?? pathOrUrl)
        .toLowerCase();
    return _extensions.contains(raw) ? raw : '.jpg';
  }

  static bool _sameFile(String a, String b) {
    final left = p.normalize(a);
    final right = p.normalize(b);
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }
}
