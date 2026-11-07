import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../debug/developer_log.dart' as developer;
import '../progress_sync/folder_transfer_disk_space.dart' as disk;
import 'podcast_client.dart';
import 'podcast_download_gate.dart';
import 'podcast_models.dart';
import 'podcast_source_policy.dart';
import 'podcast_store.dart';
import 'podcast_transfer.dart';
import '../../services/network/recoverable_media_stream.dart';

const podcastChunkBytes = 1024 * 1024;

class PodcastMediaStore {
  PodcastMediaStore({
    required this.root,
    required this.store,
    required this.http,
    this.bodyIdleTimeout = PodcastTransferPolicy.bodyIdleTimeout,
    this.playbackRequestTimeout = const Duration(seconds: 8),
  });
  final Directory root;
  final PodcastStore store;
  final PodcastHttp http;
  final Duration bodyIdleTimeout;
  // Leave room inside native initialization's 20s budget for one reconnect.
  // Download requests keep their existing, longer transport deadlines.
  final Duration playbackRequestTimeout;
  late final _downloadGate = PodcastDownloadGate(store);
  final Set<String> protectedEpisodes = {};
  final Set<String> activeDownloads = {};
  void retainForUse(String episodeId, String owner) {
    final id = '$episodeId:$owner';
    store.write('mediaUse', id, {
      'id': id,
      'until': DateTime.now()
          .add(const Duration(hours: 8))
          .millisecondsSinceEpoch,
    }, channel: episodeId);
  }

  void releaseForUse(String episodeId, String owner) =>
      store.remove('mediaUse', '$episodeId:$owner');
  bool _inUse(String episodeId) =>
      protectedEpisodes.contains(episodeId) ||
      store
          .list('mediaUse', channel: episodeId)
          .any(
            (use) =>
                (use['until'] as int? ?? 0) >
                DateTime.now().millisecondsSinceEpoch,
          );
  final Map<String, _SerialLane> _lanes = {};
  final Map<String, _IndexFlight> _indexFlights = {};
  final Map<String, Set<_PodcastPlaybackRead>> _playbackReads = {};
  final Set<String> playbackDemands = {};

  /// Asset ids with an open gateway read, including discover-page preview.
  Set<String> get storageProtectedAssetIds => _playbackReads.keys.toSet();

  /// Episodes held by playback, an active download, or a foreground demand.
  Set<String> get storageProtectedEpisodeIds => {
    ...protectedEpisodes,
    ...activeDownloads,
    ...playbackDemands,
  };
  HttpClient? _sharedClient;
  HttpClient? _downloadClient;
  int _downloadEpoch = -1;
  int _sharedEpoch = -1;
  final Set<String> _seekPending = {};
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final String _token = podcastHash(
    '${DateTime.now().microsecondsSinceEpoch}|${Random.secure().nextDouble()}',
  );
  final Map<String, (PodcastEpisode, PodcastMedia)> _sources = {};
  bool _closed = false;

  String assetId(String episodeId, String url) =>
      podcastHash('$episodeId|$url');
  Map<String, dynamic> manifest(String episodeId, String url) =>
      store.read('asset', assetId(episodeId, url)) ??
      {
        'id': assetId(episodeId, url),
        'episodeId': episodeId,
        'url': url,
        'segments': <String, dynamic>{},
        'revision': 0,
        'downloaded': false,
        'accessed': DateTime.now().millisecondsSinceEpoch,
      };
  Map<String, dynamic> _segments(Map<String, dynamic> m) =>
      Map<String, dynamic>.from(m['segments'] as Map? ?? {});
  File _chunkFile(String asset, int revision, int index) =>
      File(p.join(root.path, asset, '$revision-$index.seg'));
  File? _assembledFile(Map<String, dynamic> manifest) {
    final name = manifest['assembled'];
    if (name is! String || p.basename(name) != name) return null;
    final file = File(p.join(root.path, manifest['id'], name));
    return file.existsSync() && file.lengthSync() == manifest['total']
        ? file
        : null;
  }

  bool isComplete(String episodeId, String url) {
    final m = manifest(episodeId, url), segments = _segments(m);
    final total = m['total'] as int?;
    if (total == null || total <= 0) return false;
    if (_assembledFile(m) != null) return true;
    for (var index = 0; index * podcastChunkBytes < total; index++) {
      final expected = min(
        podcastChunkBytes,
        total - index * podcastChunkBytes,
      );
      if (segments['$index'] != expected) return false;
    }
    // Waiting preparations poll for playback completion. Reject incomplete
    // metadata before statting every saved block of a long episode each tick.
    for (var index = 0; index * podcastChunkBytes < total; index++) {
      final expected = min(
        podcastChunkBytes,
        total - index * podcastChunkBytes,
      );
      final file = _chunkFile(m['id'], m['revision'] as int, index);
      if (!file.existsSync() || file.lengthSync() != expected) return false;
    }
    return true;
  }

  bool isDownloaded(String episodeId, String url) =>
      manifest(episodeId, url)['downloaded'] == true &&
      isComplete(episodeId, url);

  /// Serializes manifest writes. A waiter cancelled before it starts leaves the
  /// lane at once, so later readers are not pinned behind a dead request.
  Future<T> _serial<T>(
    String id,
    Future<T> Function() action, {
    Future<void>? cancelSignal,
    String? fence,
  }) {
    final lane = _lanes.putIfAbsent(id, () => _SerialLane());
    final item = _SerialItem<T>();
    var cancelled = false;
    cancelSignal?.then((_) {
      cancelled = true;
      if (!item.started && !item.result.isCompleted) {
        item.skipped = true;
        item.result.completeError(const HttpException('播客读取已取消'));
      }
    });
    item.body = () async {
      final owner =
          '${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextDouble()}';
      var acquired = false;
      try {
        // The background worker has its own isolate and SQLite connection.
        // The lease stops it from committing over a newer foreground revision.
        while (!acquired) {
          if (cancelled || _closed) {
            throw const HttpException('播客读取已取消');
          }
          acquired = store.transaction(() {
            final old = store.read('assetLease', id);
            final now = DateTime.now().millisecondsSinceEpoch;
            if (old != null &&
                old['owner'] != (fence ?? owner) &&
                (old['until'] as int) > now) {
              if (fence != null) {
                throw const HttpException('下载已由另一个任务接管');
              }
              return false;
            }
            store.write('assetLease', id, {
              'owner': fence ?? owner,
              'until': now + PodcastTransferPolicy.leaseTtl.inMilliseconds,
            });
            return true;
          });
          if (!acquired) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        return await action();
      } finally {
        if (acquired &&
            store.read('assetLease', id)?['owner'] == (fence ?? owner)) {
          store.remove('assetLease', id);
        }
      }
    };
    lane.pending.add(item);
    _drain(id);
    return item.result.future;
  }

  void _drain(String id) {
    final lane = _lanes[id];
    if (lane == null || lane.active) return;
    lane.active = true;
    unawaited(() async {
      while (lane.pending.isNotEmpty) {
        final item = lane.pending.removeAt(0);
        if (item.skipped) continue;
        item.started = true;
        try {
          item.result.complete(await item.body());
        } catch (error, stack) {
          if (!item.result.isCompleted) {
            item.result.completeError(error, stack);
          }
        }
      }
      lane.active = false;
      if (lane.pending.isNotEmpty) {
        _drain(id);
      } else {
        _lanes.remove(id);
      }
    }());
  }

  HttpClient _client({bool download = false}) {
    if (download) {
      final epoch = http.sharedEpoch();
      if (_downloadClient == null || _downloadEpoch != epoch) {
        _downloadClient?.close(force: false);
        _downloadClient = http.downloadClientFactory()
          ..connectionTimeout = PodcastTransferPolicy.connectTimeout
          ..idleTimeout = const Duration(seconds: 60)
          ..maxConnectionsPerHost = PodcastTransferPolicy.maxHostBulkWindows
          ..autoUncompress = false;
        _downloadEpoch = epoch;
      }
      return _downloadClient!;
    }
    final epoch = http.sharedEpoch();
    if (_sharedClient == null || _sharedEpoch != epoch) {
      // Other windows may still be receiving bytes from this client.
      _sharedClient?.close(force: false);
      _sharedClient = http.clientFactory()
        ..connectionTimeout = PodcastTransferPolicy.connectTimeout
        ..idleTimeout = const Duration(seconds: 20);
      _sharedEpoch = epoch;
    }
    return _sharedClient!;
  }

  Future<Uint8List> chunk(
    PodcastEpisode episode,
    PodcastMedia media,
    int index, {
    bool download = false,
    void Function(int bytes)? onNetworkBytes,
    Future<void>? cancelSignal,
  }) async {
    final read = cancelSignal == null ? null : _PodcastPlaybackRead(() {});
    var settled = false;
    cancelSignal?.then((_) {
      if (!settled) read?.cancel();
    });
    try {
      return await _readChunk(
        episode,
        media,
        index,
        download: download,
        playbackRead: read,
        onNetworkBytes: onNetworkBytes,
        cancelSignal: cancelSignal,
      );
    } finally {
      settled = true;
      read?.cancel();
    }
  }

  Future<Uint8List> _readChunk(
    PodcastEpisode episode,
    PodcastMedia media,
    int index, {
    bool download = false,
    Future<void> Function(Uint8List bytes, int offset)? onData,
    _PodcastPlaybackRead? playbackRead,
    void Function(int bytes)? onNetworkBytes,
    Future<void>? cancelSignal,
  }) {
    final id = assetId(episode.id, media.url);
    final revision = manifest(episode.id, media.url)['revision'] as int? ?? 0;
    final key = '$id:$revision:$index';
    final existing = _indexFlights[key];
    if (existing != null && !existing.abandoned) {
      final waiter = existing.add(
        download: download,
        onData: onData,
        onNetworkBytes: onNetworkBytes,
      );
      void leave() => existing.drop(waiter);
      playbackRead?.bind(leave);
      cancelSignal?.then((_) => leave());
      return waiter.future;
    }
    final flight = _IndexFlight();
    _indexFlights[key] = flight;
    final self = flight.add(
      download: download,
      onData: onData,
      onNetworkBytes: onNetworkBytes,
    );
    void leave() => flight.drop(self);
    playbackRead?.bind(leave);
    cancelSignal?.then((_) => leave());
    unawaited(() async {
      try {
        final data = await _loadChunk(
          episode,
          media,
          index,
          download: download,
          flight: flight,
        );
        await flight.complete(data);
      } catch (error, stack) {
        flight.fail(error, stack);
      } finally {
        if (identical(_indexFlights[key], flight)) _indexFlights.remove(key);
      }
    }());
    return self.future;
  }

  Future<Uint8List> _loadChunk(
    PodcastEpisode episode,
    PodcastMedia media,
    int index, {
    bool download = false,
    required _IndexFlight flight,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetchChunk(
          episode,
          media,
          index,
          download: download,
          flight: flight,
        );
      } on _PodcastRetryRange {
        if (flight.abandoned) throw const HttpException('播客读取已取消');
        if (attempt >= 1) throw const HttpException('节目来源连续变化，请稍后重试');
      }
    }
  }

  Future<Uint8List> _fetchChunk(
    PodcastEpisode episode,
    PodcastMedia media,
    int index, {
    bool download = false,
    required _IndexFlight flight,
  }) => _serial('${assetId(episode.id, media.url)}:$index', () async {
    if (flight.abandoned) {
      throw const HttpException('播客读取已取消');
    }
    if (_closed) throw const HttpException('播客媒体存储已关闭');
    final id = assetId(episode.id, media.url);
    var m = manifest(episode.id, media.url);
    final assembled = _assembledFile(m);
    if (assembled != null) {
      await _touch(episode, media);
      final input = await assembled.open();
      try {
        await input.setPosition(index * podcastChunkBytes);
        final data = await input.read(podcastChunkBytes);
        await flight.deliver(data, 0);
        return data;
      } finally {
        await input.close();
      }
    }
    final file = _chunkFile(id, m['revision'] as int, index);
    final length = _segments(m)['$index'];
    if (length is int && file.existsSync() && file.lengthSync() == length) {
      await _touch(episode, media);
      final data = await file.readAsBytes();
      await flight.deliver(data, 0);
      return data;
    }
    requirePodcastRssMedia(episode, media);
    final client = _client(download: download);
    final start = index * podcastChunkBytes,
        end = start + podcastChunkBytes - 1;
    final response = await _openRange(
      client,
      media,
      m,
      start,
      end,
      cancelSignal: flight.cancelled,
      requestTimeout: download ? null : playbackRequestTimeout,
    );
    if (response.statusCode == 416) {
      throw const HttpException('媒体范围无效，请刷新节目后重试');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('媒体来源返回 ${response.statusCode}');
    }
    final range = response.headers.value('content-range');
    final rangeMatch = range == null
        ? null
        : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(range);
    if (response.statusCode == 206 &&
        (rangeMatch == null || int.parse(rangeMatch[1]!) != start)) {
      throw const HttpException('来源返回了错误的数据范围');
    }
    final total = response.statusCode == 206
        ? int.tryParse(rangeMatch![3]!)
        : (response.contentLength >= 0 ? response.contentLength : null);
    final etag = response.headers.value('etag'),
        modified = response.headers.value('last-modified');
    final changed =
        (m['etag'] != null && etag != null && m['etag'] != etag) ||
        (m['modified'] != null &&
            modified != null &&
            m['modified'] != modified) ||
        (m['total'] != null && total != null && m['total'] != total);
    if (changed) {
      m = {
        ...m,
        'segments': <String, dynamic>{},
        'revision': (m['revision'] as int) + 1,
        'downloaded': false,
      };
      // Never splice data from different versions, even during a resumed download.
      m.remove('assembled');
    }
    // If-Range may return a whole new representation. Save its validators
    // and retry a real Range instead of discarding a 30-minute prefix.
    if (changed && response.statusCode == 200 && start > 0) {
      await _serial(id, () async {
        final latest = manifest(episode.id, media.url);
        if (latest['revision'] == (m['revision'] as int) - 1) {
          if (etag != null) m['etag'] = etag;
          if (modified != null) m['modified'] = modified;
          if (total != null) m['total'] = total;
          store.write('asset', id, m, channel: episode.channelId);
        }
      });
      throw const _PodcastRetryRange();
    }
    if (etag != null) m['etag'] = etag;
    if (modified != null) m['modified'] = modified;
    if (total != null) m['total'] = total;
    m['mime'] = response.headers.contentType?.mimeType ?? media.mimeType;
    m['rangeUnsupported'] = response.statusCode == 200;
    var skip = response.statusCode == 200 ? start : 0;
    final buffer = BytesBuilder(copy: false);
    var ended = true;
    NetworkMediaResponse wrap(HttpClientResponse value) {
      // Cancel the HTTP subscription itself. Cancelling only the async*
      // recovery stream waits for its pending body read (up to the idle timeout)
      // and pins the serial lane when a seek needs this same cache chunk.
      StreamSubscription<List<int>>? upstream;
      late StreamController<List<int>> body;
      var closed = false;
      Future<void> close() async {
        if (closed) return;
        closed = true;
        if (upstream != null) {
          await upstream!.cancel();
        } else {
          await value.listen((_) {}).cancel();
        }
        if (!body.isClosed) unawaited(body.close());
      }

      body = StreamController<List<int>>(
        onListen: () {
          if (closed) return;
          upstream = value.listen(
            body.add,
            onError: body.addError,
            onDone: () => unawaited(body.close()),
          );
        },
        onPause: () => upstream?.pause(),
        onResume: () => upstream?.resume(),
        onCancel: close,
      );
      flight.bindStop(() => unawaited(close()));
      return NetworkMediaResponse(
        status: value.statusCode,
        headers: {
          for (final name in [
            HttpHeaders.contentLengthHeader,
            HttpHeaders.contentRangeHeader,
            HttpHeaders.etagHeader,
            HttpHeaders.lastModifiedHeader,
          ])
            if (value.headers.value(name) != null)
              name: value.headers.value(name)!,
        },
        body: body.stream,
        close: close,
      );
    }

    final incoming = StreamController<List<int>>();
    final subscription =
        recoverableMediaStream(
          initial: wrap(response),
          idleTimeout: bodyIdleTimeout,
          checkCancelled: () {
            if (_closed || flight.abandoned) throw StateError('播客读取已取消');
          },
          reopen: (nextStart, nextEnd, validator) async => wrap(
            await _openRange(
              _client(download: download),
              media,
              m,
              nextStart,
              nextEnd ?? end,
              cancelSignal: flight.cancelled,
              requestTimeout: download ? null : playbackRequestTimeout,
            ),
          ),
        ).listen(
          incoming.add,
          onError: incoming.addError,
          onDone: () {
            if (!incoming.isClosed) incoming.close();
          },
        );
    // Cancelling one consumer stops this response only when nobody else
    // still needs the bytes. The shared client stays open for the next range.
    flight.bindStop(() {
      // Cancelling a seek may interrupt a pending reconnect check. Its
      // cancellation future is intentionally consumed, not an app error.
      unawaited(subscription.cancel().catchError((Object _) {}));
      if (!incoming.isClosed) unawaited(incoming.close());
    });
    try {
      await for (final bytes in incoming.stream) {
        if (flight.abandoned) {
          throw const HttpException('播客读取已取消');
        }
        flight.forwardNetwork(bytes.length);
        var offset = 0;
        if (skip > 0) {
          final discarded = min(skip, bytes.length);
          skip -= discarded;
          offset += discarded;
        }
        if (offset < bytes.length) {
          final take = min(
            podcastChunkBytes - buffer.length,
            bytes.length - offset,
          );
          final piece = Uint8List.sublistView(
            Uint8List.fromList(bytes),
            offset,
            offset + take,
          );
          final pieceOffset = buffer.length;
          buffer.add(piece);
          await flight.deliver(piece, pieceOffset);
        }
        if (buffer.length == podcastChunkBytes) {
          ended = false;
          break;
        }
      }
    } finally {
      await subscription.cancel();
      if (!incoming.isClosed) await incoming.close();
    }
    final data = buffer.takeBytes();
    if (data.isEmpty && skip == 0 && ended && total == null && start > 0) {
      m['total'] = start;
      await _serial(id, () async {
        final latest = manifest(episode.id, media.url);
        latest['total'] = start;
        store.write('asset', id, latest, channel: episode.channelId);
      });
      return data;
    }
    if (data.isEmpty || skip > 0) throw const HttpException('节目数据不完整');
    if (ended && total == null) m['total'] = start + data.length;
    final expected = (m['total'] is int)
        ? min(podcastChunkBytes, (m['total'] as int) - start)
        : null;
    if (expected != null && data.length != expected) {
      throw const HttpException('节目数据中断，请重试');
    }
    await _serial(id, () async {
      final latest = manifest(episode.id, media.url);
      final originalRevision = changed
          ? (m['revision'] as int) - 1
          : m['revision'];
      if (latest['revision'] != originalRevision &&
          ((etag != null && latest['etag'] != etag) ||
              (modified != null && latest['modified'] != modified) ||
              (m['total'] != null &&
                  latest['total'] != null &&
                  latest['total'] != m['total']))) {
        throw const HttpException('节目来源版本发生变化，请重试');
      }
      if (latest['revision'] != originalRevision || !changed) {
        m = {
          ...latest,
          ...m,
          'revision': latest['revision'],
          'segments': latest['segments'],
          'downloaded': latest['downloaded'],
        };
        if (latest['assembled'] != null) m['assembled'] = latest['assembled'];
      }
      var persist =
          download ||
          store.effective(episode.channelId).flag('cacheEnabled') ||
          m['downloaded'] == true;
      if (persist && !download && m['downloaded'] != true) {
        final settings = store.effective(episode.channelId);
        final channelBytes = store
            .list('asset', channel: episode.channelId)
            .where((a) => a['downloaded'] != true)
            .fold<int>(0, (sum, a) => sum + bytesFor(a));
        if (cacheBytes + data.length >
                store.preferences.integer('cacheLimitMb') * 1024 * 1024 ||
            channelBytes + data.length >
                settings.integer('channelCacheMb') * 1024 * 1024) {
          persist = false;
        }
      }
      if (persist && _assembledFile(m) == null) {
        final target = _chunkFile(id, m['revision'] as int, index);
        await target.parent.create(recursive: true);
        final temporary = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await temporary.writeAsBytes(data, flush: true);
        if (target.existsSync()) await target.delete();
        await temporary.rename(target.path);
        final segments = _segments(m)..['$index'] = data.length;
        m['segments'] = segments;
      }
      m['accessed'] = DateTime.now().millisecondsSinceEpoch;
      store.write('asset', id, m, channel: episode.channelId);
    });
    return data;
  }, cancelSignal: flight.cancelled);

  Future<void> _touch(PodcastEpisode episode, PodcastMedia media) => _serial(
    assetId(episode.id, media.url),
    () async {
      final current = manifest(episode.id, media.url)
        ..['accessed'] = DateTime.now().millisecondsSinceEpoch;
      store.write('asset', current['id'], current, channel: episode.channelId);
    },
  );

  Future<HttpClientResponse> _request(
    HttpClient client,
    Uri uri,
    Map<String, String> headers, {
    Future<void>? cancelSignal,
    Duration? timeout,
  }) async {
    final elapsed = Stopwatch()..start();
    Duration bounded(Duration cap) {
      if (timeout == null) return cap;
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('播客连接超时', timeout);
      }
      return remaining < cap ? remaining : cap;
    }

    HttpClientRequest? active;
    var cancelled = false, settled = false;
    final cancellation = PodcastTransferException(
      '播客读取已取消',
      kind: PodcastTransferFailureKind.cancelled,
    );
    cancelSignal?.then((_) {
      cancelled = true;
      if (!settled) active?.abort(cancellation);
    });
    try {
      final opening = client.getUrl(uri);
      unawaited(
        opening.then<void>((request) {
          if (cancelled || settled) request.abort(cancellation);
        }, onError: (Object _) {}),
      );
      final request = await Future.any<HttpClientRequest>([
        opening,
        if (cancelSignal != null)
          cancelSignal.then<HttpClientRequest>((_) => throw cancellation),
      ]).timeout(bounded(PodcastTransferPolicy.requestTimeout));
      active = request;
      if (cancelled) {
        request.abort(cancellation);
        throw cancellation;
      }
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        bounded(PodcastTransferPolicy.headerTimeout),
      );
      if (http.isConnectionFailure(response)) {
        await response.listen((_) {}).cancel();
        throw const SocketException('设备代理连接失败');
      }
      if (cancelled) {
        await response.listen((_) {}).cancel();
        throw cancellation;
      }
      return response;
    } catch (_) {
      active?.abort();
      rethrow;
    } finally {
      settled = true;
    }
  }

  Future<HttpClientResponse> _openRange(
    HttpClient client,
    PodcastMedia media,
    Map<String, dynamic> manifest,
    int start,
    int end, {
    Future<void>? cancelSignal,
    Duration? requestTimeout,
  }) async {
    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    for (var attempt = 0; ; attempt++) {
      try {
        return await _openRangeBody(
          client,
          media,
          manifest,
          start,
          end,
          cancelSignal: cancelSignal,
          requestTimeout: requestTimeout,
        );
      } catch (error) {
        if (_closed || cancelled) rethrow;
        http.connectionFailed(
          Uri.parse(manifest['resolvedUrl'] as String? ?? media.url),
          error,
        );
        final transient =
            error is SocketException ||
            error is TimeoutException ||
            error is HttpException && error is! PodcastTransferException;
        if (attempt >= 1 || !transient) rethrow;
        // Routing is evaluated for each request. Use the selected alternate
        // now, rather than failing this open and requiring a second play tap.
        // A configured route is retained and may reconnect once as well.
        developer.log(
          'Retrying interrupted podcast media connection',
          name: 'PodcastMediaStore',
          error: error,
        );
      }
    }
  }

  Future<HttpClientResponse> _openRangeBody(
    HttpClient client,
    PodcastMedia media,
    Map<String, dynamic> manifest,
    int start,
    int end, {
    Future<void>? cancelSignal,
    Duration? requestTimeout,
  }) async {
    final resolved = manifest['resolvedUrl'] as String?;
    final fresh =
        DateTime.now().millisecondsSinceEpoch -
            (manifest['resolvedAt'] as int? ?? 0) <
        const Duration(minutes: 30).inMilliseconds;
    final candidate =
        fresh &&
            resolved != null &&
            ['http', 'https'].contains(Uri.tryParse(resolved)?.scheme)
        ? resolved
        : media.url;
    for (var attempt = 0; ; attempt++) {
      final source = Uri.parse(attempt == 0 ? candidate : media.url);
      final validator = manifest['etag'] ?? manifest['modified'];
      final response = await _request(
        client,
        source,
        {
          'Range': 'bytes=$start-$end',
          'Accept-Encoding': 'identity',
          'User-Agent': 'FluentPlayer/1.0 Podcast',
          if (validator is String && !validator.startsWith('W/'))
            'If-Range': validator,
        },
        cancelSignal: cancelSignal,
        timeout: requestTimeout,
      );
      final actualStart = RegExp(
        r'^bytes (\d+)-',
      ).firstMatch(response.headers.value('content-range') ?? '')?.group(1);
      if (attempt == 0 &&
          candidate != media.url &&
          ([401, 403, 404, 410].contains(response.statusCode) ||
              (response.statusCode == 200 && start > 0) ||
              (response.statusCode == 206 &&
                  int.tryParse(actualStart ?? '') != start))) {
        await response.listen((_) {}).cancel();
        continue;
      }
      var finalUri = source;
      for (final redirect in response.redirects) {
        finalUri = finalUri.resolveUri(redirect.location);
      }
      if (response.statusCode == 200 || response.statusCode == 206) {
        manifest['resolvedUrl'] = finalUri.toString();
        manifest['resolvedAt'] = DateTime.now().millisecondsSinceEpoch;
      }
      return response;
    }
  }

  /// Stop active playback reads, for example when closing an obsolete session.
  /// Offline downloads use independent requests and keep their saved progress.
  void prioritizePlayback(String episodeId, [String? url]) {
    final assets = url != null
        ? [assetId(episodeId, url)]
        : _sources.entries
              .where((entry) => entry.value.$1.id == episodeId)
              .map((entry) => entry.key)
              .toList();
    for (final asset in assets) {
      for (final read
          in _playbackReads[asset]?.toList() ?? <_PodcastPlaybackRead>[]) {
        read.cancel();
      }
    }
  }

  void prepareForSeek(String episodeId) {
    // Keep the current response alive until the decoder requests its new Range;
    // ending it before the native seek can make the decoder incorrectly see EOF.
    _seekPending.addAll(
      _sources.entries
          .where((entry) => entry.value.$1.id == episodeId)
          .map((entry) => entry.key),
    );
  }

  Future<void> _probe(
    PodcastEpisode episode,
    PodcastMedia media,
    _PodcastPlaybackRead read,
  ) async {
    requirePodcastRssMedia(episode, media);
    final client = _client();
    HttpClientResponse? opened;
    try {
      read.attach(client);
      final resolved = manifest(episode.id, media.url);
      final response = await _openRange(
        client,
        media,
        resolved,
        0,
        0,
        cancelSignal: read.stopped,
        requestTimeout: playbackRequestTimeout,
      );
      opened = response;
      read.check();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('媒体来源返回 ${response.statusCode}');
      }
      final range = RegExp(
        r'^bytes 0-\d+/(\d+)$',
      ).firstMatch(response.headers.value('content-range') ?? '');
      final total = response.statusCode == 206
          ? int.tryParse(range?[1] ?? '')
          : response.contentLength > 0
          ? response.contentLength
          : null;
      final id = assetId(episode.id, media.url);
      await _serial(id, () async {
        read.check();
        final m = manifest(episode.id, media.url);
        m['resolvedUrl'] = resolved['resolvedUrl'];
        m['resolvedAt'] = resolved['resolvedAt'];
        if (total != null) m['total'] = total;
        m['mime'] = response.headers.contentType?.mimeType ?? media.mimeType;
        m['rangeUnsupported'] = response.statusCode == 200;
        // Chunk requests validate the resource before adding media bytes.
        store.write('asset', id, m, channel: episode.channelId);
      });
    } finally {
      if (opened != null) await opened.listen((_) {}).cancel();
      read.detach(client);
    }
  }

  Set<int> _presentSegments(PodcastEpisode episode, PodcastMedia media) {
    final current = manifest(episode.id, media.url);
    final id = assetId(episode.id, media.url);
    final revision = current['revision'] as int? ?? 0;
    return _segments(current).entries
        .where((entry) {
          final index = int.tryParse(entry.key);
          if (index == null || entry.value is! int) return false;
          final file = _chunkFile(id, revision, index);
          return file.existsSync() && file.lengthSync() == entry.value;
        })
        .map((entry) => int.parse(entry.key))
        .toSet();
  }

  /// Validate one small window before enabling two larger, disjoint requests.
  /// Completed disk chunks remain 1 MiB and playback can join any active chunk.
  Future<({bool complete, bool stopped})> fillWindow(
    PodcastEpisode episode,
    PodcastMedia media, {
    required bool Function() shouldContinue,
    void Function(int bytes)? onNetworkBytes,
    void Function(int committed, int inFlight)? onUseful,
    Future<void>? cancelSignal,
    void Function(String message, bool rateLimited)? onWaiting,
  }) async {
    requirePodcastRssMedia(episode, media);
    // Join any playback request that already owns a missing chunk instead of
    // fetching the same bytes again inside a larger download window.
    final prefix =
        '${assetId(episode.id, media.url)}:${manifest(episode.id, media.url)['revision']}:';
    final joined = <(_IndexFlight, _FlightWaiter)>[];
    for (final entry in _indexFlights.entries.toList()) {
      if (entry.key.startsWith(prefix) && !entry.value.abandoned) {
        joined.add((
          entry.value,
          entry.value.add(download: true, onNetworkBytes: onNetworkBytes),
        ));
      }
    }
    try {
      if (joined.isNotEmpty) {
        await Future.any<void>([
          Future.wait(
            joined.map((entry) => entry.$2.future),
          ).then<void>((_) {}),
          if (cancelSignal != null)
            cancelSignal.then<void>(
              (_) => throw PodcastTransferException(
                '播客下载已暂停',
                kind: PodcastTransferFailureKind.cancelled,
              ),
            ),
        ]);
      }
    } finally {
      for (final (flight, waiter) in joined) {
        flight.drop(waiter);
      }
    }
    for (var guard = 0; guard < 3; guard++) {
      final current = manifest(episode.id, media.url);
      if (current['rangeUnsupported'] == true) {
        final complete = await fillSequential(
          episode,
          media,
          onProgress: (received, total) {
            onUseful?.call(received, 0);
            return shouldContinue();
          },
          onNetworkBytes: onNetworkBytes,
          cancelSignal: cancelSignal,
          onWaiting: onWaiting,
        );
        return (complete: complete, stopped: !complete);
      }
      // A feed's length alone does not prove Range support or resource identity.
      final validated =
          current['rangeUnsupported'] == false &&
          current['total'] is int &&
          ((current['etag'] is String &&
                  !(current['etag'] as String).startsWith('W/')) ||
              current['modified'] != null);
      final planned = planPodcastWindows(
        total: current['total'] as int? ?? media.length,
        present: _presentSegments(episode, media),
        windowBytes: validated
            ? PodcastTransferPolicy.bulkWindowBytes
            : PodcastTransferPolicy.windowBytes,
        maxWindows: validated ? PodcastTransferPolicy.maxWindowsPerAsset : 1,
      );
      if (planned.isEmpty) {
        return (complete: isComplete(episode.id, media.url), stopped: false);
      }
      final stop = Completer<void>();
      var stopped = false;
      var sequential = false;
      final reused = cachedBytes(episode.id, media.url);
      final committed = <int, int>{};
      final inFlight = <int, int>{};
      cancelSignal?.then((_) {
        if (!stop.isCompleted) stop.complete();
      });
      try {
        await Future.wait(
          planned.map((window) async {
            try {
              final result = await _transferWindow(
                episode,
                media,
                window,
                shouldContinue: () => !stop.isCompleted && shouldContinue(),
                onNetworkBytes: onNetworkBytes,
                onUseful: (saved, pending) {
                  committed[window.start] = saved;
                  inFlight[window.start] = pending;
                  onUseful?.call(
                    reused + committed.values.fold<int>(0, (a, b) => a + b),
                    inFlight.values.fold<int>(0, (a, b) => a + b),
                  );
                },
                cancelSignal: stop.future,
                onWaiting: onWaiting,
              );
              if (result == _WindowStop.sequential) {
                sequential = true;
                if (!stop.isCompleted) stop.complete();
              } else if (result == _WindowStop.stopped) {
                stopped = true;
                if (!stop.isCompleted) stop.complete();
              }
            } catch (error) {
              if (error is PodcastTransferException &&
                  error.kind == PodcastTransferFailureKind.cancelled &&
                  (stop.isCompleted || !shouldContinue())) {
                stopped = true;
                return;
              }
              if (!stop.isCompleted) stop.complete();
              rethrow;
            }
          }),
        );
        if (sequential && shouldContinue()) {
          final complete = await fillSequential(
            episode,
            media,
            onProgress: (received, total) {
              onUseful?.call(received, 0);
              return shouldContinue();
            },
            onNetworkBytes: onNetworkBytes,
            cancelSignal: cancelSignal,
            onWaiting: onWaiting,
          );
          return (complete: complete, stopped: !complete);
        }
        return (complete: isComplete(episode.id, media.url), stopped: stopped);
      } on _PodcastRetryRange {
        if (guard == 2) throw const HttpException('节目来源连续变化，请稍后重试');
      } finally {
        if (!stop.isCompleted) stop.complete();
      }
    }
    throw StateError('unreachable');
  }

  Uri _downloadSource(PodcastEpisode episode, PodcastMedia media) {
    final current = manifest(episode.id, media.url);
    return Uri.parse(current['resolvedUrl'] as String? ?? media.url);
  }

  Future<_WindowStop> _transferWindow(
    PodcastEpisode episode,
    PodcastMedia media,
    PodcastByteWindow window, {
    required bool Function() shouldContinue,
    void Function(int bytes)? onNetworkBytes,
    void Function(int committed, int inFlight)? onUseful,
    Future<void>? cancelSignal,
    void Function(String message, bool rateLimited)? onWaiting,
  }) => _downloadGate.run(
    _downloadSource(episode, media),
    () => _transferWindowBody(
      episode,
      media,
      window,
      shouldContinue: shouldContinue,
      onNetworkBytes: onNetworkBytes,
      onUseful: onUseful,
      cancelSignal: cancelSignal,
    ),
    shouldContinue: shouldContinue,
    cancelSignal: cancelSignal,
    onWaiting: onWaiting,
  );

  Future<_WindowStop> _transferWindowBody(
    PodcastEpisode episode,
    PodcastMedia media,
    PodcastByteWindow window, {
    required bool Function() shouldContinue,
    void Function(int bytes)? onNetworkBytes,
    void Function(int committed, int inFlight)? onUseful,
    Future<void>? cancelSignal,
  }) async {
    final id = assetId(episode.id, media.url);
    final snapshot = manifest(episode.id, media.url);
    final reused = bytesFor(snapshot);
    final revision = snapshot['revision'] as int? ?? 0;
    final owner =
        'win-$revision-${window.start}-${DateTime.now().microsecondsSinceEpoch}';
    final flights = <int, _FlightWaiter>{};
    for (
      var index = window.start ~/ podcastChunkBytes;
      index * podcastChunkBytes <= window.endInclusive;
      index++
    ) {
      final key = '$id:$revision:$index';
      final flight = _indexFlights.putIfAbsent(key, () => _IndexFlight());
      flights[index] = flight.add(download: true);
    }
    final client = _client(download: true);
    try {
      final response = await _openRange(
        client,
        media,
        snapshot,
        window.start,
        window.endInclusive,
        cancelSignal: cancelSignal,
      );
      final verdict = interpretPodcastResponse(
        status: response.statusCode,
        requestStart: window.start,
        requestEnd: window.endInclusive,
        contentRange: response.headers.value('content-range'),
        contentLength: response.contentLength,
        etag: response.headers.value('etag'),
        modified: response.headers.value('last-modified'),
        mime: response.headers.contentType?.mimeType,
        previousEtag: snapshot['etag'] as String?,
        previousModified: snapshot['modified'] as String?,
        previousTotal: snapshot['total'] as int?,
        retryAfter: response.headers.value('retry-after'),
      );
      if (verdict.endOfFile) {
        await response.listen((_) {}).cancel();
        return _WindowStop.done;
      }
      final resolved = Uri.parse(
        snapshot['resolvedUrl'] as String? ?? media.url,
      );
      _downloadGate.observe(
        resolved,
        response.statusCode,
        response.headers.value('retry-after'),
      );
      if (resolved.host != Uri.parse(media.url).host) {
        _downloadGate.observe(
          Uri.parse(media.url),
          response.statusCode,
          response.headers.value('retry-after'),
        );
      }
      if (verdict.failure != null) {
        await response.listen((_) {}).cancel();
        throw PodcastTransferException(
          verdict.failure!,
          kind: verdict.kind,
          retryable: verdict.retryable,
          retryAfter: verdict.retryAfter,
        );
      }
      if (verdict.versionChanged) {
        await response.listen((_) {}).cancel();
        await _serial(id, () async {
          final latest = manifest(episode.id, media.url);
          if (latest['revision'] != revision) throw const _PodcastRetryRange();
          latest['revision'] = (latest['revision'] as int) + 1;
          latest['segments'] = <String, dynamic>{};
          latest['downloaded'] = false;
          latest.remove('assembled');
          if (verdict.etag != null) latest['etag'] = verdict.etag;
          if (verdict.modified != null) latest['modified'] = verdict.modified;
          if (verdict.total != null) latest['total'] = verdict.total;
          store.write('asset', id, latest, channel: episode.channelId);
        });
        throw const _PodcastRetryRange();
      }
      if (verdict.rangeIgnored) {
        await _serial(id, () async {
          final latest = manifest(episode.id, media.url);
          latest['rangeUnsupported'] = true;
          if (verdict.etag != null) latest['etag'] = verdict.etag;
          if (verdict.total != null) latest['total'] = verdict.total;
          store.write('asset', id, latest, channel: episode.channelId);
        });
        if (snapshot['rangeUnsupported'] == false) {
          // A formerly ranged source changed behavior. Stop the entire parallel
          // batch before opening exactly one sequential fallback.
          await response.listen((_) {}).cancel();
          return _WindowStop.sequential;
        }
        final complete = await _fillSequential(
          episode,
          media,
          initialResponse: response,
          onProgress: (received, total) {
            onUseful?.call(max(0, received - reused), 0);
            return shouldContinue();
          },
          onNetworkBytes: onNetworkBytes,
          cancelSignal: cancelSignal,
        );
        return complete ? _WindowStop.done : _WindowStop.stopped;
      }
      await _serial(id, () async {
        final latest = manifest(episode.id, media.url);
        if (latest['revision'] != revision) throw const _PodcastRetryRange();
        latest['rangeUnsupported'] = false;
        latest['resolvedUrl'] = snapshot['resolvedUrl'];
        latest['resolvedAt'] = snapshot['resolvedAt'];
        if (verdict.etag != null) latest['etag'] = verdict.etag;
        if (verdict.modified != null) latest['modified'] = verdict.modified;
        if (verdict.total != null) latest['total'] = verdict.total;
        store.write('asset', id, latest, channel: episode.channelId);
      });
      late final StreamSubscription<List<int>> subscription;
      final incoming = StreamController<List<int>>(
        sync: true,
        onPause: () => subscription.pause(),
        onResume: () => subscription.resume(),
      );
      subscription = response
          .timeout(bodyIdleTimeout)
          .listen(
            incoming.add,
            onError: incoming.addError,
            onDone: () {
              if (!incoming.isClosed) incoming.close();
            },
          );
      cancelSignal?.then((_) {
        if (!incoming.isClosed) incoming.close();
        subscription.cancel();
      });
      final buffer = BytesBuilder(copy: false);
      var produced = 0;
      var index = window.start ~/ podcastChunkBytes;
      var sniffed = false;
      try {
        await for (final part in incoming.stream) {
          if (!shouldContinue()) return _WindowStop.stopped;
          if (!sniffed) {
            sniffed = true;
            if (podcastBodyLooksLikeError(verdict.mime, part)) {
              throw PodcastTransferException(
                '来源返回的不是媒体数据',
                kind: PodcastTransferFailureKind.media,
              );
            }
          }
          if (produced + part.length > verdict.bodyEnd! - window.start + 1) {
            throw PodcastTransferException(
              '来源返回了错误的数据范围',
              kind: PodcastTransferFailureKind.range,
            );
          }
          onNetworkBytes?.call(part.length);
          final data = part is Uint8List ? part : Uint8List.fromList(part);
          var offset = 0;
          while (offset < part.length) {
            final take = min(
              podcastChunkBytes - buffer.length,
              part.length - offset,
            );
            final piece = Uint8List.sublistView(data, offset, offset + take);
            final pieceOffset = buffer.length;
            buffer.add(piece);
            await _indexFlights['$id:$revision:$index']?.deliver(
              piece,
              pieceOffset,
            );
            offset += take;
            produced += take;
            onUseful?.call(produced - buffer.length, buffer.length);
            if (buffer.length == podcastChunkBytes ||
                (verdict.total != null &&
                    index * podcastChunkBytes + buffer.length >=
                        verdict.total!)) {
              final bytes = buffer.takeBytes();
              await _commitChunk(
                episode,
                media.url,
                id,
                revision,
                index,
                bytes,
                verdict,
                owner,
              );
              await _indexFlights['$id:$revision:$index']?.complete(bytes);
              _indexFlights.remove('$id:$revision:$index');
              index++;
              onUseful?.call(produced, 0);
            }
          }
        }
      } finally {
        await subscription.cancel();
        if (!incoming.isClosed) await incoming.close();
      }
      if (buffer.isNotEmpty && shouldContinue()) {
        final bytes = buffer.takeBytes();
        final atEnd =
            verdict.total != null &&
            index * podcastChunkBytes + bytes.length >= verdict.total!;
        if (bytes.length == podcastChunkBytes || atEnd) {
          await _commitChunk(
            episode,
            media.url,
            id,
            revision,
            index,
            bytes,
            verdict,
            owner,
          );
          await _indexFlights['$id:$revision:$index']?.complete(bytes);
          _indexFlights.remove('$id:$revision:$index');
        }
      }
      final expected = verdict.bodyEnd! - window.start + 1;
      if (produced != expected) {
        throw const HttpException('节目数据中断，请重试');
      }
      return _WindowStop.done;
    } catch (error, stack) {
      http.connectionFailed(
        Uri.parse(snapshot['resolvedUrl'] as String? ?? media.url),
        error,
      );
      for (final index in flights.keys) {
        _indexFlights['$id:$revision:$index']?.fail(error, stack);
      }
      rethrow;
    } finally {
      for (final entry in flights.entries) {
        final key = '$id:$revision:${entry.key}';
        final flight = _indexFlights[key];
        if (flight != null) {
          // A stopped window no longer has a producer. Never leave playback
          // readers or a subsequent download joining an orphaned future.
          flight.fail(
            PodcastTransferException(
              '播客读取已中断，请重试',
              kind: PodcastTransferFailureKind.cancelled,
            ),
            StackTrace.current,
          );
          _indexFlights.remove(key);
        }
      }
    }
  }

  Future<void> _commitChunk(
    PodcastEpisode episode,
    String url,
    String id,
    int revision,
    int index,
    Uint8List bytes,
    PodcastRangeVerdict verdict,
    String owner,
  ) async {
    final target = _chunkFile(id, revision, index);
    final temporary = File('${target.path}.$owner.part');
    await target.parent.create(recursive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await _serial(id, () async {
        final m = manifest(episode.id, url);
        if (m['revision'] != revision) {
          throw const HttpException('节目来源版本发生变化，请重试');
        }
        if ((m['etag'] != null &&
                verdict.etag != null &&
                m['etag'] != verdict.etag) ||
            (m['modified'] != null &&
                verdict.modified != null &&
                m['modified'] != verdict.modified) ||
            (m['total'] != null &&
                verdict.total != null &&
                m['total'] != verdict.total)) {
          throw const _PodcastRetryRange();
        }
        if (verdict.etag != null) m['etag'] = verdict.etag;
        if (verdict.modified != null) m['modified'] = verdict.modified;
        if (verdict.total != null) m['total'] = verdict.total;
        if (verdict.mime != null) m['mime'] = verdict.mime;
        if (_assembledFile(m) == null) {
          if (target.existsSync()) await target.delete();
          await temporary.rename(target.path);
          final segments = _segments(m)..['$index'] = bytes.length;
          m['segments'] = segments;
        }
        m['accessed'] = DateTime.now().millisecondsSinceEpoch;
        store.write('asset', id, m, channel: episode.channelId);
      }, fence: owner);
    } catch (_) {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
  }

  /// A server ignoring Range must be read once, rather than re-reading its
  /// entire prefix for each missing megabyte. Release the asset lease between
  /// writes so playback can reuse each completed chunk immediately.
  Future<bool> fillSequential(
    PodcastEpisode episode,
    PodcastMedia media, {
    required bool Function(int received, int? total) onProgress,
    void Function(int bytes)? onNetworkBytes,
    Future<void>? cancelSignal,
    void Function(String message, bool rateLimited)? onWaiting,
  }) async {
    return _downloadGate.run(
      _downloadSource(episode, media),
      () => _fillSequential(
        episode,
        media,
        onProgress: onProgress,
        onNetworkBytes: onNetworkBytes,
        cancelSignal: cancelSignal,
      ),
      shouldContinue: () =>
          !_closed &&
          onProgress(
            cachedBytes(episode.id, media.url),
            manifest(episode.id, media.url)['total'] as int? ?? media.length,
          ),
      cancelSignal: cancelSignal,
      onWaiting: onWaiting,
    );
  }

  Future<HttpClientResponse> _openSequential(
    HttpClient client,
    PodcastMedia media, {
    Future<void>? cancelSignal,
  }) => _request(client, Uri.parse(media.url), {
    'Accept-Encoding': 'identity',
    'User-Agent': 'FluentPlayer/1.0 Podcast',
  }, cancelSignal: cancelSignal);

  Future<bool> _fillSequential(
    PodcastEpisode episode,
    PodcastMedia media, {
    required bool Function(int received, int? total) onProgress,
    void Function(int bytes)? onNetworkBytes,
    Future<void>? cancelSignal,
    HttpClientResponse? initialResponse,
  }) async {
    final id = assetId(episode.id, media.url);
    final client = _client(download: true);
    var settled = false;
    StreamSubscription<List<int>>? body;
    cancelSignal?.then((_) async {
      if (!settled) await body?.cancel();
    });
    try {
      final response =
          initialResponse ??
          await _openSequential(client, media, cancelSignal: cancelSignal);
      _downloadGate.observe(
        _downloadSource(episode, media),
        response.statusCode,
        response.headers.value('retry-after'),
      );
      if (response.statusCode != 200) {
        await response.listen((_) {}).cancel();
        throw PodcastTransferException(
          '媒体来源返回 ${response.statusCode}',
          kind: PodcastTransferFailureKind.network,
          retryable:
              response.statusCode == 429 ||
              response.statusCode == 503 ||
              response.statusCode >= 500,
          retryAfter: parseRetryAfter(response.headers.value('retry-after')),
        );
      }
      final total = response.contentLength >= 0 ? response.contentLength : null;
      final etag = response.headers.value('etag'),
          modified = response.headers.value('last-modified');
      var revision = 0;
      await _serial(id, () async {
        var m = manifest(episode.id, media.url);
        final changed =
            (m['etag'] != null && etag != null && m['etag'] != etag) ||
            (m['modified'] != null &&
                modified != null &&
                m['modified'] != modified) ||
            (m['total'] != null && total != null && m['total'] != total);
        if (changed) {
          m = {
            ...m,
            'revision': (m['revision'] as int) + 1,
            'segments': <String, dynamic>{},
            'downloaded': false,
          }..remove('assembled');
        }
        revision = m['revision'] as int;
        if (etag != null) m['etag'] = etag;
        if (modified != null) m['modified'] = modified;
        if (total != null) m['total'] = total;
        m['mime'] = response.headers.contentType?.mimeType ?? media.mimeType;
        m['rangeUnsupported'] = true;
        store.write('asset', id, m, channel: episode.channelId);
      });
      if (!onProgress(cachedBytes(episode.id, media.url), total)) return false;
      var index = 0, consumed = 0;
      final pending = BytesBuilder(copy: false);
      Future<bool> commit() async {
        final bytes = pending.takeBytes();
        if (bytes.isEmpty) return true;
        final currentIndex = index++;
        consumed += bytes.length;
        await _serial(id, () async {
          final m = manifest(episode.id, media.url);
          if (m['revision'] != revision) {
            throw const HttpException('节目来源版本发生变化，请重试');
          }
          final segments = _segments(m);
          final target = _chunkFile(id, revision, currentIndex);
          if (_assembledFile(m) == null &&
              (segments['$currentIndex'] != bytes.length ||
                  !target.existsSync())) {
            await target.parent.create(recursive: true);
            final temp = File(
              '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
            );
            await temp.writeAsBytes(bytes, flush: true);
            if (target.existsSync()) await target.delete();
            await temp.rename(target.path);
            segments['$currentIndex'] = bytes.length;
          }
          m['segments'] = segments;
          m['accessed'] = DateTime.now().millisecondsSinceEpoch;
          store.write('asset', id, m, channel: episode.channelId);
        });
        return !_closed &&
            onProgress(cachedBytes(episode.id, media.url), total);
      }

      final incoming = StreamController<List<int>>(
        sync: true,
        onPause: () => body?.pause(),
        onResume: () => body?.resume(),
      );
      body = response
          .timeout(bodyIdleTimeout)
          .listen(
            incoming.add,
            onError: incoming.addError,
            onDone: () {
              if (!incoming.isClosed) incoming.close();
            },
          );
      cancelSignal?.then((_) async {
        await body?.cancel();
        if (!incoming.isClosed) await incoming.close();
      });
      await for (final part in incoming.stream) {
        onNetworkBytes?.call(part.length);
        if (consumed == 0 &&
            pending.isEmpty &&
            podcastBodyLooksLikeError(
              response.headers.contentType?.mimeType,
              part,
            )) {
          throw PodcastTransferException(
            '来源返回的不是媒体数据',
            kind: PodcastTransferFailureKind.media,
          );
        }
        final data = part is Uint8List ? part : Uint8List.fromList(part);
        var offset = 0;
        while (offset < part.length) {
          final take = min(
            podcastChunkBytes - pending.length,
            part.length - offset,
          );
          pending.add(Uint8List.sublistView(data, offset, offset + take));
          offset += take;
          if (pending.length == podcastChunkBytes && !await commit()) {
            return false;
          }
        }
      }
      if (pending.isNotEmpty && !await commit()) return false;
      if (total != null && consumed != total) {
        throw const HttpException('节目数据中断，请继续下载');
      }
      await _serial(id, () async {
        final m = manifest(episode.id, media.url);
        if (m['revision'] != revision) {
          throw const HttpException('节目来源版本发生变化，请重试');
        }
        m['total'] = consumed;
        store.write('asset', id, m, channel: episode.channelId);
      });
      return isComplete(episode.id, media.url);
    } catch (error) {
      http.connectionFailed(_downloadSource(episode, media), error);
      rethrow;
    } finally {
      settled = true;
      await body?.cancel();
    }
  }

  Future<Uri> playbackUri(PodcastEpisode episode, PodcastMedia media) async {
    if (!isComplete(episode.id, media.url)) {
      requirePodcastRssMedia(episode, media);
    }
    if (media.isStreamManifest && !media.isHls) {
      throw const FormatException('暂不支持这个分段媒体来源，请选择音频文件或 MP4 版本');
    }
    _server ??= await (_starting ??= HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    ));
    if (!_listening) {
      _listening = true;
      _server!.listen((request) => unawaited(_serve(request)));
    }
    final id = assetId(episode.id, media.url);
    _sources[id] = (episode, media);
    return Uri.parse('http://127.0.0.1:${_server!.port}/$_token/$id');
  }

  bool _listening = false;
  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    _PodcastPlaybackRead? read;
    String? asset;
    try {
      final parts = request.uri.pathSegments;
      if (parts.length != 2 ||
          parts[0] != _token ||
          !['HEAD', 'GET'].contains(request.method) ||
          !_sources.containsKey(parts[1])) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      final (episode, media) = _sources[parts[1]]!;
      if (media.isHls) {
        await _serveHls(request, episode, media);
        return;
      }
      asset = parts[1];
      if (request.method == 'GET' &&
          request.headers.value('range') != null &&
          _seekPending.remove(asset)) {
        for (final previous
            in _playbackReads[asset]?.toList() ?? <_PodcastPlaybackRead>[]) {
          previous.cancel();
        }
      }
      read = _PodcastPlaybackRead(() {
        unawaited(() async {
          try {
            await response.close();
          } catch (_) {
            /* The decoder may already have closed its socket. */
          }
        }());
      });
      final activeRead = read;
      _playbackReads.putIfAbsent(asset, () => {}).add(activeRead);
      unawaited(
        response.done.then<void>(
          (_) => activeRead.cancel(),
          onError: (Object _, StackTrace _) => activeRead.cancel(),
        ),
      );
      var m = manifest(episode.id, media.url);
      // A tiny metadata request must not make HEAD or a distant seek download
      // the first megabyte before the requested range can even start.
      if (m['total'] == null) {
        await _probe(episode, media, activeRead);
        m = manifest(episode.id, media.url);
      }
      final total = m['total'] as int?;
      final rawRange = request.headers.value('range');
      var start = 0;
      int? end = total == null ? null : total - 1;
      if (rawRange != null && total != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rawRange);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          response.statusCode = 416;
          response.headers.set('content-range', 'bytes */$total');
          await response.close();
          return;
        }
        if (match[1]!.isEmpty) {
          start = max(0, total - int.parse(match[2]!));
        } else {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = min(end!, int.parse(match[2]!));
        }
        if (start >= total || end! < start) {
          response.statusCode = 416;
          response.headers.set('content-range', 'bytes */$total');
          await response.close();
          return;
        }
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes $start-$end/$total');
      }
      response.headers.set(
        'content-type',
        m['mime'] is String && (m['mime'] as String).isNotEmpty
            ? m['mime']
            : (media.isVideo ? 'video/mp4' : 'audio/mpeg'),
      );
      response.headers.set('accept-ranges', total == null ? 'none' : 'bytes');
      if (end != null) response.contentLength = end - start + 1;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      var position = start;
      while (!_closed &&
          !activeRead.cancelled &&
          (end == null || position <= end)) {
        final index = position ~/ podcastChunkBytes;
        final data = await _readChunk(
          episode,
          media,
          index,
          playbackRead: activeRead,
          onData: (bytes, offset) async {
            activeRead.check();
            final absolute = index * podcastChunkBytes + offset;
            final from = max(0, position - absolute);
            final to = end == null
                ? bytes.length
                : min(bytes.length, end + 1 - absolute);
            if (to <= from) return;
            response.add(Uint8List.sublistView(bytes, from, to));
            await response.flush();
            position = absolute + to;
            if (end != null && position > end) {
              // A decoder probe may ask for only a few bytes of a shared
              // download. Finish its range without waiting for the rest of
              // the megabyte (or cancelling the download's other consumers).
              await response.close();
              activeRead.cancel();
            }
          },
        );
        if (data.isEmpty) break;
        if (data.length < podcastChunkBytes && end == null) break;
      }
      await response.close();
    } catch (error) {
      if (read?.cancelled == true) return;
      developer.log(
        'Podcast playback read failed',
        name: 'PodcastMediaStore',
        error: error,
      );
      try {
        response.statusCode = 502;
        response.headers.removeAll('content-range');
        response.contentLength = 0;
      } catch (_) {
        /* A response that already streamed bytes must finish as truncated. */
      }
      try {
        await response.close();
      } catch (_) {
        /* The player may have cancelled a seek. */
      }
    } finally {
      read?.cancel();
      if (asset != null) {
        _playbackReads[asset]?.remove(read);
        if (_playbackReads[asset]?.isEmpty == true) {
          _playbackReads.remove(asset);
        }
      }
    }
  }

  Future<void> _serveHls(
    HttpRequest request,
    PodcastEpisode episode,
    PodcastMedia media,
  ) async {
    final source = await http.get(media.url, maxBytes: 4 * 1024 * 1024);
    var body = utf8.decode(source.bytes);
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('来源没有返回可识别的流媒体列表');
    }
    Future<String> proxied(String raw) async {
      final url = Uri.parse(source.url).resolve(raw).toString();
      final next = PodcastMedia(
        url: url,
        mimeType: Uri.parse(url).path.endsWith('.m3u8')
            ? 'application/vnd.apple.mpegurl'
            : '',
      );
      // Playlist descendants inherit the verified enclosure's feed evidence.
      // Keep this derived list in memory; do not turn it into an imported show.
      final descendant = PodcastEpisode.fromJson({
        ...episode.toJson(),
        'media': [
          ...episode.media.map((value) => value.toJson()),
          next.toJson(),
        ],
      });
      return (await playbackUri(descendant, next)).toString();
    }

    final lines = <String>[];
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) {
        lines.add(line);
        continue;
      }
      if (!line.startsWith('#')) {
        lines.add(await proxied(line.trim()));
        continue;
      }
      var rewritten = line;
      final attributes = RegExp('URI="([^"]+)"').allMatches(line).toList();
      for (final match in attributes.reversed) {
        rewritten = rewritten.replaceRange(
          match.start,
          match.end,
          'URI="${await proxied(match[1]!)}"',
        );
      }
      lines.add(rewritten);
    }
    body = lines.join('\n');
    request.response.headers.set(
      'content-type',
      'application/vnd.apple.mpegurl',
    );
    if (request.method != 'HEAD') request.response.write(body);
    await request.response.close();
  }

  int bytesFor(Map<String, dynamic> m) =>
      _segments(m).values.fold<int>(0, (sum, n) => sum + (n as int));
  bool _unfinishedDownload(Map<String, dynamic> asset) {
    final task = store.read('download', asset['episodeId']);
    return task != null &&
        task['mediaUrl'] == asset['url'] &&
        task['status'] != PodcastDownloadStatus.completed.name;
  }

  int get partialDownloadBytes => store
      .list('asset')
      .where((m) => m['downloaded'] != true && _unfinishedDownload(m))
      .fold(0, (sum, m) => sum + bytesFor(m));
  int storageBytes(String category, {String? channelId}) => store
      .list('asset', channel: channelId)
      .where(
        (m) => switch (category) {
          'downloads' => m['downloaded'] == true,
          'partial' => m['downloaded'] != true && _unfinishedDownload(m),
          _ => m['downloaded'] != true && !_unfinishedDownload(m),
        },
      )
      .fold(0, (sum, m) => sum + bytesFor(m));
  int get cacheBytes => store
      .list('asset')
      .where((m) => m['downloaded'] != true && !_unfinishedDownload(m))
      .fold(0, (sum, m) => sum + bytesFor(m));
  int get downloadBytes => store
      .list('asset')
      .where((m) => m['downloaded'] == true)
      .fold(0, (sum, m) => sum + bytesFor(m));
  int cachedBytes(String episodeId, String url) =>
      bytesFor(manifest(episodeId, url));

  /// Only an assembled, complete source is exposed to other features. Chunks
  /// stay owned by this store and are never mistaken for standalone videos.
  bool isStoragePathInUse(String path) {
    String key(String value) => Platform.isWindows
        ? p.normalize(value).toLowerCase()
        : p.normalize(value);
    final target = key(path);
    final base = key(root.path);
    bool active(Map<String, dynamic> asset) =>
        _inUse(asset['episodeId'] as String) ||
        activeDownloads.contains(asset['episodeId']) ||
        storageProtectedAssetIds.contains(asset['id']);
    if (target == base || p.isWithin(target, base)) {
      return store.list('asset').any(active);
    }
    // Most callers are checking a Bilibili/cloud path. Do not scan the podcast
    // database for those; an owned path needs only its single asset record.
    if (!p.isWithin(base, target)) return false;
    final id = p.split(p.relative(target, from: base)).first;
    final asset = store.read('asset', id);
    return asset != null && active(asset);
  }

  Future<void> forgetDeletedStorage(List<String> paths) async {
    final gone = paths
        .map(
          (path) => Platform.isWindows
              ? p.normalize(path).toLowerCase()
              : p.normalize(path),
        )
        .toSet();
    for (final asset in store.list('asset')) {
      final assembled = asset['assembled'];
      if (assembled is! String) continue;
      final path = p.join(root.path, asset['id'], assembled);
      if (!gone.contains(
        Platform.isWindows
            ? p.normalize(path).toLowerCase()
            : p.normalize(path),
      )) {
        continue;
      }
      final id = asset['episodeId'] as String, url = asset['url'] as String;
      asset.remove('assembled');
      asset['downloaded'] = false;
      store.write(
        'asset',
        asset['id'],
        asset,
        channel: store.episode(id)?.channelId ?? '',
      );
      if (!_inUse(id) && !activeDownloads.contains(id)) {
        await remove(id, url, includeDownload: true);
      }
      final task = store.read('download', id);
      if (task?['mediaUrl'] == url &&
          task?['status'] == PodcastDownloadStatus.completed.name) {
        store.remove('download', id);
      }
    }
  }

  File? localFileFor(String episodeId, String url) => isComplete(episodeId, url)
      ? _assembledFile(manifest(episodeId, url))
      : null;

  Future<void> markDownloaded(
    PodcastEpisode episode,
    PodcastMedia media,
  ) async {
    if (!isComplete(episode.id, media.url)) {
      throw const HttpException('节目尚未完整下载');
    }
    final m = manifest(episode.id, media.url)..['downloaded'] = true;
    store.write('asset', m['id'], m, channel: episode.channelId);
  }

  Future<void> importFile(
    PodcastEpisode episode,
    PodcastMedia media,
    File source,
  ) async {
    final id = assetId(episode.id, media.url);
    await _serial(id, () async {
      final total = await source.length();
      if (total <= 0) throw const FormatException('离线媒体文件为空');
      final m = manifest(episode.id, media.url);
      m.remove('assembled');
      final revision = (m['revision'] as int) + 1,
          segments = <String, dynamic>{};
      final input = await source.open();
      try {
        for (var i = 0; i * podcastChunkBytes < total; i++) {
          final data = await input.read(
            min(podcastChunkBytes, total - i * podcastChunkBytes),
          );
          final target = _chunkFile(id, revision, i);
          await target.parent.create(recursive: true);
          await target.writeAsBytes(data, flush: true);
          segments['$i'] = data.length;
        }
      } finally {
        await input.close();
      }
      store.write('asset', id, {
        ...m,
        'revision': revision,
        'total': total,
        'segments': segments,
        'downloaded': true,
        'mime': media.mimeType,
      }, channel: episode.channelId);
      store.write(
        'download',
        episode.id,
        PodcastDownload(
          episodeId: episode.id,
          mediaUrl: media.url,
          status: PodcastDownloadStatus.completed,
          received: total,
          total: total,
        ).toJson(),
        channel: episode.channelId,
      );
      final directory = Directory(p.join(root.path, id));
      for (final file in directory.listSync().whereType<File>()) {
        if (!p.basename(file.path).startsWith('$revision-')) {
          await file.delete();
        }
      }
    });
  }

  Future<File> assemble(
    PodcastEpisode episode,
    PodcastMedia media, {
    Future<void>? cancelSignal,
    void Function(int copied, int total)? onProgress,
  }) => _serial(assetId(episode.id, media.url), () async {
    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    if (!isComplete(episode.id, media.url)) {
      throw const HttpException('请先完整下载这个节目');
    }
    final m = manifest(episode.id, media.url);
    final existing = _assembledFile(m);
    if (existing != null) return existing;
    final total = m['total'] as int;
    final free = await disk.availableBytes(root);
    if (free != null &&
        free < total + PodcastTransferPolicy.assembleMarginBytes) {
      throw const HttpException('设备可用空间不足，无法整理本地音频');
    }
    final extension = p.extension(Uri.parse(media.url).path);
    final safeExtension = RegExp(r'^\.[a-zA-Z0-9]{1,5}$').hasMatch(extension)
        ? extension
        : (media.isVideo ? '.mp4' : '.mp3');
    final target = File(
      p.join(root.path, m['id'], 'complete-${m['revision']}$safeExtension'),
    );
    final owner = DateTime.now().microsecondsSinceEpoch.toString();
    final temporary = File('${target.path}.$owner.tmp');
    final output = temporary.openWrite();
    var copied = 0;
    try {
      for (var i = 0; i * podcastChunkBytes < total; i++) {
        if (cancelSignal != null) {
          // A completed signal is remembered by the caller; poll a local flag
          // set below so a mid-copy cancel does not wait for the whole file.
        }
        final lease = store.read('assetLease', m['id']);
        if (lease != null) {
          lease['until'] =
              DateTime.now().millisecondsSinceEpoch +
              PodcastTransferPolicy.leaseTtl.inMilliseconds;
          store.write('assetLease', m['id'], lease);
        }
        final chunk = _chunkFile(m['id'], m['revision'] as int, i);
        await output.addStream(chunk.openRead());
        copied += min(podcastChunkBytes, total - i * podcastChunkBytes);
        onProgress?.call(copied, total);
        if (cancelled) {
          throw const HttpException('播客读取已取消');
        }
      }
    } catch (_) {
      await output.close();
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
    await output.close();
    if (temporary.lengthSync() != total) {
      await temporary.delete();
      throw const HttpException('节目数据不完整');
    }
    if (target.existsSync()) await target.delete();
    await temporary.rename(target.path);
    m['assembled'] = p.basename(target.path);
    store.write('asset', m['id'], m, channel: episode.channelId);
    // Only this revision's segments and this task's temporary file are removed.
    // A reader that still holds a segment keeps that file until it can be deleted.
    for (final entry in target.parent.listSync().whereType<File>()) {
      if (entry.path == target.path) continue;
      final name = p.basename(entry.path);
      final segment =
          name.startsWith('${m['revision']}-') && name.endsWith('.seg');
      final leftover = name.endsWith('.tmp') || name.endsWith('.part');
      if (!segment && !leftover) continue;
      try {
        await entry.delete();
      } catch (_) {
        /* Windows may keep a file open for a playback reader. */
      }
    }
    return target;
  }, cancelSignal: cancelSignal);

  void cancelActiveReads() {
    for (final read
        in _playbackReads.values.expand((reads) => reads).toList()) {
      read.cancel();
    }
    for (final flight in _indexFlights.values.toList()) {
      flight.stop();
    }
  }

  Future<void> remove(
    String episodeId,
    String url, {
    bool includeDownload = false,
  }) async {
    final id = assetId(episodeId, url);
    await _serial(id, () async {
      final m = manifest(episodeId, url);
      if (includeDownload &&
          (_inUse(episodeId) || activeDownloads.contains(episodeId))) {
        throw const HttpException('节目仍在使用中，请切换播放或暂停任务后再删除');
      }
      if (_inUse(episodeId) ||
          activeDownloads.contains(episodeId) ||
          (!includeDownload && _unfinishedDownload(m)) ||
          (!includeDownload && m['downloaded'] == true) ||
          (!includeDownload && store.state(episodeId).retained)) {
        return;
      }
      final directory = Directory(p.join(root.path, id));
      if (await directory.exists()) await directory.delete(recursive: true);
      store.remove('asset', id);
    });
  }

  Future<void> clean({String? channelId, bool allTemporary = false}) async {
    for (final use in store.list('mediaUse')) {
      if ((use['until'] as int? ?? 0) <=
              DateTime.now().millisecondsSinceEpoch &&
          use['id'] is String) {
        store.remove('mediaUse', use['id']);
      }
    }
    final global = store.preferences;
    var totalBytes = cacheBytes;
    final records = store.list('asset')
      ..sort(
        (a, b) =>
            (a['accessed'] as int? ?? 0).compareTo(b['accessed'] as int? ?? 0),
      );
    final channelTotals = <String, int>{};
    for (final m in records.where(
      (m) => m['downloaded'] != true && !_unfinishedDownload(m),
    )) {
      final episode = store.episode(m['episodeId']);
      if (episode == null) continue;
      channelTotals.update(
        episode.channelId,
        (n) => n + bytesFor(m),
        ifAbsent: () => bytesFor(m),
      );
    }
    for (final m in records) {
      final episode = store.episode(m['episodeId']);
      if (episode == null ||
          (channelId != null && episode.channelId != channelId) ||
          m['downloaded'] == true ||
          _unfinishedDownload(m) ||
          (_inUse(episode.id) || activeDownloads.contains(episode.id)) ||
          store.state(episode.id).retained) {
        continue;
      }
      final settings = store.effective(episode.channelId);
      final age =
          DateTime.now().millisecondsSinceEpoch - (m['accessed'] as int? ?? 0);
      if (allTemporary ||
          age > Duration(days: settings.integer('cacheDays')).inMilliseconds ||
          totalBytes > global.integer('cacheLimitMb') * 1024 * 1024 ||
          (channelTotals[episode.channelId] ?? 0) >
              settings.integer('channelCacheMb') * 1024 * 1024) {
        final bytes = bytesFor(m);
        await remove(episode.id, m['url']);
        totalBytes -= bytes;
        channelTotals.update(episode.channelId, (n) => n - bytes);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _downloadGate.close();
    _downloadClient?.close(force: true);
    _downloadClient = null;
    cancelActiveReads();
    _sharedClient?.close(force: true);
    _sharedClient = null;
    await _server?.close(force: true);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (_lanes.values.any(
          (lane) => lane.active || lane.pending.isNotEmpty,
        ) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

class _PodcastPlaybackRead {
  _PodcastPlaybackRead(this.onCancel);
  final void Function() onCancel;
  final List<void Function()> _stops = [];
  final _stopped = Completer<void>();
  Future<void> get stopped => _stopped.future;
  bool cancelled = false;
  void check() {
    if (cancelled) throw const HttpException('播放位置已改变');
  }

  void attach(HttpClient client) => check();
  void detach(HttpClient client) {}
  void bind(void Function() stop) {
    if (cancelled) {
      stop();
      return;
    }
    _stops.add(stop);
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _stopped.complete();
    for (final stop in _stops) {
      stop();
    }
    onCancel();
  }
}

class _SerialItem<T> {
  late final Future<T> Function() body;
  final result = Completer<T>();
  bool started = false;
  bool skipped = false;
}

class _SerialLane {
  final pending = <_SerialItem<dynamic>>[];
  bool active = false;
}

class _FlightWaiter {
  _FlightWaiter({required this.download, this.onData, this.onNetworkBytes});
  final bool download;
  final Future<void> Function(Uint8List bytes, int offset)? onData;
  final void Function(int bytes)? onNetworkBytes;
  final done = Completer<Uint8List>();
  Future<void> delivery = Future<void>.value();
  Future<Uint8List> get future => done.future;
}

class _IndexFlight {
  final waiters = <_FlightWaiter>[];
  final _downloadJoined = Completer<void>();
  final _cancelled = Completer<void>();
  Future<void> get cancelled => _cancelled.future;
  // A decoder can reopen byte zero while the cold chunk is still arriving.
  // Every new reader needs the prefix too, not just subsequent network bytes.
  final _pieces = <(Uint8List, int)>[];
  final List<void Function()> _stops = [];
  bool abandoned = false;
  bool get hasDownload => waiters.any((waiter) => waiter.download);

  _FlightWaiter add({
    required bool download,
    Future<void> Function(Uint8List bytes, int offset)? onData,
    void Function(int bytes)? onNetworkBytes,
  }) {
    if (download && !_downloadJoined.isCompleted) _downloadJoined.complete();
    final waiter = _FlightWaiter(
      download: download,
      onData: onData,
      onNetworkBytes: onNetworkBytes,
    );
    waiters.add(waiter);
    for (final (bytes, offset) in _pieces) {
      _enqueue(waiter, bytes, offset);
    }
    // Window bookkeeping waiters are not always awaited. Keep their completion
    // observed so ending a window cannot surface as an unhandled async error.
    waiter.future.then<void>((_) {}, onError: (Object _) {});
    return waiter;
  }

  void drop(_FlightWaiter waiter) {
    waiters.remove(waiter);
    if (!waiter.done.isCompleted) {
      waiter.done.completeError(const HttpException('播客读取已取消'));
    }
    if (waiters.isEmpty) stop();
  }

  void bindStop(void Function() stop) {
    if (abandoned) {
      stop();
    } else {
      _stops.add(stop);
    }
  }

  void stop() {
    if (abandoned) return;
    abandoned = true;
    _cancelled.complete();
    for (final stop in _stops) {
      stop();
    }
  }

  void forwardNetwork(int bytes) {
    for (final waiter in waiters) {
      waiter.onNetworkBytes?.call(bytes);
    }
  }

  void _enqueue(_FlightWaiter waiter, Uint8List bytes, int offset) {
    if (waiter.onData == null) return;
    waiter.delivery = waiter.delivery
        .then((_) async {
          if (waiters.contains(waiter)) await waiter.onData!(bytes, offset);
        })
        .catchError((Object error, StackTrace stack) {
          if (!waiter.done.isCompleted) waiter.done.completeError(error, stack);
          drop(waiter);
        });
  }

  Future<void> deliver(Uint8List bytes, int offset) async {
    _pieces.add((bytes, offset));
    for (final waiter in waiters.toList()) {
      _enqueue(waiter, bytes, offset);
    }
    if (!hasDownload) {
      await Future.any<void>([
        Future.wait(
          waiters.map((waiter) => waiter.delivery),
        ).then<void>((_) {}),
        _downloadJoined.future,
        // A seek also releases a paused decoder's pending socket flush.
        _cancelled.future,
      ]);
    }
  }

  Future<void> complete(Uint8List data) async {
    // A paused decoder must not hold a bulk download behind its socket flush.
    // Its own future still waits for queued writes before closing the gateway.
    final deliveries = <Future<void>>[];
    final downloading = hasDownload;
    for (final waiter in waiters.toList()) {
      if (waiter.download) {
        if (!waiter.done.isCompleted) waiter.done.complete(data);
        waiters.remove(waiter);
      } else {
        deliveries.add(
          waiter.delivery.then((_) {
            if (!waiter.done.isCompleted) waiter.done.complete(data);
            waiters.remove(waiter);
          }),
        );
      }
    }
    if (downloading) {
      unawaited(Future.wait(deliveries));
    } else {
      await Future.any<void>([
        Future.wait(deliveries).then<void>((_) {}),
        _cancelled.future,
      ]);
    }
  }

  void fail(Object error, StackTrace stack) {
    abandoned = true;
    for (final waiter in waiters.toList()) {
      if (!waiter.done.isCompleted) waiter.done.completeError(error, stack);
    }
    waiters.clear();
  }
}

enum _WindowStop { done, stopped, sequential }

class _PodcastRetryRange implements Exception {
  const _PodcastRetryRange();
}
