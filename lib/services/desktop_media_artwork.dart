import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../models/media_artwork_ref.dart';
import '../models/video_item.dart';
import 'media_artwork_repository.dart';

/// A small PNG snapshot for OS media clients, which cannot decode every format
/// accepted by Flutter or read authenticated image URLs themselves.
class DesktopMediaArtwork {
  Future<Directory>? _directory;
  Future<String?>? _fallback;
  bool _closed = false;

  Future<String?> fallback() => _fallback ??= _defaultArtwork();

  Future<String?> _defaultArtwork() async {
    try {
      final data = await rootBundle.load(
        'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png',
      );
      return await _png(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  Future<String?> resolve(VideoItem item) async {
    try {
      final candidate = item.thumbnailPath?.trim() ?? '';
      final uri = Uri.tryParse(candidate);
      if (candidate.isNotEmpty &&
          uri?.scheme != 'https' &&
          uri?.scheme != 'http') {
        final file = uri?.scheme == 'file'
            ? File.fromUri(uri!)
            : File(candidate);
        if (await file.exists() && await file.length() <= 20 * 1024 * 1024) {
          return await _png(await file.readAsBytes());
        }
      }
      final remote = uri?.scheme == 'https' || uri?.scheme == 'http'
          ? candidate
          : item.bilibiliPendingCardData?.coverUrl ?? '';
      final repository = MediaArtworkRepository.active;
      if (remote.isEmpty || repository == null || _closed) return null;
      final host = Uri.tryParse(remote)?.host.toLowerCase() ?? '';
      final snapshot = await repository.load(
        ArtworkRef(
          ownerKind: 'desktop-media',
          ownerId: item.id,
          temporary: true,
          primary: ArtworkRequest(
            url: remote,
            adapter:
                host.endsWith('.hdslb.com') || host.endsWith('.bilibili.com')
                ? ArtworkAdapter.bilibili
                : ArtworkAdapter.generic,
          ),
        ),
        priority: ArtworkPriority.player,
      );
      if (_closed) return null;
      final bytes = snapshot.memoryBytes;
      if (bytes != null) return await _png(Uint8List.fromList(bytes));
      final path = snapshot.localPath;
      if (path != null) return await _png(await File(path).readAsBytes());
    } catch (_) {
      // Keep the application artwork when the source image is unavailable.
    }
    return null;
  }

  Future<String?> _png(Uint8List bytes) async {
    if (_closed) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final scale = 512 / (width > height ? width : height);
        return ui.TargetImageSize(
          width: (width * scale).round().clamp(1, 512),
          height: (height * scale).round().clamp(1, 512),
        );
      },
    );
    late final ui.FrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } finally {
      codec.dispose();
    }
    ByteData? png;
    try {
      png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      frame.image.dispose();
    }
    if (_closed || png == null) return null;
    final data = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    final directory = await (_directory ??= Directory.systemTemp.createTemp(
      'fluent_desktop_media_',
    ));
    if (_closed) {
      await directory.delete(recursive: true);
      return null;
    }
    final file = File('${directory.path}/${sha256.convert(data)}.png');
    if (!await file.exists()) await file.writeAsBytes(data, flush: true);
    // Bound temporary snapshots during a long queue. Keep the default artwork.
    final files = await directory
        .list()
        .where((entry) => entry is File)
        .toList();
    if (files.length > 8) {
      final fallback = await _fallback;
      for (final old in files.take(files.length - 8)) {
        if (old.path != file.path && old.path != fallback) await old.delete();
      }
    }
    return _closed ? null : file.path;
  }

  Future<void> dispose() async {
    _closed = true;
    final directory = await _directory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
