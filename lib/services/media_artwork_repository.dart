import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../debug/developer_log.dart' as developer;
import '../models/media_artwork_ref.dart';
import 'network/network_http.dart';
import 'storage_audit_service.dart';

/// Result of checking bytes before they are allowed to become a cover.
class ArtworkInspection {
  const ArtworkInspection({
    required this.format,
    required this.extension,
    required this.width,
    required this.height,
  });

  final String format;
  final String extension;
  final int width;
  final int height;
}

class ArtworkReject implements Exception {
  const ArtworkReject(this.reason);
  final String reason;
}

/// Rejects HTML error pages, empty bodies and images that are too large to decode.
ArtworkInspection inspectArtworkBytes(List<int> bytes) {
  if (bytes.isEmpty) throw const ArtworkReject('empty');
  if (_looksLikeMarkup(bytes)) throw const ArtworkReject('html');
  final image = _decodeHeader(bytes);
  if (image == null) throw const ArtworkReject('decode');
  if (image.width > 8192 ||
      image.height > 8192 ||
      image.width * image.height > 40000000) {
    throw const ArtworkReject('tooLarge');
  }
  return image;
}

bool _looksLikeMarkup(List<int> bytes) {
  var index = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    index = 3;
  }
  while (index < bytes.length && index < 64) {
    final byte = bytes[index];
    if (byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) break;
    index++;
  }
  if (index >= bytes.length || bytes[index] != 0x3C) return false;
  return true;
}

ArtworkInspection? _decodeHeader(List<int> bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return ArtworkInspection(
      format: 'png',
      extension: '.png',
      width: _u32(bytes, 16),
      height: _u32(bytes, 20),
    );
  }
  if (bytes.length >= 10 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return ArtworkInspection(
      format: 'gif',
      extension: '.gif',
      width: bytes[6] | (bytes[7] << 8),
      height: bytes[8] | (bytes[9] << 8),
    );
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return _webp(bytes);
  }
  if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return _jpeg(bytes);
  }
  return null;
}

ArtworkInspection? _webp(List<int> bytes) {
  if (bytes.length < 30) return null;
  final kind = ascii.decode(bytes.sublist(12, 16), allowInvalid: true);
  if (kind == 'VP8X') {
    final width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
    final height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
    return ArtworkInspection(
      format: 'webp',
      extension: '.webp',
      width: width,
      height: height,
    );
  }
  if (kind == 'VP8 ' && bytes.length >= 30) {
    // Lossy frame: 3 byte start code, then 14-bit width and height.
    final width = bytes[26] | ((bytes[27] & 0x3F) << 8);
    final height = bytes[28] | ((bytes[29] & 0x3F) << 8);
    return ArtworkInspection(
      format: 'webp',
      extension: '.webp',
      width: width,
      height: height,
    );
  }
  if (kind == 'VP8L' && bytes.length >= 25) {
    final bits =
        bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return ArtworkInspection(
      format: 'webp',
      extension: '.webp',
      width: (bits & 0x3FFF) + 1,
      height: ((bits >> 14) & 0x3FFF) + 1,
    );
  }
  return null;
}

ArtworkInspection? _jpeg(List<int> bytes) {
  var index = 2;
  while (index + 1 < bytes.length) {
    if (bytes[index] != 0xFF) {
      index++;
      continue;
    }
    while (index < bytes.length && bytes[index] == 0xFF) {
      index++;
    }
    if (index >= bytes.length) return null;
    final marker = bytes[index++];
    if (marker == 0xD9 || marker == 0xDA) return null;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
    if (index + 1 >= bytes.length) return null;
    final length = (bytes[index] << 8) | bytes[index + 1];
    if (length < 2 || index + length > bytes.length) return null;
    final startOfFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (startOfFrame && index + 7 < bytes.length) {
      return ArtworkInspection(
        format: 'jpeg',
        extension: '.jpg',
        height: (bytes[index + 3] << 8) | bytes[index + 4],
        width: (bytes[index + 5] << 8) | bytes[index + 6],
      );
    }
    index += length;
  }
  return null;
}

int _u32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

class ArtworkFetchRequest {
  const ArtworkFetchRequest({
    required this.uri,
    required this.headers,
    required this.maxBytes,
    required this.connectTimeout,
    required this.headerTimeout,
    required this.totalBudget,
    required this.cancelled,
    required this.scope,
  });

  final Uri uri;
  final Map<String, String> headers;
  final int maxBytes;
  final Duration connectTimeout;
  final Duration headerTimeout;
  final Duration totalBudget;
  final bool Function() cancelled;
  final NetworkScope scope;
}

class ArtworkFetchResponse {
  const ArtworkFetchResponse({
    required this.status,
    required this.headers,
    required this.bytes,
    required this.finalUri,
  });

  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
  final Uri finalUri;
}

typedef ArtworkFetcher =
    Future<ArtworkFetchResponse> Function(ArtworkFetchRequest request);

class ArtworkDiagnostics {
  int network = 0;
  int disk = 0;
  int coalesced = 0;
  int notModified = 0;
  int fallback = 0;
  int decodeFailure = 0;
  int cancelled = 0;
  int retries = 0;
}

class _Alias {
  _Alias({
    required this.requestKey,
    this.blobHash,
    this.etag,
    this.lastModified,
    this.validatedMs = 0,
    this.expiresMs = 0,
    this.retryAfterMs = 0,
    this.failure = '',
    this.persistent = true,
    this.exportable = true,
  });

  final String requestKey;
  String? blobHash;
  String? etag;
  String? lastModified;
  int validatedMs;
  int expiresMs;
  int retryAfterMs;
  String failure;
  bool persistent;
  bool exportable;
}

class _Demand {
  _Demand(this.id, this.priority);
  final int id;
  ArtworkPriority priority;
  bool alive = true;
}

class _Job {
  _Job(this.generation);
  final int generation;
  final demands = <int, _Demand>{};
  bool finished = false;
  bool started = false;
  bool abandoned = false;
  Timer? grace;
  Future<ArtworkSnapshot>? future;
  ArtworkPriority priority = ArtworkPriority.prefetch;

  bool get hasDemand => demands.values.any((demand) => demand.alive);

  void recomputePriority() {
    ArtworkPriority? best;
    for (final demand in demands.values) {
      if (!demand.alive) continue;
      if (best == null || demand.priority.index < best.index) {
        best = demand.priority;
      }
    }
    priority = best ?? ArtworkPriority.prefetch;
  }
}

class _Permit {
  _Permit(this.host);
  final String host;
}

class _Slot {
  _Slot(this.host, this.job, this.done, this.sequence);
  final String host;
  final _Job job;
  final Completer<_Permit?> done;
  final int sequence;
}

/// Grants a global slot and a per-host slot together. A request waiting on a
/// busy host does not occupy one of the global four.
class _ArtworkScheduler {
  static const globalMax = 4;
  static const hostMax = 2;
  int globalActive = 0;
  final hostActive = <String, int>{};
  final waiting = <_Slot>[];
  int _sequence = 0;

  Future<_Permit?> acquire({required String host, required _Job job}) {
    final slot = _Slot(host, job, Completer<_Permit?>(), _sequence++);
    waiting.add(slot);
    _pump();
    return slot.done.future;
  }

  void release(_Permit permit) {
    if (globalActive > 0) globalActive--;
    final left = (hostActive[permit.host] ?? 1) - 1;
    if (left <= 0) {
      hostActive.remove(permit.host);
    } else {
      hostActive[permit.host] = left;
    }
    _pump();
  }

  void removeJob(_Job job) {
    waiting.removeWhere((slot) {
      if (!identical(slot.job, job) || slot.done.isCompleted) return false;
      slot.done.complete(null);
      return true;
    });
  }

  void _pump() {
    if (waiting.isEmpty) return;
    waiting.sort((a, b) {
      final byPriority = a.job.priority.index.compareTo(b.job.priority.index);
      if (byPriority != 0) return byPriority;
      return a.sequence.compareTo(b.sequence);
    });
    final done = <_Slot>[];
    for (final slot in waiting) {
      if (slot.done.isCompleted) {
        done.add(slot);
        continue;
      }
      if (!slot.job.hasDemand || slot.job.abandoned || slot.job.finished) {
        slot.done.complete(null);
        done.add(slot);
        continue;
      }
      if (globalActive >= globalMax) break;
      final hostCount = hostActive[slot.host] ?? 0;
      if (hostCount >= hostMax) continue;
      globalActive++;
      hostActive[slot.host] = hostCount + 1;
      slot.done.complete(_Permit(slot.host));
      done.add(slot);
    }
    waiting.removeWhere(done.contains);
  }
}

/// Shared original-byte store for covers.
///
/// Flutter's image cache only reuses decoded frames. This repository is the
/// place that downloads, deduplicates and publishes the file those frames
/// come from. One URL in one network context produces one request, regardless
/// of how many widgets or pixel sizes are on screen.
class MediaArtworkRepository {
  MediaArtworkRepository._({
    required this.root,
    required Database database,
    required ArtworkFetcher fetcher,
    required DateTime Function() clock,
    required math.Random random,
    required this.retryBase,
    required this.orphanGrace,
    this.legacyPodcastDirectory,
  }) : _database = database,
       _fetcher = fetcher,
       _clock = clock,
       _random = random;

  static MediaArtworkRepository? debugOverride;
  static MediaArtworkRepository? _instance;
  static MediaArtworkRepository? get active => debugOverride ?? _instance;

  static const maxImageBytes = 8 * 1024 * 1024;
  static const connectTimeout = Duration(seconds: 8);
  static const headerTimeout = Duration(seconds: 12);
  static const totalBudget = Duration(seconds: 20);

  final Directory root;
  final Database _database;
  final ArtworkFetcher _fetcher;
  final DateTime Function() _clock;
  final math.Random _random;
  final Duration retryBase;
  final Duration orphanGrace;
  final Directory? legacyPodcastDirectory;
  static const budgetBytes = 256 * 1024 * 1024;
  final diagnostics = ArtworkDiagnostics();
  final _scheduler = _ArtworkScheduler();
  final _jobs = <String, _Job>{};
  final _demands = <int, _Demand>{};
  final _memory = <String, Uint8List>{};
  int _nextDemand = 0;

  /// True while a publish or fetch still holds this process.
  bool get storagePublishActive => _jobs.isNotEmpty || _demands.isNotEmpty;

  /// Forgets blobs whose files were deleted by a confirmed storage plan.
  ///
  /// Request rows stay so the picture can be fetched again. Owners are not
  /// wiped just to make the folder look empty.
  Future<List<String>> forgetDeletedFiles(List<String> paths) async {
    final gone = paths.map(storagePathKey).toSet();
    try {
      final blobs = _database.select(
        'SELECT blob_hash, relative_path FROM blobs',
      );
      final hashes = <String>[];
      for (final blob in blobs) {
        final absolute = p.normalize(
          p.join(
            root.path,
            p.joinAll(blob['relative_path'].toString().split('/')),
          ),
        );
        if (gone.contains(storagePathKey(absolute))) {
          hashes.add(blob['blob_hash'].toString());
        }
      }
      if (hashes.isEmpty) return const [];
      _database.execute('BEGIN IMMEDIATE');
      for (final hash in hashes) {
        final aliases = _database.select(
          'SELECT request_key FROM aliases WHERE blob_hash=?',
          [hash],
        );
        for (final alias in aliases) {
          _memory.remove(alias['request_key'].toString());
        }
        _database.execute('DELETE FROM palettes WHERE blob_hash=?', [hash]);
        _database.execute(
          'UPDATE aliases SET blob_hash=NULL WHERE blob_hash=?',
          [hash],
        );
        _database.execute('DELETE FROM blobs WHERE blob_hash=?', [hash]);
      }
      _database.execute('COMMIT');
      return const [];
    } catch (error) {
      try {
        _database.execute('ROLLBACK');
      } catch (_) {}
      return ['封面文件已删除，索引校正失败：$error'];
    }
  }

  /// Hosts in the order a network fetch actually acquired a slot.
  @visibleForTesting
  final artworkFetchOrder = <String>[];

  @visibleForTesting
  int get activeArtworkFetches => _scheduler.globalActive;

  @visibleForTesting
  int artworkFetchesForHost(String host) => _scheduler.hostActive[host] ?? 0;

  @visibleForTesting
  int get queuedArtworkFetches =>
      _scheduler.waiting.where((slot) => !slot.done.isCompleted).length;
  final _palettes = <String, int>{};
  int _generation = 0;
  bool _closed = false;

  static Future<MediaArtworkRepository> open(
    Directory root, {
    ArtworkFetcher? fetcher,
    DateTime Function()? clock,
    math.Random? random,
    Duration retryBase = const Duration(milliseconds: 200),
    Duration orphanGrace = const Duration(hours: 1),
    Directory? legacyPodcastDirectory,
    bool installAsActive = true,
  }) async {
    await root.create(recursive: true);
    await Directory(p.join(root.path, 'blobs')).create(recursive: true);
    await Directory(p.join(root.path, 'staging')).create(recursive: true);
    final database = sqlite3.open(p.join(root.path, 'index.sqlite'));
    final repository = MediaArtworkRepository._(
      root: root,
      database: database,
      fetcher: fetcher ?? defaultArtworkFetcher,
      clock: clock ?? DateTime.now,
      random: random ?? math.Random(),
      retryBase: retryBase,
      orphanGrace: orphanGrace,
      legacyPodcastDirectory: legacyPodcastDirectory,
    );
    repository._migrate();
    repository.recover();
    if (installAsActive) _instance = repository;
    return repository;
  }

  void close() {
    _closed = true;
    _generation++;
    _database.dispose();
    if (identical(_instance, this)) _instance = null;
    if (identical(debugOverride, this)) debugOverride = null;
  }

  /// Changing proxy or route cancels the old transfer. A valid file stays.
  void bumpNetworkGeneration() => _generation++;

  int get networkGeneration => _generation;

  Stream<ArtworkSnapshot> watch(
    ArtworkRef ref, {
    ArtworkPriority priority = ArtworkPriority.visible,
  }) {
    final owned = <int>[];
    late final StreamController<ArtworkSnapshot> controller;
    controller = StreamController<ArtworkSnapshot>(
      onCancel: () {
        for (final id in owned) {
          _releaseDemand(id);
        }
        owned.clear();
      },
    );
    controller.onListen = () {
      unawaited(() async {
        // Show a cached channel image before a slow episode image is tried.
        // A later primary result may replace it; a later fallback may not.
        final cached = cachedSnapshot(ref);
        if (_closed) return;
        if (cached != null && !controller.isClosed) controller.add(cached);
        if (controller.isClosed || ref.chain.isEmpty) {
          if (!controller.isClosed && cached == null) {
            controller.add(
              const ArtworkSnapshot(
                phase: ArtworkPhase.placeholder,
                reason: 'empty',
              ),
            );
          }
          return;
        }
        final primary = await _loadRequest(
          ref.chain.first,
          ref,
          priority: priority,
          ownedDemands: owned,
        );
        if (_closed || controller.isClosed) return;
        if (primary.hasImage) {
          if (primary.requestKey != cached?.requestKey ||
              primary.blobHash != cached?.blobHash) {
            controller.add(primary);
          }
          _rememberOwner(ref, ref.chain.first.requestKey);
          return;
        }
        if (cached != null && cached.requestKey != ref.chain.first.requestKey) {
          return;
        }
        for (final request in ref.chain.skip(1)) {
          if (controller.isClosed) return;
          final snapshot = await _loadRequest(
            request,
            ref,
            priority: priority,
            ownedDemands: owned,
          );
          if (_closed) return;
          if (snapshot.hasImage) {
            if (!controller.isClosed) controller.add(snapshot);
            diagnostics.fallback++;
            _rememberOwner(ref, request.requestKey);
            return;
          }
        }
        if (!controller.isClosed && cached == null) controller.add(primary);
      }());
    };
    return controller.stream;
  }

  /// Primary cache wins. Otherwise the first cached fallback, so a warm
  /// channel image is not hidden behind an uncached episode image.
  /// Reads only the local index and files, including stale covers. This lets a
  /// newly mounted view show its cached image in its first build while watch()
  /// checks freshness separately.
  ArtworkSnapshot? cachedSnapshot(ArtworkRef ref) {
    if (_closed) return null;
    ArtworkSnapshot? fallback;
    for (var index = 0; index < ref.chain.length; index++) {
      final request = ref.chain[index];
      final ready = _readySnapshot(
        _alias(request.requestKey),
        request.requestKey,
      );
      if (ready == null) continue;
      if (index == 0) return ready;
      fallback ??= ready;
    }
    return fallback;
  }

  Future<ArtworkSnapshot> load(
    ArtworkRef ref, {
    ArtworkPriority priority = ArtworkPriority.visible,
  }) async {
    if (ref.chain.isEmpty) {
      return const ArtworkSnapshot(
        phase: ArtworkPhase.placeholder,
        reason: 'empty',
      );
    }
    final cached = cachedSnapshot(ref);
    if (cached != null && cached.requestKey == ref.chain.first.requestKey) {
      final alias = _alias(ref.chain.first.requestKey);
      final now = _clock().millisecondsSinceEpoch;
      if (alias == null || alias.expiresMs == 0 || alias.expiresMs > now) {
        diagnostics.disk++;
        return cached;
      }
    }
    // A visible row should not sit through the primary's retries when the
    // channel image is already on disk. The primary keeps loading underneath.
    if (cached != null &&
        cached.requestKey != ref.chain.first.requestKey &&
        priority != ArtworkPriority.player) {
      unawaited(
        _loadRequest(ref.chain.first, ref, priority: priority).then((_) {}),
      );
      return cached;
    }
    ArtworkSnapshot? last;
    for (final request in ref.chain) {
      last = await _loadRequest(request, ref, priority: priority);
      if (last.hasImage) {
        _rememberOwner(ref, request.requestKey);
        return last;
      }
      if (cached != null && cached.requestKey != request.requestKey) {
        return cached;
      }
      if (request != ref.chain.first) diagnostics.fallback++;
    }
    return cached ??
        last ??
        const ArtworkSnapshot(phase: ArtworkPhase.failed, reason: 'empty');
  }

  Future<ArtworkSnapshot> retry(ArtworkRef ref) {
    for (final request in ref.chain) {
      final alias = _alias(request.requestKey);
      if (alias == null) continue;
      alias.retryAfterMs = 0;
      alias.failure = '';
      _saveAlias(alias, adapter: request.adapter.name);
    }
    return load(ref, priority: ArtworkPriority.player);
  }

  void acquire(String requestKey, String leaseId) {
    _database.execute(
      'INSERT INTO leases(request_key, lease_id) VALUES(?, ?) ON CONFLICT(request_key, lease_id) DO NOTHING',
      [requestKey, leaseId],
    );
  }

  void releaseLease(String requestKey, String leaseId) {
    _database.execute('DELETE FROM leases WHERE request_key=? AND lease_id=?', [
      requestKey,
      leaseId,
    ]);
  }

  /// Reads an existing palette without waiting for file access or revalidation.
  /// A new page can paint its known cover colour on its very first frame.
  int? cachedPalette(ArtworkRef ref, {int algorithmVersion = 1}) {
    if (_closed) return null;
    for (final request in ref.chain) {
      final hash = _alias(request.requestKey)?.blobHash;
      if (hash == null) continue;
      final color = palette(hash, algorithmVersion: algorithmVersion);
      if (color != null) return color;
    }
    return null;
  }

  int? palette(String blobHash, {int algorithmVersion = 1}) {
    final cached = _palettes['$blobHash:$algorithmVersion'];
    if (cached != null) return cached;
    final rows = _database.select(
      'SELECT argb FROM palettes WHERE blob_hash=? AND algorithm=?',
      [blobHash, algorithmVersion],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['argb'] as int;
    _palettes['$blobHash:$algorithmVersion'] = value;
    return value;
  }

  void rememberPalette(String blobHash, int argb, {int algorithmVersion = 1}) {
    _palettes['$blobHash:$algorithmVersion'] = argb;
    _database.execute(
      'INSERT INTO palettes(blob_hash, algorithm, argb) VALUES(?,?,?) ON CONFLICT(blob_hash, algorithm) DO UPDATE SET argb=excluded.argb',
      [blobHash, algorithmVersion, argb],
    );
  }

  /// Copies an already validated file into the shared store and leaves the
  /// original in place. Used for old podcast covers and Bilibili files.
  Future<String?> adoptFile({
    required ArtworkRequest request,
    required File file,
    String ownerKind = '',
    String ownerId = '',
  }) async {
    if (!await file.exists() || await file.length() == 0) return null;
    final bytes = await file.readAsBytes();
    return _publish(
      request: request,
      bytes: bytes,
      headers: const {},
      ownerKind: ownerKind,
      ownerId: ownerId,
      persistent: true,
    );
  }

  void releaseOwner(String ownerKind, String ownerId) {
    _database.execute('DELETE FROM owners WHERE owner_kind=? AND owner_id=?', [
      ownerKind,
      ownerId,
    ]);
  }

  int get storedBytes {
    final row = _database.select(
      'SELECT COALESCE(SUM(bytes), 0) AS n FROM blobs WHERE published=1',
    );
    return row.first['n'] as int;
  }

  /// Drops cold blobs until the unique-byte budget fits. In-use files stay,
  /// and the alias remains so the next visit refetches instead of going blank
  /// forever. Owners are not deleted to satisfy the budget.
  int prune({int? budget}) {
    final limit = budget ?? budgetBytes;
    var removed = 0;
    final now = _clock().millisecondsSinceEpoch;
    final expiredOwners = _database.select(
      'SELECT owner_kind, owner_id FROM owners WHERE expires_ms>0 AND expires_ms<?',
      [now],
    );
    for (final row in expiredOwners) {
      releaseOwner(row['owner_kind'] as String, row['owner_id'] as String);
    }
    while (storedBytes > limit) {
      final candidate = _database.select('''
        SELECT b.blob_hash, b.relative_path, b.bytes, b.used_ms
        FROM blobs b
        WHERE b.published=1
          AND NOT EXISTS (
            SELECT 1 FROM aliases a
            JOIN leases l ON l.request_key=a.request_key
            WHERE a.blob_hash=b.blob_hash
          )
        ORDER BY b.used_ms ASC
        LIMIT 1
      ''');
      if (candidate.isEmpty) break;
      final hash = candidate.first['blob_hash'] as String;
      final relative = candidate.first['relative_path'] as String;
      final file = File(p.join(root.path, relative));
      if (file.existsSync()) file.deleteSync();
      _database.execute('DELETE FROM blobs WHERE blob_hash=?', [hash]);
      _database.execute('UPDATE aliases SET blob_hash=NULL WHERE blob_hash=?', [
        hash,
      ]);
      removed += candidate.first['bytes'] as int;
    }
    return removed;
  }

  void recover() {
    final staging = Directory(p.join(root.path, 'staging'));
    if (staging.existsSync()) {
      for (final entity in staging.listSync()) {
        if (entity is File) entity.deleteSync();
      }
    }
    final now = _clock().millisecondsSinceEpoch;
    final blobs = _database.select(
      'SELECT blob_hash, relative_path FROM blobs WHERE published=1',
    );
    for (final row in blobs) {
      final file = File(p.join(root.path, row['relative_path'] as String));
      if (!file.existsSync() || file.lengthSync() == 0) {
        _database.execute(
          'UPDATE aliases SET blob_hash=NULL, failure=? WHERE blob_hash=?',
          ['missing', row['blob_hash']],
        );
        _database.execute('DELETE FROM blobs WHERE blob_hash=?', [
          row['blob_hash'],
        ]);
      }
    }
    final known = _database
        .select('SELECT relative_path FROM blobs')
        .map((row) => row['relative_path'] as String)
        .toSet();
    final directory = Directory(p.join(root.path, 'blobs'));
    if (!directory.existsSync()) return;
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final relative = p.join('blobs', p.basename(entity.path));
      if (known.contains(relative.replaceAll('\\', '/'))) continue;
      final age = now - entity.lastModifiedSync().millisecondsSinceEpoch;
      if (age >= orphanGrace.inMilliseconds) entity.deleteSync();
    }
  }

  void _migrate() {
    _database.execute('PRAGMA journal_mode=WAL');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS aliases (
        request_key TEXT PRIMARY KEY,
        blob_hash TEXT,
        adapter TEXT NOT NULL,
        url_digest TEXT NOT NULL,
        etag TEXT,
        last_modified TEXT,
        validated_ms INTEGER NOT NULL,
        expires_ms INTEGER NOT NULL,
        retry_after_ms INTEGER NOT NULL,
        failure TEXT NOT NULL,
        persistent INTEGER NOT NULL,
        exportable INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS blobs (
        blob_hash TEXT PRIMARY KEY,
        relative_path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        format TEXT NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        used_ms INTEGER NOT NULL,
        published INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS owners (
        owner_kind TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        expires_ms INTEGER NOT NULL,
        PRIMARY KEY(owner_kind, owner_id, request_key)
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS palettes (
        blob_hash TEXT NOT NULL,
        algorithm INTEGER NOT NULL,
        argb INTEGER NOT NULL,
        PRIMARY KEY(blob_hash, algorithm)
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS leases (
        request_key TEXT NOT NULL,
        lease_id TEXT NOT NULL,
        PRIMARY KEY(request_key, lease_id)
      )
    ''');
  }

  int _attachDemand(String key, ArtworkPriority priority, _Job job) {
    final demand = _Demand(++_nextDemand, priority);
    _demands[demand.id] = demand;
    job.demands[demand.id] = demand;
    job.recomputePriority();
    job.grace?.cancel();
    if (job.hasDemand) job.abandoned = false;
    _scheduler._pump();
    return demand.id;
  }

  void _releaseDemand(int id) {
    final demand = _demands.remove(id);
    if (demand == null) return;
    demand.alive = false;
    _Job? job;
    for (final candidate in _jobs.values) {
      if (candidate.demands.containsKey(id)) {
        job = candidate;
        break;
      }
    }
    if (job == null) return;
    job.demands.remove(id);
    job.recomputePriority();
    if (job.hasDemand) {
      job.grace?.cancel();
      job.abandoned = false;
      _scheduler._pump();
      return;
    }
    // A queued task nobody is looking at leaves immediately. An in-flight
    // transfer gets a short grace so a rebuild does not abort it.
    if (!job.started) {
      job.abandoned = true;
      _scheduler.removeJob(job);
      return;
    }
    job.grace?.cancel();
    job.grace = Timer(const Duration(milliseconds: 150), () {
      if (!job!.hasDemand) job.abandoned = true;
    });
  }

  Future<ArtworkSnapshot> _loadRequest(
    ArtworkRequest request,
    ArtworkRef ref, {
    required ArtworkPriority priority,
    List<int>? ownedDemands,
  }) async {
    final key = request.requestKey;
    final alias = _alias(key);
    final ready = _readySnapshot(alias, key);
    final now = _clock().millisecondsSinceEpoch;
    if (ready != null && (alias!.expiresMs == 0 || alias.expiresMs > now)) {
      diagnostics.disk++;
      _touch(alias.blobHash!);
      _log('disk-hit', request);
      return ready;
    }
    if (alias != null && alias.retryAfterMs > now && ready == null) {
      return ArtworkSnapshot(
        phase: ArtworkPhase.failed,
        requestKey: key,
        reason: alias.failure.isEmpty ? 'cooldown' : alias.failure,
      );
    }
    int? createdDemand;
    final current = _jobs[key];
    if (current != null &&
        current.future != null &&
        !current.finished &&
        current.generation == _generation) {
      diagnostics.coalesced++;
      final joined = _attachDemand(key, priority, current);
      if (ownedDemands != null) {
        ownedDemands.add(joined);
      } else {
        createdDemand = joined;
      }
      _log('coalesced', request, extra: 'priority=${current.priority.name}');
      try {
        final shared = await current.future!;
        if (shared.hasImage || ready == null) return shared;
        return ready;
      } finally {
        if (createdDemand != null) _releaseDemand(createdDemand);
      }
    }
    // Register the task before the first await so a second widget joins it
    // instead of starting another download of the same bytes.
    final created = _Job(_generation);
    _jobs[key] = created;
    final attached = _attachDemand(key, priority, created);
    if (ownedDemands != null) {
      ownedDemands.add(attached);
    } else {
      createdDemand = attached;
    }
    created.future = _fetch(request, ref, alias, ready, created);
    try {
      final snapshot = await created.future!;
      if (ready != null && !snapshot.hasImage) return ready;
      return snapshot;
    } finally {
      created.finished = true;
      created.grace?.cancel();
      if (identical(_jobs[key], created)) _jobs.remove(key);
      if (createdDemand != null) _releaseDemand(createdDemand);
    }
  }

  ArtworkSnapshot? _readySnapshot(_Alias? alias, String key) {
    final memory = _memory[key];
    if (memory != null && memory.isNotEmpty) {
      return ArtworkSnapshot(
        phase: ArtworkPhase.ready,
        memoryBytes: memory,
        requestKey: key,
        blobHash: alias?.blobHash,
        fromDisk: false,
      );
    }
    final hash = alias?.blobHash;
    if (hash == null || hash.isEmpty) return null;
    final rows = _database.select(
      'SELECT relative_path, format FROM blobs WHERE blob_hash=? AND published=1',
      [hash],
    );
    if (rows.isEmpty) return null;
    final file = File(p.join(root.path, rows.first['relative_path'] as String));
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    return ArtworkSnapshot(
      phase: ArtworkPhase.ready,
      localPath: file.path,
      blobHash: hash,
      requestKey: key,
      format: rows.first['format'] as String,
      fromDisk: true,
    );
  }

  Future<ArtworkSnapshot> _fetch(
    ArtworkRequest request,
    ArtworkRef ref,
    _Alias? existing,
    ArtworkSnapshot? previous,
    _Job job,
  ) async {
    final uri = Uri.tryParse(request.url);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return ArtworkSnapshot(
        phase: previous == null ? ArtworkPhase.failed : ArtworkPhase.ready,
        localPath: previous?.localPath,
        blobHash: previous?.blobHash,
        requestKey: request.requestKey,
        reason: 'url',
        fromDisk: previous != null,
      );
    }
    final legacy = await _importLegacy(request, ref);
    if (legacy != null) return legacy;
    var conditional = existing?.etag != null || existing?.lastModified != null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_closed ||
          job.generation != _generation ||
          job.abandoned ||
          !job.hasDemand) {
        diagnostics.cancelled++;
        _log('cancelled', request);
        return previous ??
            ArtworkSnapshot(
              phase: ArtworkPhase.failed,
              requestKey: request.requestKey,
              reason: 'cancelled',
            );
      }
      try {
        final headers = <String, String>{..._safeHeaders(request)};
        if (conditional) {
          if (existing?.etag != null) {
            headers[HttpHeaders.ifNoneMatchHeader] = existing!.etag!;
          }
          if (existing?.lastModified != null) {
            headers[HttpHeaders.ifModifiedSinceHeader] =
                existing!.lastModified!;
          }
        }
        final host = request.host.isEmpty ? '_' : request.host;
        final permit = await _scheduler.acquire(host: host, job: job);
        if (permit == null) throw const ArtworkReject('cancelled');
        job.started = true;
        ArtworkFetchResponse response;
        try {
          if (job.generation != _generation ||
              job.abandoned ||
              !job.hasDemand) {
            throw const ArtworkReject('cancelled');
          }
          diagnostics.network++;
          artworkFetchOrder.add(host);
          _log('network', request, extra: 'priority=${job.priority.name}');
          response = await _fetcher(
            ArtworkFetchRequest(
              uri: uri,
              headers: headers,
              maxBytes: maxImageBytes,
              connectTimeout: connectTimeout,
              headerTimeout: headerTimeout,
              totalBudget: totalBudget,
              // One row scrolling away must not abort a download another row
              // or the player still needs. Abandon only when every consumer left.
              cancelled: () =>
                  _closed ||
                  job.generation != _generation ||
                  job.abandoned ||
                  !job.hasDemand,
              scope: _scopeFor(request, uri),
            ),
          );
        } finally {
          // Backoff must not keep the global or host slot.
          _scheduler.release(permit);
        }
        if (response.status == 304) {
          diagnostics.notModified++;
          if (previous != null) {
            _noteValidated(existing!, request);
            return previous;
          }
          // One unconditional retry. A second 304 still has nothing to show.
          if (conditional) {
            conditional = false;
            continue;
          }
          throw const ArtworkReject('notModified');
        }
        if (response.status != 200) throw ArtworkReject('http');
        final cacheControl = (response.headers['cache-control'] ?? '')
            .toLowerCase();
        final persistent = !cacheControl.contains('no-store');
        final exportable = persistent && !cacheControl.contains('private');
        final path = await _publish(
          request: request,
          bytes: response.bytes,
          headers: response.headers,
          ownerKind: ref.ownerKind,
          ownerId: ref.ownerId,
          persistent: persistent,
          exportable: exportable,
          temporary: ref.temporary,
        );
        if (path == null && !persistent) {
          // _publish already retained an isolated copy. Keep that buffer's
          // identity so MemoryImage can reuse its decoded frame.
          return ArtworkSnapshot(
            phase: ArtworkPhase.ready,
            memoryBytes: _memory[request.requestKey],
            requestKey: request.requestKey,
            reason: 'memory',
          );
        }
        final snapshot = _readySnapshot(
          _alias(request.requestKey),
          request.requestKey,
        );
        if (snapshot != null) return snapshot;
        throw const ArtworkReject('missing');
      } on ArtworkReject catch (error) {
        if (error.reason == 'decode' ||
            error.reason == 'html' ||
            error.reason == 'empty' ||
            error.reason == 'tooLarge') {
          diagnostics.decodeFailure++;
          _rememberFailure(request, error.reason, cooldown: true);
          _log('reject:${error.reason}', request);
          break;
        }
        if (error.reason == 'cancelled' || error.reason == 'notModified') {
          if (error.reason == 'cancelled') diagnostics.cancelled++;
          _rememberFailure(
            request,
            error.reason,
            cooldown: error.reason != 'cancelled',
          );
          return previous ??
              ArtworkSnapshot(
                phase: ArtworkPhase.failed,
                requestKey: request.requestKey,
                reason: error.reason,
              );
        }
        if (attempt < 2) {
          diagnostics.retries++;
          await Future<void>.delayed(_retryDelay(attempt));
          continue;
        }
        _rememberFailure(request, error.reason, cooldown: true);
      } catch (_) {
        if (attempt < 2) {
          diagnostics.retries++;
          await Future<void>.delayed(_retryDelay(attempt));
          continue;
        }
        _rememberFailure(request, 'network', cooldown: true);
      }
    }
    if (previous != null) return previous;
    final failed = _alias(request.requestKey);
    return ArtworkSnapshot(
      phase: ArtworkPhase.failed,
      requestKey: request.requestKey,
      reason: failed?.failure.isNotEmpty == true ? failed!.failure : 'network',
    );
  }

  Duration _retryDelay(int attempt) {
    if (retryBase == Duration.zero) return Duration.zero;
    final millis =
        retryBase.inMilliseconds * (1 << attempt) + _random.nextInt(120);
    return Duration(milliseconds: millis);
  }

  Map<String, String> _safeHeaders(ArtworkRequest request) {
    final blocked = {'cookie', 'authorization', 'proxy-authorization'};
    return {
      for (final entry in request.headers.entries)
        if (!blocked.contains(entry.key.toLowerCase())) entry.key: entry.value,
    };
  }

  NetworkScope _scopeFor(ArtworkRequest request, Uri uri) {
    if (request.adapter == ArtworkAdapter.bilibili) {
      return NetworkScope.bilibili;
    }
    if (request.adapter == ArtworkAdapter.podcast) {
      return NetworkSites.forPodcast(uri);
    }
    return NetworkScope.other;
  }

  Future<ArtworkSnapshot?> _importLegacy(
    ArtworkRequest request,
    ArtworkRef ref,
  ) async {
    final directory = legacyPodcastDirectory;
    if (directory == null) return null;
    final digest = sha256.convert(utf8.encode(request.url)).toString();
    final file = File(p.join(directory.path, '$digest.jpg'));
    if (!file.existsSync()) return null;
    try {
      final path = await adoptFile(
        request: request,
        file: file,
        ownerKind: ref.ownerKind,
        ownerId: ref.ownerId,
      );
      if (path == null) return null;
      diagnostics.disk++;
      _log('legacy', request);
      return _readySnapshot(_alias(request.requestKey), request.requestKey);
    } on ArtworkReject {
      return null;
    }
  }

  Future<String?> _publish({
    required ArtworkRequest request,
    required List<int> bytes,
    required Map<String, String> headers,
    required String ownerKind,
    required String ownerId,
    required bool persistent,
    bool exportable = true,
    bool temporary = false,
  }) async {
    final inspection = inspectArtworkBytes(bytes);
    final hash = sha256.convert(bytes).toString();
    if (!persistent) {
      _rememberMemory(request.requestKey, bytes);
      _saveAlias(
        _Alias(
          requestKey: request.requestKey,
          etag: headers['etag'],
          lastModified: headers['last-modified'],
          validatedMs: _clock().millisecondsSinceEpoch,
          expiresMs: _clock().millisecondsSinceEpoch,
          failure: '',
          persistent: false,
          exportable: false,
        ),
        adapter: request.adapter.name,
        urlDigest: _urlDigest(request.url),
      );
      return null;
    }
    final relative = 'blobs/$hash${inspection.extension}';
    final destination = File(p.join(root.path, relative));
    if (!destination.existsSync()) {
      if (storedBytes + bytes.length > budgetBytes) {
        prune();
      }
      if (storedBytes + bytes.length > budgetBytes) {
        _rememberMemory(request.requestKey, bytes);
        return null;
      }
      final staging = File(
        p.join(
          root.path,
          'staging',
          '${DateTime.now().microsecondsSinceEpoch}-${hash.substring(0, 8)}.part',
        ),
      );
      await staging.parent.create(recursive: true);
      await staging.writeAsBytes(bytes, flush: true);
      final published = inspectArtworkBytes(await staging.readAsBytes());
      if (published.format != inspection.format) {
        await staging.delete();
        throw const ArtworkReject('decode');
      }
      await destination.parent.create(recursive: true);
      if (destination.existsSync()) {
        await staging.delete();
      } else {
        try {
          await staging.rename(destination.path);
        } on FileSystemException {
          await staging.copy(destination.path);
          if (staging.existsSync()) await staging.delete();
        }
      }
    }
    final now = _clock().millisecondsSinceEpoch;
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        '''
        INSERT INTO blobs(blob_hash, relative_path, bytes, format, width, height, used_ms, published)
        VALUES(?,?,?,?,?,?,?,1)
        ON CONFLICT(blob_hash) DO UPDATE SET used_ms=excluded.used_ms, published=1
        ''',
        [
          hash,
          relative,
          bytes.length,
          inspection.format,
          inspection.width,
          inspection.height,
          now,
        ],
      );
      _saveAlias(
        _Alias(
          requestKey: request.requestKey,
          blobHash: hash,
          etag: headers['etag'],
          lastModified: headers['last-modified'],
          validatedMs: now,
          expiresMs: now + _ttl(headers).inMilliseconds,
          failure: '',
          persistent: true,
          exportable: exportable,
        ),
        adapter: request.adapter.name,
        urlDigest: _urlDigest(request.url),
      );
      if (ownerKind.isNotEmpty && ownerId.isNotEmpty) {
        final expires = temporary
            ? now + const Duration(hours: 24).inMilliseconds
            : 0;
        _database.execute(
          '''
          INSERT INTO owners(owner_kind, owner_id, request_key, expires_ms)
          VALUES(?,?,?,?)
          ON CONFLICT(owner_kind, owner_id, request_key) DO UPDATE SET expires_ms=excluded.expires_ms
          ''',
          [ownerKind, ownerId, request.requestKey, expires],
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    // The committed file now owns this request. Keep snapshots already handed
    // to consumers intact, but do not retain superseded no-store bytes here.
    _memory.remove(request.requestKey);
    _log('published', request, extra: 'bytes=${bytes.length}');
    return destination.path;
  }

  Duration _ttl(Map<String, String> headers) {
    final control = (headers['cache-control'] ?? '').toLowerCase();
    final match = RegExp(r'max-age=(\d+)').firstMatch(control);
    if (match != null) {
      return Duration(seconds: int.parse(match.group(1)!));
    }
    return const Duration(days: 7);
  }

  void _rememberOwner(ArtworkRef ref, String requestKey) {
    if (ref.ownerId.isEmpty) return;
    final now = _clock().millisecondsSinceEpoch;
    final expires = ref.temporary
        ? now + const Duration(hours: 24).inMilliseconds
        : 0;
    _database.execute(
      '''
      INSERT INTO owners(owner_kind, owner_id, request_key, expires_ms)
      VALUES(?,?,?,?)
      ON CONFLICT(owner_kind, owner_id, request_key) DO UPDATE SET expires_ms=excluded.expires_ms
      ''',
      [ref.ownerKind, ref.ownerId, requestKey, expires],
    );
  }

  void _rememberFailure(
    ArtworkRequest request,
    String reason, {
    required bool cooldown,
  }) {
    final now = _clock().millisecondsSinceEpoch;
    final previous = _alias(request.requestKey);
    _saveAlias(
      _Alias(
        requestKey: request.requestKey,
        blobHash: previous?.blobHash,
        etag: previous?.etag,
        lastModified: previous?.lastModified,
        validatedMs: previous?.validatedMs ?? now,
        expiresMs: previous?.expiresMs ?? now,
        retryAfterMs: cooldown
            ? now + const Duration(seconds: 30).inMilliseconds
            : now,
        failure: reason,
        persistent: previous?.persistent ?? true,
        exportable: previous?.exportable ?? true,
      ),
      adapter: request.adapter.name,
      urlDigest: _urlDigest(request.url),
    );
    _log('failure:$reason', request);
  }

  void _noteValidated(_Alias alias, ArtworkRequest request) {
    final now = _clock().millisecondsSinceEpoch;
    alias.validatedMs = now;
    alias.expiresMs = now + const Duration(days: 7).inMilliseconds;
    alias.failure = '';
    alias.retryAfterMs = 0;
    _saveAlias(
      alias,
      adapter: request.adapter.name,
      urlDigest: _urlDigest(request.url),
    );
  }

  void _touch(String blobHash) {
    _database.execute('UPDATE blobs SET used_ms=? WHERE blob_hash=?', [
      _clock().millisecondsSinceEpoch,
      blobHash,
    ]);
  }

  _Alias? _alias(String requestKey) {
    final rows = _database.select('SELECT * FROM aliases WHERE request_key=?', [
      requestKey,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return _Alias(
      requestKey: requestKey,
      blobHash: row['blob_hash'] as String?,
      etag: row['etag'] as String?,
      lastModified: row['last_modified'] as String?,
      validatedMs: row['validated_ms'] as int,
      expiresMs: row['expires_ms'] as int,
      retryAfterMs: row['retry_after_ms'] as int,
      failure: row['failure'] as String? ?? '',
      persistent: (row['persistent'] as int) == 1,
      exportable: (row['exportable'] as int) == 1,
    );
  }

  void _saveAlias(_Alias alias, {required String adapter, String? urlDigest}) {
    _database.execute(
      '''
      INSERT INTO aliases(request_key, blob_hash, adapter, url_digest, etag, last_modified, validated_ms, expires_ms, retry_after_ms, failure, persistent, exportable)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(request_key) DO UPDATE SET
        blob_hash=excluded.blob_hash,
        etag=excluded.etag,
        last_modified=excluded.last_modified,
        validated_ms=excluded.validated_ms,
        expires_ms=excluded.expires_ms,
        retry_after_ms=excluded.retry_after_ms,
        failure=excluded.failure,
        persistent=excluded.persistent,
        exportable=excluded.exportable
      ''',
      [
        alias.requestKey,
        alias.blobHash,
        adapter,
        urlDigest ?? _alias(alias.requestKey)?.requestKey ?? alias.requestKey,
        alias.etag,
        alias.lastModified,
        alias.validatedMs,
        alias.expiresMs,
        alias.retryAfterMs,
        alias.failure,
        alias.persistent ? 1 : 0,
        alias.exportable ? 1 : 0,
      ],
    );
  }

  void _rememberMemory(String key, List<int> bytes) {
    _memory.remove(key);
    _memory[key] = Uint8List.fromList(bytes);
    while (_memory.length > 32) {
      _memory.remove(_memory.keys.first);
    }
  }

  String _urlDigest(String url) =>
      sha256.convert(utf8.encode(url)).toString().substring(0, 12);

  void _log(String event, ArtworkRequest request, {String extra = ''}) {
    final key = request.requestKey.substring(0, 8);
    developer.log(
      'artwork $event key=$key host=${request.host} scope=${request.adapter.name} $extra'
          .trim(),
      name: 'artwork',
    );
  }
}

/// Podcast and Bilibili covers go through the shared client so a redirect is
/// classified again by its real host. Callers pass a fake fetcher in tests.
Future<ArtworkFetchResponse> defaultArtworkFetcher(
  ArtworkFetchRequest request,
) async {
  final podcast =
      request.scope == NetworkScope.podcasts ||
      request.scope == NetworkScope.podcastsDomestic;
  final client = podcast
      ? NetworkHttp.instance.createPodcastClient(
          routeFor: (uri) => NetworkSites.forPodcast(uri).defaultMode,
        )
      : NetworkHttp.instance.createClient(
          scope: request.scope,
          source: request.uri,
        );
  client.connectionTimeout = request.connectTimeout;
  final deadline = DateTime.now().add(request.totalBudget);
  Duration remaining() {
    if (request.cancelled()) throw const ArtworkReject('cancelled');
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) throw TimeoutException('封面读取超时');
    return left;
  }

  Duration headerWait() {
    final left = remaining();
    return left < request.headerTimeout ? left : request.headerTimeout;
  }

  try {
    final httpRequest = await openNetworkRequest(
      client,
      'GET',
      request.uri,
      timeout: headerWait(),
    );
    httpRequest.headers.set(
      HttpHeaders.userAgentHeader,
      request.scope == NetworkScope.bilibili
          ? request.headers[HttpHeaders.userAgentHeader] ?? 'FluentPlayer/1.0'
          : 'FluentPlayer/1.0 Podcast',
    );
    request.headers.forEach((name, value) {
      if (name.toLowerCase() == 'cookie' ||
          name.toLowerCase() == 'authorization') {
        return;
      }
      httpRequest.headers.set(name, value);
    });
    final response = await httpRequest.close().timeout(headerWait());
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    if (response.statusCode != 200) {
      await response.listen((_) {}).cancel();
      return ArtworkFetchResponse(
        status: response.statusCode,
        headers: headers,
        bytes: const [],
        finalUri: request.uri,
      );
    }
    final List<int> bytes;
    try {
      bytes = await readNetworkResponseBytes(
        response,
        maxBytes: request.maxBytes,
        idleTimeout: request.totalBudget,
        totalTimeout: remaining(),
        onBytes: (_, _) {
          if (request.cancelled()) throw const ArtworkReject('cancelled');
        },
      );
    } on FormatException {
      throw const ArtworkReject('tooLarge');
    }
    return ArtworkFetchResponse(
      status: response.statusCode,
      headers: headers,
      bytes: bytes,
      finalUri: request.uri,
    );
  } finally {
    client.close(force: true);
  }
}
