import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/open_with_other_apps.dart';

enum VideoComposeSaveResult { saved, cancelled, sharePresented, unavailable }

/// Hands a completed file to a mobile system save/share surface without
/// loading the video into Dart memory or changing the compose task's output.
class VideoComposeSaveService {
  const VideoComposeSaveService({
    this.platform,
    this.androidChannel = const MethodChannel(
      'com.example.video_player_app/compose_video_save',
    ),
    this.shareChannel = openWithOtherAppsChannel,
  });

  final TargetPlatform? platform;
  final MethodChannel androidChannel;
  final MethodChannel shareChannel;

  Future<VideoComposeSaveResult> save(String path, {Rect? origin}) async {
    if (path.isEmpty || path.contains('\u0000') || !File(path).isAbsolute) {
      throw ArgumentError('视频路径无效');
    }
    if (!await File(path).exists()) {
      throw FileSystemException('合成视频不存在', path);
    }
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.android:
        final saved = await androidChannel.invokeMethod<bool>('save', {
          'path': path,
        });
        return saved == true
            ? VideoComposeSaveResult.saved
            : saved == false
            ? VideoComposeSaveResult.cancelled
            : VideoComposeSaveResult.unavailable;
      case TargetPlatform.iOS:
        final presented = await shareChannel.invokeMethod<bool>('shareFile', {
          'path': path,
          'mimeType': 'video/mp4',
          if (origin != null) ...{
            'originX': origin.left,
            'originY': origin.top,
            'originWidth': origin.width,
            'originHeight': origin.height,
          },
        });
        return presented == true
            ? VideoComposeSaveResult.sharePresented
            : VideoComposeSaveResult.unavailable;
      default:
        return VideoComposeSaveResult.unavailable;
    }
  }
}
