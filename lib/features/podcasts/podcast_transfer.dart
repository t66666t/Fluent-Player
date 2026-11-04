import 'dart:io';
import 'dart:math';
import 'podcast_models.dart';

const podcastWindowChunkBytes = 1024 * 1024;

/// Transport limits shared by playback, manual downloads and AI preparation.
///
/// Disk chunks stay at 1 MiB so existing caches remain valid. Network windows
/// are larger so a high-latency source is not charged a new connection per chunk.
class PodcastTransferPolicy {
  const PodcastTransferPolicy();
  static const windowBytes = 4 * podcastWindowChunkBytes;
  static const bulkWindowBytes = 16 * podcastWindowChunkBytes;
  static const maxWindowsPerAsset = 2;
  static const maxGlobalWindows = 4;
  static const maxHostBulkWindows = 3;
  static const maxHostWindows = 4;
  static const connectTimeout = Duration(seconds: 15);
  static const requestTimeout = Duration(seconds: 20);
  static const headerTimeout = Duration(seconds: 25);
  static const bodyIdleTimeout = Duration(seconds: 30);
  static const stallNotice = Duration(seconds: 5);
  static const slowWarmup = Duration(seconds: 20);
  static const slowSample = Duration(seconds: 60);
  static const slowBytesPerSecond = 16 * 1024;
  static const slowRecoveryLimit = 2;
  static const slowRecoverySpacing = Duration(minutes: 5);
  static const leaseTtl = Duration(seconds: 120);
  static const leaseRenew = Duration(seconds: 30);
  static const speedWindow = Duration(seconds: 5);
  static const hostRecovery = Duration(minutes: 10);
  static const assembleMarginBytes = 64 * 1024 * 1024;
}

enum PodcastTransferFailureKind {
  network,
  timeout,
  retryLater,
  client,
  range,
  media,
  version,
  cancelled,
  space,
}

class PodcastTransferException extends HttpException {
  PodcastTransferException(
    super.message, {
    required this.kind,
    this.retryAfter,
    this.retryable = false,
  });
  final PodcastTransferFailureKind kind;
  final Duration? retryAfter;
  final bool retryable;
}

/// One contiguous byte window that still needs to be fetched.
class PodcastByteWindow {
  const PodcastByteWindow(this.start, this.endInclusive);
  final int start, endInclusive;
  int get length => endInclusive - start + 1;
}

/// Plans non-overlapping windows over missing 1 MiB chunks.
///
/// A completed chunk is never pulled again just to make a window larger.
List<PodcastByteWindow> planPodcastWindows({
  required int? total,
  required Set<int> present,
  int chunkBytes = podcastWindowChunkBytes,
  int windowBytes = PodcastTransferPolicy.windowBytes,
  int maxWindows = PodcastTransferPolicy.maxWindowsPerAsset,
  bool rangeSupported = true,
}) {
  if (!rangeSupported || maxWindows < 1) return const [];
  final windows = <PodcastByteWindow>[];
  var index = 0;
  final knownEnd = total == null ? null : max(0, total - 1);
  while (maxWindows > windows.length) {
    if (knownEnd != null && index * chunkBytes > knownEnd) break;
    if (present.contains(index)) {
      index++;
      continue;
    }
    final start = index * chunkBytes;
    if (knownEnd != null && start > knownEnd) break;
    var end = start;
    var covered = 0;
    while (covered < windowBytes) {
      final chunkStart = index * chunkBytes;
      if (knownEnd != null && chunkStart > knownEnd) break;
      if (present.contains(index) && chunkStart != start) break;
      if (present.contains(index)) break;
      final chunkEnd = knownEnd == null
          ? chunkStart + chunkBytes - 1
          : min(knownEnd, chunkStart + chunkBytes - 1);
      final room = windowBytes - covered;
      final take = min(room, chunkEnd - chunkStart + 1);
      end = chunkStart + take - 1;
      covered += take;
      if (take < chunkBytes || (knownEnd != null && end >= knownEnd)) {
        index++;
        break;
      }
      index++;
      if (knownEnd != null && end >= knownEnd) break;
    }
    if (end >= start) windows.add(PodcastByteWindow(start, end));
    if (knownEnd == null) break;
  }
  return windows;
}

class PodcastSpeedWindow {
  final List<(int, int)> _samples = [];
  void add(int nowMs, int usefulBytes) {
    _samples.add((nowMs, usefulBytes));
    final cutoff = nowMs - PodcastTransferPolicy.speedWindow.inMilliseconds;
    _samples.removeWhere((sample) => sample.$1 < cutoff);
  }

  void clear() => _samples.clear();

  /// Recent useful throughput. Idle gaps collapse the rate to zero so an old
  /// average cannot keep an ETA on screen after the source stalls.
  double bytesPerSecond(int nowMs) {
    if (_samples.length < 2) return 0;
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = nowMs - first.$1;
    if (elapsed < 150) return 0;
    if (nowMs - last.$1 > PodcastTransferPolicy.stallNotice.inMilliseconds) {
      return 0;
    }
    final delta = last.$2 - first.$2;
    if (delta <= 0) return 0;
    return delta * 1000 / elapsed;
  }
}

class PodcastSlowDecision {
  const PodcastSlowDecision({this.notice = false, this.recover = false});
  final bool notice, recover;
}

PodcastSlowDecision evaluatePodcastSlow({
  required int elapsedMs,
  required int recentUsefulBytes,
  required int recentElapsedMs,
  required int recoveries,
  required int lastRecoveryMs,
  required int nowMs,
  required bool playbackBackpressure,
  required bool hasMissingBytes,
}) {
  if (!hasMissingBytes || playbackBackpressure) {
    return const PodcastSlowDecision();
  }
  if (elapsedMs < PodcastTransferPolicy.slowWarmup.inMilliseconds) {
    return const PodcastSlowDecision();
  }
  if (recentElapsedMs < PodcastTransferPolicy.slowSample.inMilliseconds) {
    return const PodcastSlowDecision();
  }
  final rate = recentElapsedMs <= 0
      ? 0
      : recentUsefulBytes * 1000 / recentElapsedMs;
  if (rate >= PodcastTransferPolicy.slowBytesPerSecond) {
    return const PodcastSlowDecision();
  }
  final spaced =
      lastRecoveryMs == 0 ||
      nowMs - lastRecoveryMs >=
          PodcastTransferPolicy.slowRecoverySpacing.inMilliseconds;
  final recover =
      recoveries < PodcastTransferPolicy.slowRecoveryLimit && spaced;
  return PodcastSlowDecision(notice: true, recover: recover);
}

class PodcastRangeVerdict {
  const PodcastRangeVerdict({
    required this.status,
    this.bodyStart,
    this.bodyEnd,
    this.total,
    this.rangeIgnored = false,
    this.endOfFile = false,
    this.versionChanged = false,
    this.failure,
    this.kind = PodcastTransferFailureKind.network,
    this.retryable = false,
    this.retryAfter,
    this.etag,
    this.modified,
    this.mime,
    this.resolvedUrl,
  });
  final int status;
  final int? bodyStart, bodyEnd, total;
  final bool rangeIgnored, endOfFile, versionChanged, retryable;
  final PodcastTransferFailureKind kind;
  final Duration? retryAfter;
  final String? failure, etag, modified, mime, resolvedUrl;
  bool get ok =>
      failure == null && (status == 200 || status == 206 || endOfFile);
}

Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) {
    return Duration(seconds: max(0, seconds));
  }
  DateTime? date;
  try {
    date = HttpDate.parse(value.trim());
  } on HttpException {
    date = DateTime.tryParse(value.trim());
  }
  if (date == null) return null;
  final delta = date.toUtc().difference((now ?? DateTime.now()).toUtc());
  if (delta.isNegative) return Duration.zero;
  return delta;
}

bool podcastBodyLooksLikeError(String? mime, List<int> prefix) {
  final type = (mime ?? '').toLowerCase();
  if (type.startsWith('audio/') ||
      type.startsWith('video/') ||
      type == 'application/ogg' ||
      type == 'application/mp4' ||
      type == 'application/x-mpegurl') {
    return false;
  }
  if (type.contains('html') ||
      type.contains('json') ||
      type.startsWith('text/')) {
    return true;
  }
  if (prefix.length >= 5) {
    final head = String.fromCharCodes(prefix.take(12)).toLowerCase();
    if (head.startsWith('<!doctype') ||
        head.startsWith('<html') ||
        head.startsWith('{') ||
        head.startsWith('[')) {
      return type.isEmpty ||
          type.contains('text') ||
          type.contains('json') ||
          type.contains('html') ||
          type == 'application/octet-stream';
    }
  }
  return false;
}

PodcastRangeVerdict interpretPodcastResponse({
  required int status,
  required int requestStart,
  required int requestEnd,
  String? contentRange,
  int? contentLength,
  String? etag,
  String? modified,
  String? mime,
  String? previousEtag,
  String? previousModified,
  int? previousTotal,
  String? retryAfter,
  DateTime? now,
}) {
  final retry = parseRetryAfter(retryAfter, now: now);
  if (status == 429 || status == 503 || status == 408) {
    return PodcastRangeVerdict(
      status: status,
      failure: '媒体来源返回 $status',
      kind: PodcastTransferFailureKind.retryLater,
      retryable: true,
      retryAfter: retry,
      etag: etag,
      modified: modified,
      mime: mime,
    );
  }
  if (status >= 500) {
    final hard = status == 501 || status == 505;
    return PodcastRangeVerdict(
      status: status,
      failure: '媒体来源返回 $status',
      kind: PodcastTransferFailureKind.network,
      retryable: !hard,
      etag: etag,
      modified: modified,
      mime: mime,
    );
  }
  if (status >= 400 && status != 416) {
    return PodcastRangeVerdict(
      status: status,
      failure: '媒体来源返回 $status',
      kind: PodcastTransferFailureKind.client,
      retryable: false,
      etag: etag,
      modified: modified,
      mime: mime,
    );
  }
  if (status == 416) {
    final atEof = previousTotal != null && requestStart >= previousTotal;
    if (atEof) {
      return PodcastRangeVerdict(
        status: status,
        endOfFile: true,
        total: previousTotal,
        etag: etag,
        modified: modified,
        mime: mime,
      );
    }
    return const PodcastRangeVerdict(
      status: 416,
      failure: '媒体范围无效，请刷新节目后重试',
      kind: PodcastTransferFailureKind.range,
    );
  }
  final match = contentRange == null
      ? null
      : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(contentRange);
  if (status == 206) {
    if (match == null) {
      return const PodcastRangeVerdict(
        status: 206,
        failure: '来源返回了错误的数据范围',
        kind: PodcastTransferFailureKind.range,
      );
    }
    final start = int.parse(match[1]!), end = int.parse(match[2]!);
    final total = match[3] == '*' ? null : int.parse(match[3]!);
    if (start != requestStart ||
        end < start ||
        end > requestEnd ||
        (total != null && end >= total) ||
        (contentLength != null &&
            contentLength >= 0 &&
            contentLength != end - start + 1)) {
      return const PodcastRangeVerdict(
        status: 206,
        failure: '来源返回了错误的数据范围',
        kind: PodcastTransferFailureKind.range,
      );
    }
    final versionChanged =
        (previousEtag != null && etag != null && previousEtag != etag) ||
        (previousModified != null &&
            modified != null &&
            previousModified != modified) ||
        (previousTotal != null && total != null && previousTotal != total);
    return PodcastRangeVerdict(
      status: status,
      bodyStart: start,
      bodyEnd: end,
      total: total,
      versionChanged: versionChanged,
      etag: etag,
      modified: modified,
      mime: mime,
    );
  }
  if (status == 200) {
    final total = contentLength != null && contentLength >= 0
        ? contentLength
        : null;
    final versionChanged =
        (previousEtag != null && etag != null && previousEtag != etag) ||
        (previousModified != null &&
            modified != null &&
            previousModified != modified) ||
        (previousTotal != null && total != null && previousTotal != total);
    return PodcastRangeVerdict(
      status: status,
      bodyStart: 0,
      bodyEnd: total == null ? null : total - 1,
      total: total,
      rangeIgnored: true,
      versionChanged: versionChanged,
      etag: etag,
      modified: modified,
      mime: mime,
    );
  }
  return PodcastRangeVerdict(
    status: status,
    failure: '媒体来源返回 $status',
    kind: PodcastTransferFailureKind.network,
    retryable: true,
  );
}

class PodcastTranscriptionSource {
  const PodcastTranscriptionSource({
    this.media,
    this.reason,
    this.waiting = false,
  });
  final PodcastMedia? media;
  final String? reason;
  final bool waiting;
  bool get available => media != null && !waiting;
}

/// Shared by the empty-state button and the runtime so both see the same file.
PodcastTranscriptionSource resolveTranscriptionSource({
  required PodcastEpisode episode,
  required String? selectedUrl,
  required bool Function(String url) isComplete,
  String? activeDownloadUrl,
}) {
  if (episode.media.isEmpty) {
    return const PodcastTranscriptionSource(reason: '这期节目没有可转录的媒体文件');
  }
  bool file(PodcastMedia media) => !media.isStreamManifest;
  final selected = episode.media
      .where((media) => media.url == selectedUrl)
      .firstOrNull;
  if (selected != null && file(selected) && isComplete(selected.url)) {
    return PodcastTranscriptionSource(media: selected);
  }
  final active = activeDownloadUrl == null
      ? null
      : episode.media
            .where((media) => media.url == activeDownloadUrl)
            .firstOrNull;
  if (active != null &&
      file(active) &&
      selected != null &&
      active.url != selected.url &&
      !isComplete(selected.url)) {
    return const PodcastTranscriptionSource(
      reason: '这集正在下载另一个版本，请等该下载完成后再生成字幕',
      waiting: true,
    );
  }
  final audio = episode.media.where((media) => file(media) && !media.isVideo);
  if (selected != null && file(selected)) {
    return PodcastTranscriptionSource(media: selected);
  }
  final independent = audio.firstOrNull;
  if (independent != null) {
    return PodcastTranscriptionSource(media: independent);
  }
  final other = episode.media.where(file).firstOrNull;
  if (other != null) return PodcastTranscriptionSource(media: other);
  return const PodcastTranscriptionSource(reason: '当前来源是分段流媒体，请选择音频文件或 MP4 版本');
}

enum PodcastOfficialTranscript { unknown, loading, absent, failed, loaded }

enum PodcastTranscriptActionKind {
  loading,
  generate,
  failedTranscript,
  viewProgress,
  retryTask,
  loadGenerated,
  retrySelected,
  sessionLoading,
  unsupported,
}

class PodcastTranscriptAction {
  const PodcastTranscriptAction({
    required this.kind,
    required this.message,
    required this.primaryLabel,
    this.enabled = true,
    this.detail = '识别人声，为本期节目生成可跟随播放的字幕',
  });
  final PodcastTranscriptActionKind kind;
  final String message, primaryLabel, detail;
  final bool enabled;
}

PodcastTranscriptAction resolvePodcastTranscriptAction({
  required bool sessionReady,
  required bool sourceSupported,
  required PodcastOfficialTranscript official,
  required bool aiRunning,
  required bool aiFailed,
  required bool hasGenerated,
  required bool generatedLoaded,
  bool subtitlesLoading = false,
  bool hasSelectedSubtitle = false,
  String? stage,
  String? failure,
}) {
  if (!sessionReady) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.sessionLoading,
      message: '节目正在载入',
      primaryLabel: '语音转录',
      enabled: false,
      detail: '',
    );
  }
  if (subtitlesLoading) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.loading,
      message: '正在加载文字稿',
      primaryLabel: '',
      enabled: false,
      detail: '',
    );
  }
  if (hasSelectedSubtitle) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.retrySelected,
      message: '已选文字稿暂时未能读取',
      primaryLabel: '重新加载字幕',
      detail: '',
    );
  }
  if (!sourceSupported) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.unsupported,
      message: '当前来源不支持 AI 转录，可选择文件版',
      primaryLabel: '语音转录',
      enabled: false,
      detail: '',
    );
  }
  if (aiRunning) {
    return PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.viewProgress,
      message: stage == null || stage.isEmpty ? '正在语音转录' : stage,
      primaryLabel: '查看转录进度',
    );
  }
  if (aiFailed) {
    return PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.retryTask,
      message: failure == null || failure.isEmpty ? '语音转录已暂停' : failure,
      primaryLabel: '继续语音转录',
    );
  }
  if (hasGenerated && !generatedLoaded) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.loadGenerated,
      message: '已有生成结果',
      primaryLabel: '加载已生成字幕',
      detail: '',
    );
  }
  if (official == PodcastOfficialTranscript.loading) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.loading,
      message: '正在加载文字稿',
      primaryLabel: '语音转录',
    );
  }
  if (official == PodcastOfficialTranscript.failed) {
    return const PodcastTranscriptAction(
      kind: PodcastTranscriptActionKind.failedTranscript,
      message: '文字稿加载失败',
      primaryLabel: '语音转录',
    );
  }
  return const PodcastTranscriptAction(
    kind: PodcastTranscriptActionKind.generate,
    message: '本期暂无文字稿',
    primaryLabel: '语音转录',
  );
}
