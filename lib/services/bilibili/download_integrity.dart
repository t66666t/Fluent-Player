import 'dart:math' as math;

import 'package:video_player_app/models/bilibili_download_task.dart';

class DownloadIntegrityException implements Exception {
  const DownloadIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'DownloadIntegrityException: $message';
}

class BilibiliContentRange {
  const BilibiliContentRange({
    required this.start,
    required this.endInclusive,
    this.totalBytes,
  });

  final int start;
  final int endInclusive;
  final int? totalBytes;

  int get length => endInclusive - start + 1;
}

class BilibiliDownloadIntegrity {
  const BilibiliDownloadIntegrity._();

  static const int defaultMinBytesPerConnection = 16 * 1024 * 1024;

  static BilibiliContentRange? parseContentRange(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(contentRange.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final totalText = match.group(3)!;
    final total = totalText == '*' ? null : int.tryParse(totalText);
    if (start == null || end == null || start < 0 || end < start) return null;
    if (total != null && (total <= 0 || end >= total)) return null;
    return BilibiliContentRange(
      start: start,
      endInclusive: end,
      totalBytes: total,
    );
  }

  static int? contentRangeStart(String? contentRange) {
    return parseContentRange(contentRange)?.start;
  }

  static bool matchesRequestedRange({
    required String? contentRange,
    required int start,
    required int endInclusive,
    required int totalBytes,
  }) {
    final parsed = parseContentRange(contentRange);
    return parsed != null &&
        parsed.start == start &&
        parsed.endInclusive == endInclusive &&
        parsed.totalBytes == totalBytes;
  }

  static List<DownloadRangePartState> createRangePlan({
    required int totalBytes,
    required int requestedConnections,
    int contiguousBytes = 0,
    int minBytesPerConnection = defaultMinBytesPerConnection,
  }) {
    if (totalBytes <= 0) return const <DownloadRangePartState>[];
    final safeMinimum = math.max(1, minBytesPerConnection);
    final maximumUsefulConnections = math.max(1, totalBytes ~/ safeMinimum);
    final connectionCount = math.min(
      requestedConnections.clamp(1, 4),
      maximumUsefulConnections,
    );
    final partLength = (totalBytes / connectionCount).ceil();
    final existing = contiguousBytes.clamp(0, totalBytes);
    final parts = <DownloadRangePartState>[];
    for (var index = 0; index < connectionCount; index++) {
      final start = index * partLength;
      if (start >= totalBytes) break;
      final end = math.min(totalBytes - 1, start + partLength - 1);
      final length = end - start + 1;
      final downloaded = (existing - start).clamp(0, length);
      parts.add(
        DownloadRangePartState(
          start: start,
          endInclusive: end,
          downloadedBytes: downloaded,
        ),
      );
    }
    return parts;
  }

  static bool isValidRangePlan(
    List<DownloadRangePartState> parts, {
    required int totalBytes,
  }) {
    if (totalBytes <= 0 || parts.isEmpty) return false;
    var expectedStart = 0;
    for (final part in parts) {
      if (part.start != expectedStart ||
          part.endInclusive < part.start ||
          part.endInclusive >= totalBytes ||
          part.downloadedBytes < 0 ||
          part.downloadedBytes > part.length) {
        return false;
      }
      expectedStart = part.endInclusive + 1;
    }
    return expectedStart == totalBytes;
  }

  static void validateCompletedLength({
    required String label,
    required int actualBytes,
    required int? expectedBytes,
  }) {
    if (actualBytes <= 0) {
      throw DownloadIntegrityException('$label 文件为空');
    }
    if (expectedBytes != null && actualBytes != expectedBytes) {
      throw DownloadIntegrityException(
        '$label 大小不完整：$actualBytes/$expectedBytes bytes',
      );
    }
  }
}
