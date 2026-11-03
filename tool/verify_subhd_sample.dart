import 'dart:io';

import 'package:video_player_app/features/subtitle_search/subtitle_release_info.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';

Future<void> main() async {
  const expected =
      '3054584fd78c45871f799f4893fa8da26810213ed39ae07ec58b161a3f818071';
  final service = SubtitleSearchService();
  const hit = SubtitleSearchHit(
    source: SubtitleSearchSource.subhd,
    id: 'pQEFik',
    title: 'sample',
    websiteUrl: 'https://subhd.tv/a/pQEFik',
  );
  try {
    final files = await service.files(
      hit,
      const SubtitleSearchQuery(text: 'sample'),
      const SubtitleSearchCredentials(),
    );
    stdout.writeln('declared=${files.single.archiveEntries.length}');
    stdout.writeln('label=${files.single.availabilityLabel}');
    final docs = await service.download(
      hit,
      files.single,
      const SubtitleSearchCredentials(),
    );
    stdout.writeln('documents=${docs.length}');
    final episodes = <String, int>{};
    for (final doc in docs) {
      final info = SubtitleReleaseInfo.parse(doc.name);
      final key = info.special ? 'special' : 'e${info.episode ?? -1}';
      episodes[key] = (episodes[key] ?? 0) + 1;
      if (info.episode == 1 && !info.special) {
        stdout.writeln(
          'ep1 ${doc.name} cues=${doc.cues.length} encoding=${doc.encoding} lang=${doc.languageEvidence}',
        );
      }
    }
    stdout.writeln('groups=$episodes');
  } catch (error, stack) {
    stdout.writeln('FAILED $error');
    stderr.writeln(stack);
  } finally {
    stdout.writeln('expected-sha=$expected');
  }
}
