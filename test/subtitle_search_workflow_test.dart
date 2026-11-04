import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_workspace.dart';
import 'subtitle_search_service_test.dart' show MemorySubtitleSecrets;
import 'subtitle_search_workspace_test.dart' show FixtureSubtitleSearchService;

class _DelayedWorks extends FixtureSubtitleSearchService {
  final pending = <String, Completer<List<SubtitleSearchWork>>>{};
  @override
  Future<List<SubtitleSearchWork>> findWorks(
    String text, {
    CancelToken? cancelToken,
  }) => (pending[text] ??= Completer<List<SubtitleSearchWork>>()).future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  SubtitleSearchWorkspace workspace(FixtureSubtitleSearchService service) {
    final w = SubtitleSearchWorkspace(
      service: service,
      secrets: MemorySubtitleSecrets(),
    );
    addTearDown(w.dispose);
    return w;
  }

  const second = SubtitleSearchWork(
    id: '3586996',
    title: '绝命毒师 第二季',
    originalTitle: 'Breaking Bad',
    year: '2009',
    type: 'TVSeries',
  );

  test(
    'selected work, filters and cached results survive leaving and returning',
    () async {
      final service = FixtureSubtitleSearchService()..works = [second];
      final w = workspace(service);
      final s = w.acquire('video', '绝命毒师', filename: 'Breaking.Bad.S02E03.mkv');
      await s.restored;
      expect((s.season, s.episode), ('2', '3'));
      await s.lookupWorks();
      await s.chooseWork(s.works.single);
      expect(
        service.requests.every(
          (q) => q.work?.id == second.id && q.season == 2 && q.episode == 3,
        ),
        isTrue,
      );
      s.packsOnly = true;
      await w.saveDraft(s);
      w.release(s);
      final reopened = w.acquire('video', 'renamed');
      expect(reopened.work?.id, second.id);
      expect(reopened.packsOnly, isTrue);
      await reopened.search();
      expect(service.searches, 3);
      final fresh = workspace(FixtureSubtitleSearchService());
      final restored = fresh.acquire('video', 'renamed');
      await restored.restored;
      expect(restored.work?.id, second.id);
      expect(restored.episode, '3');
    },
  );

  test(
    'late work suggestions cannot replace a newer filename or chosen work',
    () async {
      final service = _DelayedWorks();
      final s = workspace(service).acquire('video', 'Old');
      await s.restored;
      final old = s.lookupWorks();
      s.updateText('New');
      final newer = s.lookupWorks();
      service.pending['New']!.complete([second]);
      await newer;
      service.pending['Old']!.complete([]);
      await old;
      expect(s.works.single.id, second.id);
      await s.chooseWork(second);
      s.updateText('Another');
      expect(s.work, isNull);
      expect(s.works, isEmpty);
    },
  );
}
