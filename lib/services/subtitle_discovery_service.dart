import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/subtitle_source_type.dart';
import 'subtitle_word_timing_store.dart';
import '../utils/subtitle_parser.dart';
import '../utils/subtitle_duration_reader.dart';
import '../utils/subtitle_file_matcher.dart';

/// 一个被扫描到的同文件夹字幕文件。
///
/// [analysis] 来自 [SubtitleFileMatcher] 的纯函数判定；自动加载方只应消费
/// [SubtitleMatchGrade.autoMatch] 且排序靠前的条目，手动面板可展示全部等级。
class DiscoveredSubtitleFile {
  final String path;
  final DateTime modifiedAt;
  final int length;
  final SubtitleSourceType sourceType;

  /// 由引擎给出、可被时长校验降级的判定结果。
  SubtitleFileNameAnalysis analysis;

  /// 时长二次校验得到的字幕最大结束时间（毫秒），未能解析时为 null。
  final int? subtitleDurationMs;

  DiscoveredSubtitleFile({
    required this.path,
    required this.modifiedAt,
    required this.length,
    this.sourceType = SubtitleSourceType.sidecar,
    required this.analysis,
    this.subtitleDurationMs,
  });

  SubtitleMatchGrade get grade => analysis.grade;
  bool get isAuto => analysis.isAuto;
}

/// 同文件夹字幕发现服务。
///
/// 职责：
/// 1. 枚举视频同目录中所有受支持的字幕文件（非递归）；
/// 2. 用 [SubtitleFileMatcher] 做资格判定与分级；
/// 3. 当传入 [videoDurationMs] 时，仅对 A 类（可自动）候选做轻量时长解析，
///    与视频时长严重不符的候选降级为 manual（不强行自动匹配）；
/// 4. 排序：auto（语言权重 → 名称干净度 → 时长接近度 → 修改时间）→
///    manual → rejected。
class SubtitleDiscoveryService {
  const SubtitleDiscoveryService();

  static const SubtitleDurationReader _durationReader =
      SubtitleDurationReader();

  /// 允许进入时长二次校验的 A 类候选上限（避免对文件夹中大量同名变体
  /// 全部读盘）。
  static const int _durationValidationLimit = 8;

  /// Only filesystem inputs have a directory that dart:io can enumerate.
  /// Cloud identities, URLs and Android document URIs use other access paths;
  /// treating them as files can even scan the process's working directory.
  static String? localVideoPath(String videoPath) {
    if (videoPath.trim().isEmpty) return null;
    // A Windows drive letter is not a URI scheme (including drive-relative
    // paths). UNC paths have no scheme and pass through below as well.
    if (Platform.isWindows && RegExp(r'^[a-zA-Z]:').hasMatch(videoPath)) {
      return p.normalize(videoPath);
    }
    final uri = Uri.tryParse(videoPath);
    if (uri == null &&
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(videoPath)) {
      return null;
    }
    if (uri != null && uri.hasScheme) {
      if (uri.scheme != 'file' ||
          uri.pathSegments.every((segment) => segment.isEmpty)) {
        return null;
      }
      try {
        return p.normalize(uri.toFilePath());
      } on ArgumentError {
        return null;
      } on UnsupportedError {
        return null;
      }
    }
    return p.normalize(videoPath);
  }

  Future<List<DiscoveredSubtitleFile>> scanVideoDirectory({
    required String videoPath,
    int? videoDurationMs,
  }) async {
    final localPath = localVideoPath(videoPath);
    if (localPath == null) return const <DiscoveredSubtitleFile>[];
    // A missing directory or revoked access must not prevent the caller from
    // listing subtitles already saved for the card.
    final Directory directory;
    try {
      directory = File(localPath).parent;
      if (!await directory.exists()) return const <DiscoveredSubtitleFile>[];
    } on FileSystemException {
      return const <DiscoveredSubtitleFile>[];
    }

    final videoStem = p.basenameWithoutExtension(localPath);

    final files = <File>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            SubtitleWordTimingStore.isCompanion(entity.path)) {
          continue;
        }
        final ext = p.extension(entity.path).toLowerCase();
        if (!SubtitleFileMatcher.supportedExtensions.contains(ext)) continue;
        if (ext == '.json' || ext == '.xml') {
          try {
            if (await entity.length() > 100 * 1024 * 1024 ||
                SubtitleParser.parse(
                  SubtitleParser.decodeBytes(await entity.readAsBytes()),
                  sourcePath: entity.path,
                ).isEmpty) {
              continue;
            }
          } catch (_) {
            continue;
          }
        }
        files.add(entity);
      }
    } on FileSystemException {
      return const <DiscoveredSubtitleFile>[];
    }

    // 1) 名称资格判定（纯函数，无 IO）。
    final analyzed = <DiscoveredSubtitleFile>[];
    for (final file in files) {
      final analysis = SubtitleFileMatcher.analyzeStems(
        videoStem: videoStem,
        subtitleStem: p.basenameWithoutExtension(file.path),
      );
      final stat = await _tryStat(file);
      if (stat == null) continue;
      analyzed.add(
        DiscoveredSubtitleFile(
          path: p.normalize(file.path),
          modifiedAt: stat.modified,
          length: stat.size,
          analysis: analysis,
        ),
      );
    }

    if (analyzed.isEmpty) return analyzed;

    // 2) 时长二次校验：只对 A 类候选、且在提供了视频时长时才执行。
    final autoCandidates = analyzed
        .where((entry) => entry.analysis.isAuto)
        .toList();
    final durationMap = <String, int?>{};
    if (videoDurationMs != null && videoDurationMs > 0) {
      final limited = autoCandidates.take(_durationValidationLimit).toList();
      final results = await Future.wait(
        limited.map((entry) => _durationReader.readMaxEndMs(File(entry.path))),
      );
      for (var i = 0; i < limited.length; i++) {
        durationMap[limited[i].path] = results[i];
      }

      // 严重不符（时长不足一半或超两倍）→ 降级为 manual，绝不允许自动匹配。
      final autoSnapshot = analyzed
          .where((entry) => entry.analysis.isAuto)
          .toList();
      for (final entry in autoSnapshot) {
        final subDuration = durationMap[entry.path];
        if (subDuration == null) continue; // 信息缺失：中性处理
        final ratio = subDuration / videoDurationMs;
        if (ratio < 0.5 || ratio > 2.0) {
          entry.analysis = SubtitleFileNameAnalysis(
            grade: SubtitleMatchGrade.manualOnly,
            languageCode: entry.analysis.languageCode,
            languageRank: entry.analysis.languageRank,
            exactCoreMatch: entry.analysis.exactCoreMatch,
            decorationGroupCount: entry.analysis.decorationGroupCount,
            trailingTagCount: entry.analysis.trailingTagCount,
            hasNoiseSuffix: true,
          );
        }
      }
    }

    analyzed.sort(
      (a, b) => _compareEntries(a, b, videoDurationMs, durationMap),
    );
    return analyzed;
  }

  Future<FileStat?> _tryStat(File file) async {
    try {
      return await file.stat();
    } on FileSystemException {
      return null;
    }
  }

  int _compareEntries(
    DiscoveredSubtitleFile a,
    DiscoveredSubtitleFile b,
    int? videoDurationMs,
    Map<String, int?> durationMap,
  ) {
    final order = _gradeOrder(a, b);
    if (order != 0) return order;

    // 同等级内部排序。
    final aAuto = a.isAuto;
    final langCmp = a.analysis.languageRank.compareTo(b.analysis.languageRank);
    if (langCmp != 0) return langCmp;

    final cleanCmp =
        (a.analysis.decorationGroupCount + a.analysis.trailingTagCount)
            .compareTo(
              b.analysis.decorationGroupCount + b.analysis.trailingTagCount,
            );
    if (cleanCmp != 0) return cleanCmp;

    if (aAuto && videoDurationMs != null && videoDurationMs > 0) {
      final ratioCmp = _durationClosenessCmp(
        a,
        b,
        videoDurationMs,
        durationMap,
      );
      if (ratioCmp != 0) return ratioCmp;
    }

    final mtimeCmp = b.modifiedAt.compareTo(a.modifiedAt);
    if (mtimeCmp != 0) return mtimeCmp;
    return p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase());
  }

  int _gradeOrder(DiscoveredSubtitleFile a, DiscoveredSubtitleFile b) {
    int gradeValue(SubtitleMatchGrade g) => switch (g) {
      SubtitleMatchGrade.autoMatch => 0,
      SubtitleMatchGrade.manualOnly => 1,
      SubtitleMatchGrade.rejected => 2,
    };
    return gradeValue(a.grade).compareTo(gradeValue(b.grade));
  }

  int _durationClosenessCmp(
    DiscoveredSubtitleFile a,
    DiscoveredSubtitleFile b,
    int videoDurationMs,
    Map<String, int?> durationMap,
  ) {
    double? closenessA = _closeness(durationMap[a.path], videoDurationMs);
    double? closenessB = _closeness(durationMap[b.path], videoDurationMs);
    final tierA = _ratioTier(closenessA);
    final tierB = _ratioTier(closenessB);
    if (tierA != tierB) return tierA.compareTo(tierB);
    if (tierA == 0) {
      // 同层时取更接近 1 的。
      closenessA ??= double.infinity;
      closenessB ??= double.infinity;
      return closenessA.compareTo(closenessB);
    }
    return 0;
  }

  /// 字幕时长/视频时长的接近度 |ratio - 1|；字幕时长未知时为 null。
  double? _closeness(int? subtitleMs, int videoDurationMs) {
    if (subtitleMs == null || subtitleMs <= 0) return null;
    final ratio = subtitleMs / videoDurationMs;
    return (ratio - 1.0).abs();
  }

  /// 0 = 接近（0.75–1.3 区间或信息缺失），1 = 略远（0.5–0.75 / 1.3–2）。
  int _ratioTier(double? closeness) {
    if (closeness == null) return 0; // 信息缺失中性处理
    return closeness <= 0.3 ? 0 : 1;
  }
}
