import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../cloud_drive/models/cloud_drive_models.dart';

/// Read a bounded snapshot, then release the file before touching the network.
/// Cancellation can remove a task while its already-read bytes keep playing.
class CacheReadSlice {
  const CacheReadSlice(
    this.bytes, {
    required this.start,
    required this.total,
    required this.partial,
    required this.requestEnd,
    this.contentType = 'application/octet-stream',
    this.stream,
    this.streamedLength,
    this.release,
  });
  final Uint8List bytes;
  final int start, total, requestEnd;
  final Stream<List<int>>? stream;
  final int? streamedLength;
  final Future<void> Function()? release;
  int get length => streamedLength ?? bytes.length;
  bool get completeRequest => start + length - 1 == requestEnd;
  final bool partial;
  final String contentType;
}

abstract final class MediaCacheReadHooks {
  static Future<CacheReadSlice?> Function(
    MediaSourceRef source,
    StreamItem track,
    bool video,
    String? range,
  )?
  bilibili;
  static Future<CacheReadSlice?> Function(
    CloudDrivePlaybackDescriptor source,
    Uri resource,
    String? range,
  )?
  cloud;

  static Future<bool> serve(
    HttpRequest request,
    Future<CacheReadSlice?>? operation,
  ) async {
    final slice = await operation;
    if (slice == null || !slice.completeRequest) return false;
    final response = request.response;
    try {
      response.statusCode = slice.partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, slice.contentType);
      response.contentLength = slice.length;
      if (slice.partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${slice.start}-${slice.start + slice.length - 1}/${slice.total}',
        );
      }
      if (request.method != 'HEAD') {
        if (slice.stream != null) {
          await response.addStream(slice.stream!);
        } else {
          response.add(slice.bytes);
        }
      }
      await response.close();
      return true;
    } finally {
      await slice.release?.call();
    }
  }
}

/// Coordinates short reads with publication and task cleanup on every platform.
abstract final class CacheFileAccess {
  static Set<String> get readingPaths => _readers.keys.toSet();
  static final _readers = <String, int>{};
  static final _blocked = <String>{};
  static final _changed = <Completer<void>>[];
  static String _key(String path) =>
      Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path);
  static bool _inside(String parent, String path) =>
      parent == path || p.isWithin(parent, path);

  static Future<T> mutate<T>(String path, Future<T> Function() work) async {
    final key = _key(path);
    while (_blocked.any(
      (entry) => _inside(entry, key) || _inside(key, entry),
    )) {
      final waiter = Completer<void>();
      _changed.add(waiter);
      await waiter.future;
    }
    _blocked.add(key);
    try {
      while (_readers.keys.any((reader) => _inside(key, reader))) {
        final waiter = Completer<void>();
        _changed.add(waiter);
        await waiter.future;
      }
      return await work();
    } finally {
      _blocked.remove(key);
      _signal();
    }
  }

  static void _signal() {
    final listeners = _changed.toList();
    _changed.clear();
    for (final waiter in listeners) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// The caller provides the verified, immutable prefix of this resource.
  /// An explicit finite range must be covered entirely. Open ranges may return
  /// a bounded 206, allowing the player to request the following chunk.
  static Future<CacheReadSlice?> read(
    File file, {
    required int resourceStart,
    required int availableBytes,
    required int total,
    required String? range,
    bool completeResource = false,
    bool streamComplete = true,
    bool allowPrefix = false,
    String contentType = 'application/octet-stream',
  }) async {
    final key = _key(file.path);
    if (_blocked.any((entry) => _inside(entry, key)) ||
        total <= 0 ||
        availableBytes <= 0) {
      return null;
    }
    var start = 0, end = total - 1;
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || match[1]!.isEmpty && match[2]!.isEmpty) return null;
      if (match[1]!.isEmpty) {
        start = math.max(0, total - int.parse(match[2]!));
      } else {
        start = int.parse(match[1]!);
        if (match[2]!.isNotEmpty) end = math.min(end, int.parse(match[2]!));
      }
    } else if (!completeResource && !allowPrefix) {
      return null;
    }
    final requestEnd = end;
    final streaming =
        streamComplete &&
        completeResource &&
        resourceStart == 0 &&
        availableBytes >= total;
    if (allowPrefix && !streaming) {
      end = math.min(
        end,
        math.min(
          resourceStart + availableBytes - 1,
          start + 2 * 1024 * 1024 - 1,
        ),
      );
    }
    if (start < resourceStart ||
        end < start ||
        end >= resourceStart + availableBytes ||
        !streaming && end - start + 1 > 8 * 1024 * 1024) {
      return null;
    }
    _readers[key] = (_readers[key] ?? 0) + 1;
    RandomAccessFile? handle;
    var detached = false;
    try {
      handle = await file.open();
      if (await handle.length() < end - resourceStart + 1) return null;
      await handle.setPosition(start - resourceStart);
      if (streaming) {
        final reader = handle;
        Future<void>? releasing;
        Future<void> release() => releasing ??= _releaseReader(key, reader);
        Stream<List<int>> body() async* {
          var left = end - start + 1;
          while (left > 0) {
            final bytes = await reader.read(math.min(left, 64 * 1024));
            if (bytes.isEmpty) throw const FileSystemException('缓存文件提前结束');
            left -= bytes.length;
            yield bytes;
          }
        }

        detached = true;
        return CacheReadSlice(
          Uint8List(0),
          start: start,
          total: total,
          requestEnd: requestEnd,
          partial: range != null,
          contentType: contentType,
          stream: body(),
          streamedLength: end - start + 1,
          release: release,
        );
      }
      final bytes = await handle.read(end - start + 1);
      if (bytes.length != end - start + 1) return null;
      return CacheReadSlice(
        bytes,
        start: start,
        total: total,
        partial: range != null,
        requestEnd: requestEnd,
        contentType: contentType,
      );
    } on FileSystemException {
      return null;
    } finally {
      if (!detached) await _releaseReader(key, handle);
    }
  }

  static Future<void> _releaseReader(
    String key,
    RandomAccessFile? handle,
  ) async {
    try {
      await handle?.close();
    } finally {
      final count = (_readers[key] ?? 1) - 1;
      if (count == 0) {
        _readers.remove(key);
      } else {
        _readers[key] = count;
      }
      _signal();
    }
  }
}
