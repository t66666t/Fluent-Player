import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/media_source_ref.dart';
import '../models/video_item.dart';
import 'open_with_other_apps.dart';
import 'reveal_in_file_manager.dart';

enum SourceMediaFileResult {
  opened,
  missing,
  permissionDenied,
  unavailable,
  invalidSource,
}

/// Uses the source recorded on the card, never its title, playback conversion,
/// thumbnail, or an online materialization cache. Sharing never stages a copy.
class SourceMediaFileActions {
  SourceMediaFileActions({
    TargetPlatform? platform,
    Future<bool> Function(String)? reveal,
  }) : platform = platform ?? defaultTargetPlatform,
       _reveal = reveal ?? _revealSourceFile;

  final TargetPlatform platform;
  final Future<bool> Function(String) _reveal;

  bool get isMobile =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  bool get isSupported => !kIsWeb && platform != TargetPlatform.fuchsia;

  String get label => isMobile ? '分享源媒体文件' : '打开源文件位置';

  String? pathFor(VideoItem item) {
    if (!isSupported || item.isRecycled) return null;
    if (item.sourceRef?.kind == MediaSourceKind.cloudDrive ||
        item.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      return null;
    }
    return sourceMediaFilePath(item.path, platform: platform);
  }

  Future<SourceMediaFileResult> open(
    VideoItem item, {
    Rect? sharePositionOrigin,
  }) async {
    final path = pathFor(item);
    if (path == null) return SourceMediaFileResult.invalidSource;
    try {
      if (isMobile) {
        // Native FileProvider / UIActivityViewController shares this exact file
        // in place, including app-private directories. Do not use share_plus:
        // its Android implementation copies files into the share cache first.
        final opened = await openWithOtherAppsChannel.invokeMethod<bool>(
          'shareFile',
          <String, Object>{
            'path': path,
            'mimeType': item.type == MediaType.audio ? 'audio/*' : 'video/*',
            if (sharePositionOrigin != null) ...{
              'originX': sharePositionOrigin.left,
              'originY': sharePositionOrigin.top,
              'originWidth': sharePositionOrigin.width,
              'originHeight': sharePositionOrigin.height,
            },
          },
        );
        return opened == true
            ? SourceMediaFileResult.opened
            : SourceMediaFileResult.unavailable;
      }
      if (!await File(path).exists()) return SourceMediaFileResult.missing;
      return await _reveal(path)
          ? SourceMediaFileResult.opened
          : SourceMediaFileResult.unavailable;
    } on PlatformException catch (error) {
      return switch (error.code) {
        'SOURCE_MISSING' => SourceMediaFileResult.missing,
        'SOURCE_PERMISSION_DENIED' => SourceMediaFileResult.permissionDenied,
        _ => SourceMediaFileResult.unavailable,
      };
    } on FileSystemException catch (error) {
      return error.osError?.errorCode == 5 || error.osError?.errorCode == 13
          ? SourceMediaFileResult.permissionDenied
          : SourceMediaFileResult.missing;
    } on Exception {
      return SourceMediaFileResult.unavailable;
    }
  }

  static Future<bool> _revealSourceFile(String path) =>
      revealInFileManager(path, requireExistingFile: true);
}

/// Recognizes the path's prefix, without parsing plain filenames as URLs or
/// decoding literal percent escapes. Whitespace in a real filename is data.
String? sourceMediaFilePath(String path, {required TargetPlatform platform}) {
  if (path.isEmpty || path.contains('\u0000')) return null;
  final windows = platform == TargetPlatform.windows;
  final paths = windows ? p.windows : p.posix;
  // Root-relative Windows paths depend on the process's current drive.
  if (windows && paths.isRootRelative(path)) return null;
  if (paths.isAbsolute(path)) return path;

  final uri = Uri.tryParse(path);
  if (uri == null) return null;
  if (uri.scheme == 'content' && platform == TargetPlatform.android) {
    return uri.hasAuthority && uri.host.isNotEmpty ? path : null;
  }
  if (uri.scheme != 'file' || uri.hasQuery || uri.hasFragment) return null;
  try {
    final decoded = uri.toFilePath(windows: windows);
    return paths.isAbsolute(decoded) &&
            !(windows && paths.isRootRelative(decoded)) &&
            !decoded.contains('\u0000')
        ? decoded
        : null;
  } on UnsupportedError {
    return null;
  } on ArgumentError {
    return null;
  }
}
