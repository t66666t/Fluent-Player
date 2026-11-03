import 'bilibili_download_task.dart';

/// The small, durable part of an online import that still needs the network.
/// Playback identity, title and duration already belong to the saved card.
class BilibiliPendingCardData {
  const BilibiliPendingCardData({
    required this.coverUrl,
    required this.subtitleLanguage,
    required this.preferAiSubtitles,
    this.selectedSubtitle,
  });

  final String coverUrl;
  final String subtitleLanguage;
  final bool preferAiSubtitles;
  final BilibiliSubtitle? selectedSubtitle;

  Map<String, dynamic> toJson() => {
    'coverUrl': coverUrl,
    'subtitleLanguage': subtitleLanguage,
    'preferAiSubtitles': preferAiSubtitles,
    if (selectedSubtitle != null)
      'selectedSubtitle': selectedSubtitle!.toJson(),
  };

  static BilibiliPendingCardData? fromJsonOrNull(Object? value) {
    if (value is! Map) return null;
    final subtitle = value['selectedSubtitle'];
    return BilibiliPendingCardData(
      coverUrl: value['coverUrl']?.toString() ?? '',
      subtitleLanguage: value['subtitleLanguage']?.toString() ?? 'zh',
      preferAiSubtitles: value['preferAiSubtitles'] == true,
      selectedSubtitle: subtitle is Map
          ? BilibiliSubtitle.fromJson(Map<String, dynamic>.from(subtitle))
          : null,
    );
  }
}
