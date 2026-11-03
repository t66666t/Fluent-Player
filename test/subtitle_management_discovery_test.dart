import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_discovery_service.dart';
import 'package:video_player_app/utils/subtitle_file_matcher.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

class _Discovery extends SubtitleDiscoveryService {
  final started = Completer<void>();
  late final result = Completer<List<DiscoveredSubtitleFile>>();
  final paths = <String>[];

  @override
  Future<List<DiscoveredSubtitleFile>> scanVideoDirectory({
    required String videoPath,
    int? videoDurationMs,
  }) {
    paths.add(videoPath);
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

class _Embedded extends EmbeddedSubtitleService {
  final paths = <String>[];
  late final result = Completer<List<EmbeddedSubtitleTrack>>();

  @override
  Future<List<EmbeddedSubtitleTrack>> getEmbeddedSubtitles(String path) {
    paths.add(path);
    return result.future;
  }
}

class _SlowLibrary extends ChangeNotifier implements LibraryService {
  _SlowLibrary(this.root);

  final Directory root;
  late final persisted = Completer<void>();
  bool reconciling = false;

  @override
  Directory? get dataRootDirOrNull => root;

  @override
  VideoItem? getVideo(String id) => null;

  @override
  ManagedSubtitleAsset? managedSubtitleAssetForPath(
    String videoId,
    String path,
  ) => null;

  @override
  Future<void> reconcileManagedSubtitleAssets(
    String videoId,
    Iterable<String> paths,
  ) {
    reconciling = true;
    return persisted.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late File saved;
  late _Discovery discovery;
  late _Embedded embedded;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('subtitle_management_scan_');
    await SettingsService().init();
    SettingsService().largeDataRootPath = root.path;
    saved = await File(
      p.join(root.path, 'saved.srt'),
    ).writeAsString('1\n00:00:00,000 --> 00:00:01,000\n已保存字幕\n');
    discovery = _Discovery();
    embedded = _Embedded();
  });

  tearDown(() async {
    SettingsService().largeDataRootPath = null;
    if (!discovery.result.isCompleted) discovery.result.complete([]);
    if (!embedded.result.isCompleted) embedded.result.complete([]);
    embedded.dispose();
    await root.delete(recursive: true);
  });

  Widget sheet(
    String path, {
    bool probeEmbedded = false,
    String? probePath,
    String? videoId,
  }) {
    return ChangeNotifierProvider<EmbeddedSubtitleService>.value(
      value: embedded,
      child: MaterialApp(
        home: Scaffold(
          body: SubtitleManagementSheet(
            videoPath: path,
            videoId: videoId,
            showEmbeddedSubtitles: probeEmbedded,
            embeddedProbePath: probePath,
            discoveryService: discovery,
            localSubtitles: {'saved.srt': saved.path},
            onSubtitleChanged: () {},
            onOpenAi: () {},
          ),
        ),
      ),
    );
  }

  Future<void> startLocalScan(WidgetTester tester, String path) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(sheet(path, probeEmbedded: true));
      await discovery.started.future.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
  }

  testWidgets(
    'saved rows stay above the footer while scans finish separately',
    (tester) async {
      final videoPath = p.join(root.path, 'Movie.mp4');
      await startLocalScan(tester, videoPath);
      final row = find.text('saved.srt');
      final before = tester.getRect(row);
      final footer = find.byKey(const ValueKey('subtitle-discovery-status'));
      expect(tester.getTopLeft(footer).dy, greaterThan(before.bottom));
      expect(find.textContaining('正在查找本地同文件夹字幕'), findsOneWidget);
      expect(find.textContaining('正在检测内嵌字幕'), findsOneWidget);
      expect(find.textContaining('正在读取已保存字幕'), findsNothing);

      await tester.runAsync(() async {
        discovery.result.complete([]);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(find.textContaining('正在查找本地同文件夹字幕'), findsNothing);
      expect(find.textContaining('正在检测内嵌字幕'), findsOneWidget);
      expect(tester.getRect(row), before);

      await tester.runAsync(() async {
        embedded.result.complete([]);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(footer, findsNothing);
      expect(tester.getRect(row), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cloud and document media skip local scans and retain saved rows',
    (tester) async {
      for (final path in [
        for (final provider in ['uc', 'quark', 'baidu', 'aliyun'])
          'cloud-drive://v1/$provider/account/drive/video',
        'content://media/external/video/1',
        'https://example.test/Movie.mp4',
        'bilibili://stream/BV1xx411c7mD?cid=101',
      ]) {
        await tester.runAsync(() async {
          await tester.pumpWidget(sheet(path, probeEmbedded: true));
          // Wait for actual file metadata IO used by the saved subtitle list.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.text('saved.srt'), findsOneWidget, reason: path);
        expect(
          find.byKey(const ValueKey('subtitle-discovery-status')),
          findsNothing,
        );
        expect(discovery.paths, isEmpty, reason: path);
        expect(embedded.paths, isEmpty, reason: path);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'file URIs probe the native file and a failed sidecar keeps saved rows',
    (tester) async {
      final video = File(p.join(root.path, '视频 Movie.mp4'));
      await startLocalScan(tester, video.uri.toString());
      expect(embedded.paths, [video.path]);
      await tester.runAsync(() async {
        discovery.result.completeError(
          const FileSystemException('Access denied'),
        );
        embedded.result.complete([]);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('saved.srt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-discovery-status')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a late local scan cannot populate a newly selected UC video', (
    tester,
  ) async {
    await startLocalScan(tester, p.join(root.path, 'Movie.mp4'));
    await tester.runAsync(() async {
      await tester.pumpWidget(sheet('cloud-drive://v1/uc/account/drive/video'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.runAsync(() async {
      discovery.result.complete([
        DiscoveredSubtitleFile(
          path: p.join(root.path, 'Movie.zh.srt'),
          modifiedAt: DateTime(2026),
          length: 100,
          analysis: SubtitleFileMatcher.analyzeStems(
            videoStem: 'Movie',
            subtitleStem: 'Movie.zh',
          ),
        ),
      ]);
      embedded.result.complete([]);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('saved.srt'), findsOneWidget);
    expect(find.text('Movie.zh.srt'), findsNothing);
    expect(
      find.byKey(const ValueKey('subtitle-discovery-status')),
      findsNothing,
    );
    expect(discovery.paths, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending library save does not keep UC discovery spinning', (
    tester,
  ) async {
    final library = _SlowLibrary(root);
    await tester.runAsync(() async {
      final tasks = await Directory(
        p.join(root.path, 'subtitles', 'tasks', 'card'),
      ).create(recursive: true);
      await saved.copy(p.join(tasks.path, 'task.srt'));
      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: library,
          child: sheet(
            'cloud-drive://v1/uc/account/drive/video',
            videoId: 'card',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(library.reconciling, isTrue);
    expect(library.persisted.isCompleted, isFalse);
    expect(find.text('task.srt'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subtitle-discovery-status')),
      findsNothing,
    );
    await tester.runAsync(() async {
      library.persisted.complete();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    expect(tester.takeException(), isNull);
  });
}
