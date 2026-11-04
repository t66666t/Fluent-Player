import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_subtitle_tracks_section.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/subtitle_management_tile.dart';

const _bvid = 'BV1xx411c7mD';
const _path = 'bilibili://stream/$_bvid?cid=101';

void main() {
  late Directory dir;
  late File saved;
  late VideoItem item;
  late List<List<String>> selections;
  late int fetches;
  late BilibiliSubtitleTracks tracks;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('sheet_bili_tracks_');
    await SettingsService().init();
    SettingsService().largeDataRootPath = dir.path;
    saved = File(p.join(dir.path, 'zh.srt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
    item = VideoItem(
      id: 'card',
      path: _path,
      title: '测试',
      durationMs: 1000,
      lastUpdated: 0,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: <String, String>{'中文': saved.path},
      managedSubtitleAssets: <ManagedSubtitleAsset>[
        ManagedSubtitleAsset(
          assetId: '1',
          path: saved.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'zh-CN',
          createdAt: 0,
        ),
      ],
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliStream,
        bvid: _bvid,
        cid: 101,
      ),
    );
    selections = <List<String>>[];
    fetches = 0;
    tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource(
        fetchPublicAnswer: (bvid, cid) async =>
            const BilibiliSubtitleAnswer(needsLogin: true),
        fetchLoggedInAnswer: (bvid, cid) async => const BilibiliSubtitleAnswer(
          tracks: [
            BilibiliSubtitleTrack(
              lan: 'zh-CN',
              label: '中文',
              isAi: false,
              url: 'https://aisubtitle.hdslb.com/zh.json',
            ),
            BilibiliSubtitleTrack(
              lan: 'ai-en',
              label: '英语（自动生成）',
              isAi: true,
              url: 'https://aisubtitle.hdslb.com/ai-en.json',
            ),
          ],
        ),
        isLoggedIn: () async => true,
        fetchContent: (url) async {
          fetches++;
          return <String, Object?>{
            'body': <Object?>[
              <String, Object?>{'from': 0.0, 'to': 1.0, 'content': 'hello'},
            ],
          };
        },
      ),
      store: BilibiliSubtitleTrackStore(
        itemOf: (id) => id == item.id ? item : null,
        noteChanged: (id) async {},
        writeSubtitle: (id, label, contents) async {
          final file = File(p.join(dir.path, 'ai-en.srt'))
            ..writeAsStringSync(contents);
          return file.path;
        },
      ),
    );
  });

  tearDown(() {
    SettingsService().largeDataRootPath = null;
    tracks.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    List<String> selected = const <String>[],
    Size screenSize = const Size(1200, 1600),
    double? managerWidth,
    Map<String, String>? localSubtitles,
  }) async {
    tester.view.physicalSize = screenSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ChangeNotifierProvider<EmbeddedSubtitleService>(
          create: (_) => EmbeddedSubtitleService(),
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: managerWidth ?? screenSize.width,
                  child: SubtitleManagementSheet(
                    videoPath: _path,
                    videoId: item.id,
                    showEmbeddedSubtitles: false,
                    associatedSubtitles: item.downloadAssociatedSubtitles,
                    localSubtitles: localSubtitles,
                    initialSelectedPaths: selected,
                    bilibiliTracks: tracks,
                    onSubtitleChanged: () {},
                    onOpenAi: () {},
                    onSubtitleSelected: (paths) =>
                        selections.add(List<String>.of(paths)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tracks.ensureLoaded(item.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets(
    'render compact management cards on phones',
    (tester) async {
      await tester.runAsync(() async {
        for (final font in {
          'MiSans': 'assets/fonts/MiSans-Regular.otf',
        'monospace': 'assets/fonts/MiSans-Regular.otf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
      final english = File(p.join(dir.path, 'English.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');
      final local = File(p.join(dir.path, '星际穿越.简体中文.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
      addTearDown(tester.view.reset);
      for (final size in [const Size(320, 568), const Size(390, 700)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final capture = GlobalKey();
        await tester.runAsync(() async {
          await tester.pumpWidget(
            ChangeNotifierProvider<EmbeddedSubtitleService>(
              create: (_) => EmbeddedSubtitleService(),
              child: MaterialApp(
                theme: ThemeData(
                  brightness: Brightness.dark,
                  useMaterial3: true,
                  fontFamily: 'MiSans',
                ),
                home: Scaffold(
                  body: RepaintBoundary(
                    key: capture,
                    child: SubtitleManagementSheet(
                      videoPath: 'https://example.test/movie.mp4',
                      showEmbeddedSubtitles: false,
                      associatedSubtitles: {
                        '星际穿越.2014.简英双语.srt': saved.path,
                        'English.srt': english.path,
                      },
                      localSubtitles: {'简体中文字幕': local.path},
                      initialSelectedPaths: [saved.path, english.path],
                      onSubtitleChanged: () {},
                      onOpenAi: () {},
                      onSubtitleSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final title = tester.getRect(find.text('星际穿越.2014.简英双语.srt'));
        final role = tester.getRect(find.text('主'));
        expect(title.center.dy, closeTo(role.center.dy, 2));
        final tile = find.ancestor(
          of: find.text('星际穿越.2014.简英双语.srt'),
          matching: find.byType(SubtitleManagementTile),
        );
        expect(tester.getSize(tile).height, lessThanOrEqualTo(56));
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/subtitle_card_previews/manager-phone-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: !const bool.fromEnvironment('SUBTITLE_CARD_PREVIEWS'),
  );

  for (final (size, managerWidth) in [
    (const Size(320, 568), 320.0),
    (const Size(390, 844), 390.0),
    (const Size(844, 390), 844.0),
    (const Size(1440, 900), 360.0),
  ]) {
    testWidgets(
      'subtitle cards fit a $size screen with $managerWidth manager',
      (tester) async {
        final local = File(p.join(dir.path, 'Movie.2026.bilingual.zh-en.srt'))
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
        await pumpSheet(
          tester,
          screenSize: size,
          managerWidth: managerWidth,
          selected: [saved.path, local.path],
          localSubtitles: {'双语字幕': local.path},
        );
        expect(tester.takeException(), isNull);
        final savedTile = find.ancestor(
          of: find.text('中文'),
          matching: find.byType(SubtitleManagementTile),
        );
        expect(
          tester.widget<SubtitleManagementTile>(savedTile).selected,
          isTrue,
        );
        expect(
          find.descendant(of: savedTile, matching: find.text('主')),
          findsOneWidget,
        );

        final localTile = find.ancestor(
          of: find.text(p.basename(local.path)),
          matching: find.byType(SubtitleManagementTile),
        );
        await tester.scrollUntilVisible(
          localTile,
          100,
          scrollable: find.descendant(
            of: find.byKey(const PageStorageKey('subtitle-manager-files')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(localTile, findsOneWidget);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final buttons = find.descendant(
          of: localTile,
          matching: find.byType(IconButton),
        );
        expect(buttons, findsNWidgets(3));
        final title = tester.getRect(find.text(p.basename(local.path)));
        final bounds = tester.getRect(localTile);
        expect(title.width, greaterThan(90));
        for (final button in buttons.evaluate()) {
          final rect = tester.getRect(find.byWidget(button.widget));
          expect(rect.size, const Size(32, 40));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
          expect(rect.left, greaterThan(title.right));
          expect(rect.center.dy, bounds.center.dy);
        }
        await tester.tap(find.text(p.basename(local.path)));
        await tester.pump();
        expect(selections.last, [saved.path]);
      },
    );
  }

  testWidgets('a Bilibili video lists its tracks once, under「B 站字幕」', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('B 站字幕'), findsOneWidget);
    expect(find.text('媒体库关联字幕'), findsNothing);
    expect(find.text('中文'), findsOneWidget);
    expect(find.text('英语（自动生成）'), findsOneWidget);
    expect(find.byType(BilibiliAiBadge), findsOneWidget);
    expect(find.text('暂无关联字幕文件'), findsNothing);
  });

  testWidgets('pick, switch and turn off like a local subtitle', (
    tester,
  ) async {
    await pumpSheet(tester);
    // Pick the saved CC track.
    await tester.tap(find.text('中文'));
    await tester.pump();
    expect(selections.last, [saved.path]);

    // Pick the AI track: fetched, then selected next to it.
    await tester.runAsync(() async {
      await tester.tap(find.text('英语（自动生成）'));
      for (var i = 0; i < 30 && selections.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(fetches, 1);
    final aiPath = p.join(dir.path, 'ai-en.srt');
    expect(selections.last, [saved.path, aiPath]);

    // Tap again: turned off, one by one.
    await tester.tap(find.text('英语（自动生成）'));
    await tester.pump();
    expect(selections.last, [saved.path]);
    await tester.tap(find.text('中文'));
    await tester.pump();
    expect(selections.last, isEmpty);
  });

  testWidgets('an AI subtitle saved for this card shows in the list', (
    tester,
  ) async {
    final ai = File(p.join(dir.path, 'subtitles', 'tasks', item.id, 'ai.srt'));
    ai.createSync(recursive: true);
    ai.writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n转写\n');
    await pumpSheet(tester);
    expect(find.text('AI 字幕'), findsOneWidget);
  });

  testWidgets(
    'the same Bilibili part shares subtitles, a local file does not',
    (tester) async {
      final library = LibraryService()..resetLibraryForTesting();
      addTearDown(library.resetLibraryForTesting);
      final watch = VideoItem(
        id: 'watch-card',
        path: _path,
        title: '只看',
        durationMs: 1000,
        lastUpdated: 0,
        sourceRef: item.sourceRef,
      );
      final local = VideoItem(
        id: 'local-card',
        path: p.join(dir.path, 'same.mp4'),
        title: '本地',
        durationMs: 1000,
        lastUpdated: 0,
      );
      library
        ..seedVideoForTesting(item)
        ..seedVideoForTesting(watch)
        ..seedVideoForTesting(local);
      final siblingAi = File(
        p.join(dir.path, 'subtitles', 'tasks', watch.id, 'ai.srt'),
      );
      siblingAi.parent.createSync(recursive: true);
      siblingAi.writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n另一张卡\n');
      final shared = File(
        p.join(dir.path, 'subtitles', 'bilibili', '${_bvid}_101', 'extra.srt'),
      );
      shared.parent.createSync(recursive: true);
      shared.writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n共享\n');
      final privateFile = File(
        p.join(dir.path, 'subtitles', 'tasks', local.id, 'private.srt'),
      );
      privateFile.parent.createSync(recursive: true);
      privateFile.writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n私有\n');

      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<EmbeddedSubtitleService>(
                create: (_) => EmbeddedSubtitleService(),
              ),
              ChangeNotifierProvider<LibraryService>.value(value: library),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SubtitleManagementSheet(
                  videoPath: _path,
                  videoId: item.id,
                  showEmbeddedSubtitles: false,
                  associatedSubtitles: item.downloadAssociatedSubtitles,
                  bilibiliTracks: tracks,
                  onSubtitleChanged: () {},
                  onOpenAi: () {},
                  onSubtitleSelected: (_) {},
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(find.text('AI 字幕'), findsOneWidget);
      expect(find.text('extra.srt'), findsOneWidget);
      expect(find.text(p.basename(privateFile.path)), findsNothing);
      expect(siblingAi.existsSync(), isTrue);
    },
  );

  testWidgets('a fetched track that is already selected stays selected', (
    tester,
  ) async {
    await pumpSheet(tester, selected: <String>[saved.path]);
    final state = tester.state(find.byType(BilibiliSubtitleTracksSection));
    final section = state.widget as BilibiliSubtitleTracksSection;
    section.onPick(saved.path);
    await tester.pump();
    expect(selections, isEmpty);
  });
}
