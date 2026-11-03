// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:io';

import 'package:dio/dio.dart';

import 'douyin_models.dart';
import 'douyin_parser.dart';
import 'douyin_audio_muxer.dart';

class DouyinDownloadException implements Exception {
  const DouyinDownloadException(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
  @override
  String toString() {
    return '';
  }
}

/// One transfer, with a new cancellation token for each retry. Credentials are
/// scoped to the exact URL that the browser exported them for, and never saved.
class DouyinTransfer {
  DouyinTransfer({
    Dio? dio,
    bool Function(Uri)? allowUri,
    DouyinAudioMuxer Function()? muxerFactory,
  }) : _dio =
           dio ??
           NetworkHttp.instance.createDio(
             scope: NetworkScope.ytDlpDomestic,
             options: BaseOptions(connectTimeout: const Duration(seconds: 20)),
           ),
       _muxerFactory = muxerFactory ?? DouyinAudioMuxer.new,
       _allowUri =
           allowUri ?? ((uri) => DouyinParser.isSafeMediaUrl(uri.toString()));

  final Dio _dio;
  final bool Function(Uri) _allowUri;
  final DouyinAudioMuxer Function() _muxerFactory;

  void Function(double)? onMergeProgress;

  void cancel() {}

  void close() {}

  Future<File> download(
    DouyinVideo video,
    DouyinVideoVariant variant,
    Directory directory, {
    required Map<String, Map<String, String>> headersByUrl,
    void Function(int received, int? total)? onProgress,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  static String safeTitle(String value) {
    return '';
  }
}
