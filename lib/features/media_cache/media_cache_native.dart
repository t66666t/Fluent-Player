// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../../services/network/network_models.dart';

class CacheSystemDeferred implements Exception {
  const CacheSystemDeferred();
  @override
  String toString() {
    return '';
  }
}

/// Native transfer state is separate from the Dart journal. iOS owns its
/// resumable requests while Flutter is suspended; completion receipts live
/// beside the task files, so a normal process restart can reconcile them.
abstract final class MediaCacheNative {
  static const transfers = MethodChannel(
    'com.example.video_player_app/media_cache_transfers',
  );
  static const tasks = MethodChannel(
    'com.example.video_player_app/media_cache_tasks',
  );

  static void Function(bool manual)? onInterrupted;

  static bool get foreground => !const {
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  }.contains(WidgetsBinding.instance.lifecycleState);
  static void checkCanFinalize() {}

  static Future<bool> canDownload(NetworkScope scope) async {
    return false;
  }

  static Future<void> setActive(int count) async {}

  static Future<void> directory(String path, {required bool forget}) async {}

  static Future<Map<String, dynamic>?> download({
    required String identity,
    required Uri url,
    required File target,
    required Map<String, String> headers,
    required NetworkScope scope,
    required CancelToken cancel,
    required void Function(int received, int? total) onProgress,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }
}
