import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_batch_matcher.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_workspace.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/subtitle_batch_import_dialog.dart';

import 'subtitle_search_service_test.dart' show MemorySubtitleSecrets;
import 'subtitle_search_workspace_test.dart' show FixtureSubtitleSearchService;
import 'subtitle_batch_matcher_test.dart' show candidate;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<SubtitleSearchWorkspace> setup() async {
    final w = SubtitleSearchWorkspace(
      service: FixtureSubtitleSearchService(),
      secrets: MemorySubtitleSecrets(),
    );
    await w.initialize();
    return w;
  }

  List<SubtitleBatchCandidate> candidates() => [
    for (var i = 1; i <= 3; i++)
      candidate(
        'Frieren - 0$i.srt',
        document: SubtitleSearchDocument(
          name: 'Frieren - 0$i.srt',
          content: 'fixture',
          cues: [
            SubtitleItem(
              index: 1,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 2),
              text: '字幕',
            ),
          ],
        ),
      ),
  ];
  const targets = [
    SubtitleBatchTarget(id: '1', title: 'Frieren - 01', path: '1.mkv'),
    SubtitleBatchTarget(
      id: '2',
      title: 'Frieren - 02',
      path: '2.mkv',
      hasSubtitle: true,
    ),
    SubtitleBatchTarget(id: '3', title: 'Frieren - 03', path: '3.mkv'),
  ];
  testWidgets(
    'batch fits small, landscape and enlarged screens and preserves existing subtitles by default',
    (tester) async {
      addTearDown(tester.view.reset);
      final w = await setup();
      final session = w.acquire('one', 'Frieren - 01');
      await session.restored;
      for (final (size, scale) in [
        (const Size(320, 568), 1.0),
        (const Size(667, 280), 1.0),
        (const Size(248, 440), 1.4),
        (const Size(360, 640), 2.0),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            ),
            home: SubtitleBatchImportDialog(
              targets: targets,
              candidates: candidates(),
              session: session,
              anchorTitle: 'Frieren - 01',
              preferredName: 'Frieren - 01.srt',
              onImport: (_, _, _) async => '/saved.srt',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('导入选中的 2 集'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size $scale');
      }
      await tester.pumpWidget(const SizedBox());
      w.dispose();
    },
  );
  testWidgets(
    'one failed episode does not discard successful imports and only failed rows remain selected',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      final w = await setup();
      final session = w.acquire('one', 'Frieren - 01');
      await session.restored;
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: SubtitleBatchImportDialog(
            targets: targets,
            candidates: candidates(),
            session: session,
            anchorTitle: 'Frieren - 01',
            preferredName: 'Frieren - 01.srt',
            onImport: (id, _, _) async {
              calls.add(id);
              if (id == '3') throw StateError('文件暂时不可写');
              return '/$id.srt';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('subtitle-batch-apply')));
      await tester.pumpAndSettle();
      expect(calls, ['1', '3']);
      expect(find.textContaining('成功 1 集'), findsOneWidget);
      expect(find.text('导入选中的 1 集'), findsOneWidget);
      expect(
        (w.service as FixtureSubtitleSearchService).downloads,
        0,
        reason: 'pack preview documents are reused',
      );
      await tester.pumpWidget(const SizedBox());
      w.dispose();
    },
  );

  testWidgets(
    'supplemental lookup advances beyond failed episodes in the first forty',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      final w = await setup();
      final service = w.service as FixtureSubtitleSearchService;
      service.failXunlei = true;
      final session = w.acquire('one', 'Frieren - 01');
      await session.restored;
      session.completedQuery = const SubtitleSearchQuery(text: 'Frieren');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: SubtitleBatchImportDialog(
            targets: [
              for (var i = 1; i <= 42; i++)
                SubtitleBatchTarget(
                  id: '$i',
                  title: 'Frieren - ${i.toString().padLeft(2, '0')}',
                  path: '$i.mkv',
                ),
            ],
            candidates: const [],
            session: session,
            anchorTitle: 'Frieren - 01',
            preferredName: '',
            onImport: (_, _, _) async => '/saved.srt',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('按集补搜缺失字幕'));
      for (var i = 0; i < 42; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(service.searches, 40);
      await tester.tap(find.text('按集补搜缺失字幕'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(service.searches, 42);
      await tester.pumpWidget(const SizedBox());
      w.dispose();
    },
  );
}
