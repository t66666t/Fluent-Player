class MediaChapter {
  final String title;
  final int startMs;
  final int endMs;
  final String? sourceThumbnailUrl;

  const MediaChapter({
    required this.title,
    required this.startMs,
    required this.endMs,
    this.sourceThumbnailUrl,
  });

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
  Duration get duration => Duration(milliseconds: endMs - startMs);

  bool contains(Duration position, {bool includeEnd = false}) {
    final value = position.inMilliseconds;
    return value >= startMs && (includeEnd ? value <= endMs : value < endMs);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    'startMs': startMs,
    'endMs': endMs,
    if (sourceThumbnailUrl != null) 'sourceThumbnailUrl': sourceThumbnailUrl,
  };

  factory MediaChapter.fromJson(Map<String, dynamic> json) {
    final startMs = _readMilliseconds(
      json,
      millisecondKeys: const <String>['startMs', 'start_ms'],
      secondKeys: const <String>[
        'startTimeSeconds',
        'start_time',
        'start',
        'from',
      ],
    );
    final endMs = _readMilliseconds(
      json,
      millisecondKeys: const <String>['endMs', 'end_ms'],
      secondKeys: const <String>['endTimeSeconds', 'end_time', 'end', 'to'],
    );
    return MediaChapter(
      title: (json['title'] ?? json['content'] ?? '').toString().trim(),
      startMs: startMs,
      endMs: endMs,
      sourceThumbnailUrl:
          _nonEmptyString(json['sourceThumbnailUrl']) ??
          _nonEmptyString(json['imgUrl']) ??
          _nonEmptyString(json['img_url']),
    );
  }

  static List<MediaChapter> normalize(
    Iterable<MediaChapter> chapters, {
    int durationMs = 0,
  }) {
    final sorted = chapters.where((chapter) => chapter.startMs >= 0).toList()
      ..sort((left, right) => left.startMs.compareTo(right.startMs));
    if (sorted.isEmpty) return const <MediaChapter>[];

    final deduped = <MediaChapter>[];
    for (final chapter in sorted) {
      if (deduped.isNotEmpty && deduped.last.startMs == chapter.startMs) {
        if (deduped.last.title.isEmpty && chapter.title.isNotEmpty) {
          deduped[deduped.length - 1] = chapter;
        }
        continue;
      }
      deduped.add(chapter);
    }

    final normalized = <MediaChapter>[];
    for (var index = 0; index < deduped.length; index++) {
      final chapter = deduped[index];
      final nextStart = index + 1 < deduped.length
          ? deduped[index + 1].startMs
          : null;
      var endMs = chapter.endMs;
      if (endMs <= chapter.startMs ||
          (nextStart != null && endMs > nextStart)) {
        endMs = nextStart ?? durationMs;
      }
      if (durationMs > 0 && endMs > durationMs) {
        endMs = durationMs;
      }
      if (endMs <= chapter.startMs) continue;
      normalized.add(
        MediaChapter(
          title: chapter.title.isEmpty ? '章节 ${index + 1}' : chapter.title,
          startMs: chapter.startMs,
          endMs: endMs,
          sourceThumbnailUrl: chapter.sourceThumbnailUrl,
        ),
      );
    }
    return List<MediaChapter>.unmodifiable(normalized);
  }

  static MediaChapter? atPosition(
    List<MediaChapter> chapters,
    Duration position,
  ) {
    if (chapters.isEmpty) return null;
    final positionMs = position.inMilliseconds;
    var low = 0;
    var high = chapters.length - 1;
    var candidate = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (chapters[middle].startMs <= positionMs) {
        candidate = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (candidate < 0) return null;
    final chapter = chapters[candidate];
    final isLast = candidate == chapters.length - 1;
    return chapter.contains(position, includeEnd: isLast) ? chapter : null;
  }
}

int _readMilliseconds(
  Map<String, dynamic> json, {
  required List<String> millisecondKeys,
  required List<String> secondKeys,
}) {
  for (final key in millisecondKeys) {
    final value = _toDouble(json[key]);
    if (value != null) return value.round();
  }
  for (final key in secondKeys) {
    final value = _toDouble(json[key]);
    if (value != null) return (value * 1000).round();
  }
  return 0;
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String? _nonEmptyString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
