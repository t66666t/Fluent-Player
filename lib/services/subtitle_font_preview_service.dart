import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/subtitle_font.dart';
import '../utils/subtitle_font_parser.dart';
import 'network/network_http.dart';

typedef SubtitleFontPreviewFetcher =
    Future<Uint8List> Function(Uri uri, CancelToken cancel, int maxBytes);
typedef SubtitleFontPreviewLoader =
    Future<void> Function(String family, Uint8List bytes);

/// Loads only fixed specimen glyphs. These aliases never enter the installed
/// font library, settings, or composition jobs. No full font files are fetched.
class SubtitleFontPreviewService {
  static final instance = SubtitleFontPreviewService();
  static const maxCssBytes = 32 * 1024;
  static const maxFontBytes = 256 * 1024;
  static const userAgent = 'FluentPlayer-FontPreview/1.0';

  final SubtitleFontPreviewFetcher? fetchBytes;
  final SubtitleFontPreviewLoader? fontLoader;
  final int maxConcurrent;
  final Map<String, String> _loaded = {};
  final Map<String, _PreviewJob> _pending = {};
  final Queue<_PreviewJob> _queue = Queue();
  int _active = 0;

  SubtitleFontPreviewService({
    this.fetchBytes,
    this.fontLoader,
    this.maxConcurrent = 3,
  }) : assert(maxConcurrent > 0);

  Future<String> load(
    SubtitleOnlineFont font,
    String text, {
    required CancelToken cancel,
  }) async {
    _checkCancelled(cancel);
    final source = Uri.tryParse(font.sourceUrl);
    if (!font.directDownload ||
        source?.scheme != 'https' ||
        source?.host != 'github.com' ||
        source!.pathSegments.length < 6 ||
        source.pathSegments[0] != 'google' ||
        source.pathSegments[1] != 'fonts' ||
        source.pathSegments[2] != 'tree' ||
        source.pathSegments[4] != 'ofl') {
      throw const FormatException('请到字体官网预览');
    }
    if (text.trim().isEmpty || text.runes.length > 128) {
      throw const FormatException('预览示例过长');
    }
    final weight = font.weights.isEmpty
        ? 400
        : font.weights.reduce(
            (a, b) => (a - 400).abs() <= (b - 400).abs() ? a : b,
          );
    // Avoid repeating glyphs in the request, and never send subtitle content.
    final specimen = String.fromCharCodes(
      text.replaceAll(RegExp(r'\s+'), ' ').runes.toSet(),
    );
    final key = sha256
        .convert(utf8.encode('${font.name}|$weight|$specimen'))
        .toString();
    final loaded = _loaded[key];
    if (loaded != null) return loaded;
    var job = _pending[key];
    if (job == null || job.cancel.isCancelled) {
      job = _PreviewJob(key, font.name, weight, specimen);
      _pending[key] = job;
      _queue.add(job);
    }
    job.listeners++;
    _drain();
    try {
      return await Future.any<String>([
        job.result.future,
        cancel.whenCancel.then<String>((error) => throw error),
      ]);
    } finally {
      job.listeners--;
      if (job.listeners == 0 && !job.result.isCompleted) {
        job.cancel.cancel('预览已离开列表');
      }
    }
  }

  void _drain() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_PreviewJob job) async {
    try {
      _checkCancelled(job.cancel);
      final family = await _loadSpecimen(
        job,
      ).timeout(const Duration(seconds: 25));
      _checkCancelled(job.cancel);
      _loaded[job.key] = family;
      job.result.complete(family);
    } catch (error, stack) {
      job.cancel.cancel('预览请求结束');
      job.result.completeError(error, stack);
    } finally {
      if (identical(_pending[job.key], job)) _pending.remove(job.key);
      _active--;
      _drain();
    }
  }

  Future<String> _loadSpecimen(_PreviewJob job) async {
    final cssUri = Uri.https('fonts.googleapis.com', '/css2', {
      'family': '${job.name}:wght@${job.weight}',
      'text': job.text,
    });
    final css = utf8.decode(await _fetch(cssUri, job.cancel, maxCssBytes));
    final urls = RegExp(
      r'''url\(\s*['"]?(https://[^'"\)\s]+)['"]?\s*\)''',
    ).allMatches(css).map((match) => Uri.parse(match.group(1)!)).toSet();
    if (urls.length != 1) throw const FormatException('暂时无法获取字体预览');
    final uri = urls.single;
    if (uri.scheme != 'https' ||
        uri.host != 'fonts.gstatic.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !(uri.path.startsWith('/l/') || uri.path.startsWith('/s/'))) {
      throw const FormatException('字体预览地址无效');
    }
    final bytes = await _fetch(uri, job.cancel, maxFontBytes);
    final parsed = await compute(parseSubtitleFont, bytes);
    _checkCancelled(job.cancel);
    // Missing glyphs must not be shown in a fallback font as if they were a
    // genuine preview of this family.
    for (final rune in job.text.runes) {
      if (String.fromCharCode(rune).trim().isEmpty) continue;
      if (!parsed.coverage.any(
        (range) => rune >= range[0] && rune <= range[1],
      )) {
        throw const FormatException('字体未包含此预览示例的文字');
      }
    }
    final family = 'subtitle_preview_${job.key}';
    if (fontLoader != null) {
      await fontLoader!(family, bytes);
    } else {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    return family;
  }

  Future<Uint8List> _fetch(Uri uri, CancelToken cancel, int limit) async {
    _checkCancelled(cancel);
    if (fetchBytes != null) {
      final bytes = await fetchBytes!(uri, cancel, limit);
      _checkCancelled(cancel);
      if (bytes.length > limit) throw const FormatException('字体预览数据过大');
      return bytes;
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 12),
        followRedirects: false,
        headers: const {'User-Agent': userAgent},
      ),
    );
    NetworkHttp.instance.configureDio(dio);
    try {
      final response = await openCancellableDioStream(
        (child) => dio.get<ResponseBody>(
          uri.toString(),
          cancelToken: child,
          options: Options(responseType: ResponseType.stream),
        ),
        cancelToken: cancel,
      );
      final body = response.data!;
      final length = int.tryParse(
        body.headers['content-length']?.firstOrNull ?? '',
      );
      if (length != null && length > limit) {
        throw const FormatException('字体预览数据过大');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        _checkCancelled(cancel);
        if (builder.length + chunk.length > limit) {
          throw const FormatException('字体预览数据过大');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      dio.close(force: true);
    }
  }

  void _checkCancelled(CancelToken cancel) {
    if (cancel.isCancelled) throw cancel.cancelError!;
  }
}

class _PreviewJob {
  final String key, name, text;
  final int weight;
  final cancel = CancelToken();
  final result = Completer<String>();
  int listeners = 0;

  _PreviewJob(this.key, this.name, this.weight, this.text);
}
