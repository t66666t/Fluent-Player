import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../services/network/network_http.dart';

/// URLSession owns transfers while iOS suspends the Flutter engine. The same
/// stable key reattaches to an existing transfer after a normal process restart.
class IosModelDownload {
  static const channel = MethodChannel(
    'com.example.video_player_app/model_downloads',
  );
  static final _progress = <String, void Function(int)>{};
  static bool _registered = false;

  static Future<void> pauseRetiredSpeakerDownload(String id) async {
    final key = switch (id) {
      'asr-speaker-segmentation-int8' =>
        'asr-speaker-segmentation-int8@9403a6902bb58e3d5ae8c7e77c3422de279db2e0:model.int8.onnx',
      'asr-speaker-campplus' =>
        'asr-speaker-campplus@8be2a75c9ed7a590538b268e46fbb65e1aa9d208:model.onnx',
      _ => null,
    };
    if (key == null) return;
    await channel.invokeMethod<void>('pause', {'key': key});
  }

  static Future<NetworkMode> networkMode() async {
    await NetworkSettingsService.instance.ready;
    final config = NetworkSettingsService.instance.configuration;
    return config.unifiedMode ??
        config.featureModes[NetworkScope.modelDownloads] ??
        NetworkMode.system;
  }

  static Future<void> pauseRetiredModelDownload(
    String identity,
    Iterable<String> files,
  ) async {
    for (final file in files) {
      await channel.invokeMethod<void>('pause', {'key': '$identity:$file'});
    }
  }

  static Future<void> download({
    required String key,
    required String url,
    required String destination,
    required bool direct,
    required CancelToken cancel,
    required void Function(int) onProgress,
  }) async {
    if (!_registered) {
      _registered = true;
      channel.setMethodCallHandler((call) async {
        final args = call.arguments;
        if (call.method == 'progress' && args is Map) {
          _progress[args['key']]?.call((args['received'] as num).toInt());
        }
      });
    }
    var finished = false;
    _progress[key] = onProgress;
    cancel.whenCancel.then((_) async {
      if (!finished) {
        try {
          await channel.invokeMethod<void>('pause', {'key': key});
        } on PlatformException {
          /* completion already delivered */
        }
      }
    });
    try {
      cancel.throwIfCancellationRequestedForModelDownload();
      await channel.invokeMethod<void>('download', {
        'key': key,
        'url': url,
        'destination': destination,
        'direct': direct,
      });
    } finally {
      finished = true;
      _progress.remove(key);
    }
  }
}

extension on CancelToken {
  void throwIfCancellationRequestedForModelDownload() {
    if (isCancelled) throw cancelError!;
  }
}
