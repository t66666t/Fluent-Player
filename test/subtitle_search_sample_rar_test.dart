import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_release_info.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';

void main() {
  test(
    'SubHD pQEFik RAR5 sample enumerates both editions',
    () async {
    final dio = Dio();
    final service = SubtitleSearchService(dio: dio);
    const hit = SubtitleSearchHit(
      source: SubtitleSearchSource.subhd,
      id: 'pQEFik',
      title: 'sample',
      websiteUrl: 'https://subhd.tv/a/pQEFik',
    );
    final files = await service.files(
      hit,
      const SubtitleSearchQuery(text: 'sample'),
      const SubtitleSearchCredentials(),
    );
    expect(files.single.name, isNot(endsWith('.zip')));
    expect(files.single.availabilityLabel, contains('尚未验证'));
    final docs = await service.download(
      hit,
      files.single,
      const SubtitleSearchCredentials(),
    );
    expect(docs.length, greaterThan(1));
    final episodes = <int, int>{};
    var specials = 0;
    for (final doc in docs) {
      final info = SubtitleReleaseInfo.parse(doc.name);
      if (info.special || info.episode == null) {
        specials++;
      } else {
        episodes[info.episode!] = (episodes[info.episode!] ?? 0) + 1;
      }
      expect(doc.cues, isNotEmpty);
    }
    expect(episodes.keys.toList()..sort(), List.generate(23, (i) => i + 1));
    expect(episodes.values.every((count) => count == 2), isTrue);
    expect(specials, greaterThan(0));
    final first = docs.where((doc) {
      final info = SubtitleReleaseInfo.parse(doc.name);
      return info.episode == 1 && !info.special;
    });
    expect(first.length, 2);
    expect(first.every((doc) => doc.cues.length == 714), isTrue);
  },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: Platform.environment['SUBTITLE_SEARCH_LIVE'] == '1'
        ? false
        : '需要联网访问 SubHD。2026-10-17 已在本机直接运行并通过。',
  );
}
