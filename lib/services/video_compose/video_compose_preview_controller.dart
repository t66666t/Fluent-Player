import '../subtitle_font_service.dart';
import 'package:flutter/foundation.dart';

import '../../models/subtitle_display_state.dart';
import '../../models/subtitle_model.dart';
import '../../widgets/subtitle_overlay.dart';
import 'video_compose_subtitle_service.dart';

@immutable
class VideoComposePreviewConfig {
  final String? primarySubtitlePath;
  final String? secondarySubtitlePath;
  final bool renderSecondarySubtitle;
  final bool continuousSubtitle;
  final bool splitSubtitleByLine;
  final bool burnSubtitles;

  const VideoComposePreviewConfig({
    required this.primarySubtitlePath,
    required this.secondarySubtitlePath,
    required this.renderSecondarySubtitle,
    required this.continuousSubtitle,
    required this.splitSubtitleByLine,
    required this.burnSubtitles,
  });
}

/// Owns the temporary subtitle timeline shown while the compose panel is open.
/// It never writes to MediaPlaybackService or the video's persisted subtitles.
class VideoComposePreviewController {
  VideoComposePreviewController({
    VideoComposeSubtitleService subtitleService =
        const VideoComposeSubtitleService(),
  }) : _subtitleService = subtitleService;

  final VideoComposeSubtitleService _subtitleService;
  final ValueNotifier<SubtitleDisplayState> displayNotifier =
      ValueNotifier<SubtitleDisplayState>(SubtitleDisplayState.empty);

  VideoComposePreviewConfig? _config;
  VideoComposePreviewConfig? get config => _config;
  String? fontLanguage(bool secondary) {
    final config = _config;
    if (config == null) return null;
    final fonts = SubtitleFontService.instance;
    final source = secondary
        ? fonts.secondarySource(
            config.primarySubtitlePath,
            config.secondarySubtitlePath,
          )
        : config.primarySubtitlePath;
    final texts = secondary
        ? (_secondary.isNotEmpty
              ? _secondary.map((s) => s.text)
              : _primary.map((s) => s.text.split('\n').skip(1).join('\n')))
        : _primary.map((s) => s.text);
    return fonts.languageForSource(source, texts: texts.take(100));
  }

  List<SubtitleItem> _primary = const <SubtitleItem>[];
  List<SubtitleItem> _secondary = const <SubtitleItem>[];
  List<int> _primaryStarts = const <int>[];
  List<int> _secondaryStarts = const <int>[];
  final Map<int, Uint8List?> _primaryImages = <int, Uint8List?>{};
  int _loadGeneration = 0;
  Duration _lastPosition = Duration.zero;
  bool _disposed = false;

  Future<void> configure(VideoComposePreviewConfig config) async {
    if (_disposed) return;
    final previous = _config;
    _config = config;
    final bool timelineChanged =
        previous == null ||
        previous.primarySubtitlePath != config.primarySubtitlePath ||
        previous.secondarySubtitlePath != config.secondarySubtitlePath ||
        previous.renderSecondarySubtitle != config.renderSecondarySubtitle ||
        previous.burnSubtitles != config.burnSubtitles;
    if (!timelineChanged) {
      update(_lastPosition);
      return;
    }

    final int generation = ++_loadGeneration;
    _primaryImages.clear();
    displayNotifier.value = SubtitleDisplayState.empty;
    if (!config.burnSubtitles) {
      _commitTimelines(const <SubtitleItem>[], const <SubtitleItem>[]);
      return;
    }

    String? primaryPath = _nonEmpty(config.primarySubtitlePath);
    String? secondaryPath = config.renderSecondarySubtitle
        ? _nonEmpty(config.secondarySubtitlePath)
        : null;
    if (primaryPath == null && secondaryPath != null) {
      primaryPath = secondaryPath;
      secondaryPath = null;
    }

    try {
      final results =
          await Future.wait<List<SubtitleItem>>(<Future<List<SubtitleItem>>>[
            _subtitleService.loadSubtitle(primaryPath),
            _subtitleService.loadSubtitle(secondaryPath),
          ]);
      if (_disposed || generation != _loadGeneration) return;
      _commitTimelines(results[0], results[1]);
      update(_lastPosition);
    } catch (_) {
      if (_disposed || generation != _loadGeneration) return;
      _commitTimelines(const <SubtitleItem>[], const <SubtitleItem>[]);
      displayNotifier.value = SubtitleDisplayState.empty;
    }
  }

  void update(Duration position) {
    if (_disposed) return;
    _lastPosition = position;
    final config = _config;
    if (config == null || !config.burnSubtitles) {
      _setEntries(const <SubtitleOverlayEntry>[]);
      return;
    }

    final int positionMs = position.inMilliseconds;
    final primaryIndices = _activeIndices(
      _primary,
      _primaryStarts,
      positionMs,
      config.continuousSubtitle,
    );
    final secondaryIndices = _activeIndices(
      _secondary,
      _secondaryStarts,
      positionMs,
      config.continuousSubtitle,
    );
    final secondaryItems = secondaryIndices
        .map((int index) => _secondary[index])
        .toList(growable: false);
    final entries = <SubtitleOverlayEntry>[];

    for (final int index in primaryIndices) {
      final item = _primary[index];
      final bool hasImage = item.imageLoader != null;
      String text = hasImage ? '' : item.text;
      String? secondaryText;
      if (!hasImage && _secondary.isEmpty && config.splitSubtitleByLine) {
        final lines = text.split('\n');
        if (lines.length > 1) {
          text = lines.first;
          secondaryText = lines.skip(1).join('\n');
        }
      } else if (!hasImage && secondaryItems.isNotEmpty) {
        SubtitleItem? closest;
        int closestDelta = 1 << 30;
        for (final candidate in secondaryItems) {
          final delta =
              (candidate.startTime.inMilliseconds -
                      item.startTime.inMilliseconds)
                  .abs();
          if (delta < closestDelta) {
            closest = candidate;
            closestDelta = delta;
          }
        }
        secondaryText = closest?.text;
      }
      entries.add(
        SubtitleOverlayEntry(
          sourcePath: config.primarySubtitlePath,
          secondarySourcePath: SubtitleFontService.instance.secondarySource(
            config.primarySubtitlePath,
            config.secondarySubtitlePath,
          ),
          language: SubtitleFontService.instance.languageForSource(
            config.primarySubtitlePath,
            texts: _primary.take(100).map((s) => s.text),
          ),
          secondaryLanguage: SubtitleFontService.instance.languageForSource(
            config.secondarySubtitlePath,
            texts: _secondary.take(100).map((s) => s.text),
          ),
          index: index,
          text: text,
          secondaryText: secondaryText,
          image: _primaryImages[index],
        ),
      );
      if (hasImage && !_primaryImages.containsKey(index)) {
        _primaryImages[index] = null;
        _loadPrimaryImage(index, item, _loadGeneration);
      }
    }

    if (primaryIndices.isEmpty) {
      for (final int index in secondaryIndices) {
        entries.add(
          SubtitleOverlayEntry(
            text: '',
            secondaryText: _secondary[index].text,
            secondarySourcePath: config.secondarySubtitlePath,
          ),
        );
      }
    }
    _setEntries(entries);
  }

  void clear() {
    _config = null;
    _loadGeneration++;
    _commitTimelines(const <SubtitleItem>[], const <SubtitleItem>[]);
    displayNotifier.value = SubtitleDisplayState.empty;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadGeneration++;
    displayNotifier.dispose();
  }

  void _commitTimelines(
    List<SubtitleItem> primary,
    List<SubtitleItem> secondary,
  ) {
    _primary = List<SubtitleItem>.unmodifiable(primary);
    _secondary = List<SubtitleItem>.unmodifiable(secondary);
    _primaryStarts = List<int>.unmodifiable(
      primary.map((SubtitleItem item) => item.startTime.inMilliseconds),
    );
    _secondaryStarts = List<int>.unmodifiable(
      secondary.map((SubtitleItem item) => item.startTime.inMilliseconds),
    );
  }

  List<int> _activeIndices(
    List<SubtitleItem> items,
    List<int> starts,
    int positionMs,
    bool continuous,
  ) {
    if (items.isEmpty) return const <int>[];
    int low = 0;
    int high = starts.length - 1;
    int candidate = -1;
    while (low <= high) {
      final int middle = (low + high) >> 1;
      if (starts[middle] <= positionMs) {
        candidate = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (candidate < 0) return const <int>[];
    final indices = <int>[];
    for (int index = candidate; index >= 0; index--) {
      final int end = continuous && index + 1 < items.length
          ? starts[index + 1]
          : items[index].endTime.inMilliseconds;
      if (positionMs < end) {
        indices.add(index);
      } else {
        break;
      }
    }
    return indices.reversed.toList(growable: false);
  }

  Future<void> _loadPrimaryImage(
    int index,
    SubtitleItem item,
    int generation,
  ) async {
    Uint8List? image;
    try {
      image = await item.imageLoader?.call();
    } catch (_) {}
    if (_disposed || generation != _loadGeneration) return;
    _primaryImages[index] = image;
    update(_lastPosition);
  }

  void _setEntries(List<SubtitleOverlayEntry> entries) {
    final previous = displayNotifier.value.entries;
    if (_entriesEqual(previous, entries)) return;
    displayNotifier.value = SubtitleDisplayState(
      entries: List<SubtitleOverlayEntry>.unmodifiable(entries),
    );
  }

  bool _entriesEqual(
    List<SubtitleOverlayEntry> left,
    List<SubtitleOverlayEntry> right,
  ) {
    if (left.length != right.length) return false;
    for (int index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.index != b.index ||
          a.text != b.text ||
          a.secondaryText != b.secondaryText ||
          !identical(a.image, b.image)) {
        return false;
      }
    }
    return true;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
