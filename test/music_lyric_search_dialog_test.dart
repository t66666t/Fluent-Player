import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:video_player_app/features/lyrics/lyric_search_importer.dart';
import 'package:video_player_app/features/lyrics/lyric_media_metadata.dart';
import 'package:video_player_app/features/lyrics/lyric_search_models.dart';
import 'package:video_player_app/features/lyrics/lyric_search_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/timed_subtitle_parser.dart';
import 'package:video_player_app/widgets/music_lyric_search_dialog.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

void main() {
  final item = VideoItem(
    id: 'song',
    path: 'Artist - Song [FLAC].mp3',
    title: 'Artist - Song [FLAC].mp3',
    durationMs: 20000,
    lastUpdated: 0,
  );

  Future<void> open(
    WidgetTester tester,
    _Service service, {
    Future<bool> Function(LyricImportRequest)? onImport,
    GlobalKey? capture,
    Future<LyricMediaMetadata>? metadata,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          builder: (context, child) => AppTextInputFocus(child: child!),
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MusicLyricSearchDialog(
                    item: item,
                    service: service,
                    metadata: metadata,
                    mediaDuration: const Duration(seconds: 20),
                    onImport: onImport ?? (_) async => true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'prefills filename, previews real sync level and imports optional translation and offset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _Service();
      LyricImportRequest? imported;
      await open(
        tester,
        service,
        onImport: (request) async {
          imported = request;
          return true;
        },
      );
      expect(service.queries, ['Artist - Song']);
      expect(find.text('逐字时间轴'), findsOneWidget);
      expect(find.text('有中文翻译'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyric-result-netease:42')));
      await tester.pumpAndSettle();
      expect(find.text('逐字时间轴'), findsOneWidget);
      expect(find.text('有中文翻译'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-offset')),
        '-250',
      );
      await tester.tap(find.byKey(const ValueKey('lyric-search-import')));
      await tester.pumpAndSettle();
      expect(imported?.includeTranslation, isFalse);
      expect(imported?.offset, const Duration(milliseconds: -250));
      expect(find.byType(MusicLyricSearchDialog), findsNothing);
    },
  );

  testWidgets('selected filename text starts a new search', (tester) async {
    final service = _Service();
    await open(tester, service);
    await tester.tap(
      find.byKey(const ValueKey('lyric-search-filename-options')),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('lyric-search-filename')),
    );
    field.controller!.selection = const TextSelection(
      baseOffset: 9,
      extentOffset: 13,
    );
    await tester.pump();
    await tester.ensureVisible(find.text('搜索选中的文字'));
    await tester.tap(find.text('搜索选中的文字'));
    await tester.pumpAndSettle();
    expect(service.queries.last, 'Song');
  });

  testWidgets(
    'media tags populate editable author and title, with title-only search available',
    (tester) async {
      final service = _Service();
      await open(
        tester,
        service,
        metadata: Future.value(
          const LyricMediaMetadata(
            title: 'Tagged Song',
            artist: 'Tagged Artist',
          ),
        ),
      );
      expect(service.queries.single, 'Tagged Song');
      expect(service.artists.single, 'Tagged Artist');
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-artist')),
        'Corrected Artist',
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(service.artists.last, 'Corrected Artist');
      await tester.tap(find.byKey(const ValueKey('lyric-search-use-artist')));
      await tester.pumpAndSettle();
      expect(service.artists.last, '');
      expect(find.text('仅搜歌名'), findsOneWidget);
    },
  );

  testWidgets(
    'late metadata cannot replace manually entered search text or author',
    (tester) async {
      final pending = Completer<LyricMediaMetadata>();
      final service = _Service();
      // Opening uses a bounded pump because metadata discovery is still pending.
      await tester.pumpWidget(
        MaterialApp(
          home: MusicLyricSearchDialog(
            item: item,
            service: service,
            metadata: pending.future,
            onImport: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-query')),
        'My query',
      );
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-artist')),
        'My artist',
      );
      pending.complete(
        const LyricMediaMetadata(title: 'Old tag', artist: 'Old artist'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('lyric-search-query')))
            .controller!
            .text,
        'My query',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('lyric-search-artist')),
            )
            .controller!
            .text,
        'My artist',
      );
      expect(service.queries, isEmpty);
    },
  );

  testWidgets('line lyrics without Chinese are labeled before preview', (
    tester,
  ) async {
    final service = _Service()
      ..wordTimed = false
      ..chinese = false;
    await open(tester, service);
    expect(find.text('逐句时间轴'), findsOneWidget);
    expect(find.text('无中文翻译'), findsOneWidget);
    expect(service.fetches, 1);
  });

  testWidgets('all platforms preload once and source changes only filter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _Service()
      ..tracks = [
        _Service.track,
        for (final source in [LyricSource.qqMusic, LyricSource.lrclib])
          LyricSearchTrack(source: source, id: '42', title: source.label),
      ];
    await open(tester, service);
    expect(service.requestedSources.single, LyricSource.values.toSet());
    expect(service.fetches, 3);
    for (final source in [...LyricSource.values, null]) {
      tester
          .widget<CapsuleDropdownButton<LyricSource?>>(
            find.byKey(const ValueKey('lyric-search-source')),
          )
          .onChanged!(source);
      await tester.pumpAndSettle();
      expect(service.queries, hasLength(1));
      expect(service.fetches, 3);
      expect(
        find.byKey(ValueKey('lyric-result-${source?.name ?? 'netease'}:42')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('lyric-result-netease:42')));
    await tester.pumpAndSettle();
    expect(find.text('歌词预览'), findsOneWidget);
    expect(service.fetches, 3);
  });

  testWidgets('only verified lyrics appear and failures leave no dead rows', (
    tester,
  ) async {
    final service = _Service()
      ..tracks = const [
        _Service.track,
        LyricSearchTrack(
          source: LyricSource.netease,
          id: 'no-lyrics',
          title: 'Instrumental',
        ),
        LyricSearchTrack(
          source: LyricSource.netease,
          id: 'failed',
          title: 'Unavailable',
        ),
      ]
      ..unavailable.add('no-lyrics')
      ..failures.add('failed');
    await open(tester, service);
    expect(
      find.byKey(const ValueKey('lyric-result-netease:42')),
      findsOneWidget,
    );
    expect(find.text('Instrumental'), findsNothing);
    expect(find.text('Unavailable'), findsNothing);
    expect(find.text('歌词详情暂时无法确认'), findsNothing);
    expect(find.textContaining('已过滤 1 首无同步歌词'), findsOneWidget);
    expect(find.textContaining('1 首获取失败'), findsOneWidget);
  });

  testWidgets(
    'QQ songs appear individually with four bounded workers and cached preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _Service()
        ..tracks = [
          for (var i = 0; i < 5; i++)
            LyricSearchTrack(
              source: LyricSource.qqMusic,
              id: '$i',
              title: 'Version $i',
            ),
        ];
      for (final track in service.tracks!) {
        service.pendingLyrics[track.id] = Completer<void>();
      }
      await tester.pumpWidget(
        MaterialApp(
          home: MusicLyricSearchDialog(
            item: item,
            service: service,
            onImport: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      expect(service.activeFetches, 4);
      expect(service.pendingLyrics['4']!.isCompleted, isFalse);
      final previous = debugOnRebuildDirtyWidget;
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is MusicLyricSearchDialog) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var i = 0; i < 4; i++) {
        service.pendingLyrics['$i']!.complete();
        await tester.pump();
        expect(find.byKey(ValueKey('lyric-result-qqMusic:$i')), findsOneWidget);
      }
      expect(builds, 0);
      expect(service.maxActiveFetches, 4);
      expect(find.text('QQ 音乐 正在获取歌词 4/5'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyric-result-qqMusic:0')));
      await tester.pump();
      expect(find.text('歌词预览'), findsOneWidget);
      expect(service.fetches, 5);
      service.pendingLyrics['4']!.complete();
      await tester.pumpAndSettle();
      expect(find.text('歌词预览'), findsOneWidget);
      expect(builds, lessThanOrEqualTo(2));
      debugOnRebuildDirtyWidget = previous;
    },
  );

  testWidgets(
    'new keyword matches join the queue without fetching duplicates',
    (tester) async {
      const extra = LyricSearchTrack(
        source: LyricSource.netease,
        id: 'extra',
        title: 'Extra version',
      );
      final service = _Service()
        ..searchPending = true
        ..moreResults = Completer<LyricSearchResults>();
      await tester.pumpWidget(
        MaterialApp(
          home: MusicLyricSearchDialog(
            item: item,
            service: service,
            onImport: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('lyric-result-netease:42')),
        findsOneWidget,
      );
      expect(find.text('网易云音乐 正在搜索'), findsOneWidget);
      expect(service.fetches, 1);
      service.moreResults!.complete(
        const LyricSearchResults(
          [_Service.track, extra],
          statuses: {
            LyricSource.netease: LyricSourceStatus(
              source: LyricSource.netease,
              phase: LyricSourcePhase.ready,
            ),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Extra version'), findsOneWidget);
      expect(service.fetches, 2);
      expect(find.text('网易云音乐 2 首'), findsOneWidget);
    },
  );

  testWidgets(
    'supplemental matches use idle workers while an earlier song waits',
    (tester) async {
      const extra = LyricSearchTrack(
        source: LyricSource.netease,
        id: 'extra',
        title: 'Fast extra version',
      );
      final slowLyrics = Completer<void>();
      final service = _Service()
        ..searchPending = true
        ..moreResults = Completer<LyricSearchResults>()
        ..pendingLyrics['42'] = slowLyrics;
      await tester.pumpWidget(
        MaterialApp(
          home: MusicLyricSearchDialog(
            item: item,
            service: service,
            onImport: (_) async => true,
          ),
        ),
      );
      await tester.pump();
      expect(service.activeFetches, 1);
      service.moreResults!.complete(
        const LyricSearchResults([_Service.track, extra]),
      );
      await tester.pump();
      expect(find.text('Fast extra version'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lyric-result-netease:42')),
        findsNothing,
      );
      expect(service.fetches, 2);
      expect(service.maxActiveFetches, 2);
      slowLyrics.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lyric-result-netease:42')),
        findsOneWidget,
      );
      expect(find.text('网易云音乐 2 首'), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard motion keeps search widgets and cached results intact',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        return tester.binding.setSurfaceSize(null);
      });
      final service = _Service();
      await open(tester, service);
      final query = find.byKey(const ValueKey('lyric-search-query'));
      final originalField = tester.widget<TextField>(query);
      final previous = debugOnRebuildDirtyWidget;
      var builds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is MusicLyricSearchDialog) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (final inset in [0, 60, 120, 180, 240, 300, 240, 180, 120, 60, 0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset.toDouble());
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<TextField>(query), same(originalField));
        expect(tester.takeException(), isNull);
      }
      expect(builds, 0);
      expect(service.queries, hasLength(1));
      expect(service.fetches, 1);
      debugOnRebuildDirtyWidget = previous;
    },
  );

  testWidgets(
    'returned results stay openable while another source is still retrying',
    (tester) async {
      final service = _Service()..hold = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MusicLyricSearchDialog(
                    item: item,
                    service: service,
                    mediaDuration: const Duration(seconds: 20),
                    onImport: (_) async => true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('QQ 音乐 正在重试 2/3'), findsOneWidget);
      expect(find.text('逐字时间轴'), findsOneWidget);
      expect(find.text('有中文翻译'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyric-result-netease:42')));
      await tester.pump();
      expect(find.text('歌词预览'), findsOneWidget);
      expect(service.fetches, 1);
      service.hold!.complete();
      await tester.pump();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('an older search cannot overwrite a newer query', (tester) async {
    final service = _Service();
    await open(tester, service);
    service.delayed = Completer<LyricSearchResults>();
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-query')),
      'Old',
    );
    await tester.tap(find.text('搜索'));
    await tester.pump();
    final old = service.delayed!;
    service.delayed = null;
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-query')),
      'New',
    );
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    old.complete(
      const LyricSearchResults([
        LyricSearchTrack(
          source: LyricSource.lrclib,
          id: 'old',
          title: 'Stale result',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(
      find.byKey(const ValueKey('lyric-result-netease:42')),
      findsOneWidget,
    );
  });

  testWidgets('late lyric details cannot enter a newer search', (tester) async {
    final oldLyrics = Completer<void>();
    final service = _Service()..pendingLyrics['42'] = oldLyrics;
    await tester.pumpWidget(
      MaterialApp(
        home: MusicLyricSearchDialog(
          item: item,
          service: service,
          onImport: (_) async => true,
        ),
      ),
    );
    await tester.pump();
    expect(service.fetches, 1);
    service.tracks = const [
      LyricSearchTrack(
        source: LyricSource.netease,
        id: 'new',
        title: 'New recording',
      ),
    ];
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-query')),
      'New',
    );
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    oldLyrics.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyric-result-netease:42')), findsNothing);
    expect(find.text('New recording'), findsOneWidget);
    expect(service.queries, hasLength(2));
  });

  testWidgets(
    'search and preview fit phone landscape, portrait, desktop and keyboard',
    (tester) async {
      const captureUi = bool.fromEnvironment('CAPTURE_MUSIC_UI');
      if (captureUi) {
        for (final font in {
          'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
          'Inter': 'assets/fonts/Inter-Regular.otf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/cupertino_icons/CupertinoIcons':
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
        }.entries) {
          await tester.runAsync(
            () => (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load(),
          );
        }
      }
      final capture = GlobalKey();
      Future<void> screenshot(Size size, String phase) async {
        if (!captureUi) return;
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/lyric-search/$phase-${size.width.toInt()}x${size.height.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final size in [
        const Size(480, 320),
        const Size(844, 390),
        const Size(390, 844),
        const Size(1440, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await open(tester, _Service(), capture: capture);
        expect(tester.takeException(), isNull, reason: 'search $size');
        await screenshot(size, 'search');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('lyric-result-netease:42')),
          160,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('lyric-result-netease:42')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'preview $size');
        expect(
          find.byKey(const ValueKey('lyric-search-import')).hitTestable(),
          findsOneWidget,
        );
        await screenshot(size, 'preview');
        if (size.width == 390) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'keyboard');
          tester.view.resetViewInsets();
        }
        await tester.tap(
          find.byKey(const ValueKey('music-lyric-search-close')),
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
}

class _Service extends LyricSearchService {
  _Service() : super(dio: Dio());
  final queries = <String>[];
  final artists = <String>[];
  final requestedSources = <Set<LyricSource>>[];
  List<LyricSearchTrack>? tracks;
  final unavailable = <String>{};
  final failures = <String>{};
  final pendingLyrics = <String, Completer<void>>{};
  int activeFetches = 0;
  int maxActiveFetches = 0;
  Completer<LyricSearchResults>? delayed;
  Completer<LyricSearchResults>? moreResults;
  bool searchPending = false;
  Completer<void>? hold;
  bool wordTimed = true;
  bool chinese = true;
  int fetches = 0;
  static const track = LyricSearchTrack(
    source: LyricSource.netease,
    id: '42',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(seconds: 20),
  );
  @override
  Future<LyricSearchResults> search(
    String query, {
    Set<LyricSource> sources = const {},
    Duration mediaDuration = Duration.zero,
    String artist = '',
    CancelToken? cancelToken,
    void Function(LyricSearchResults snapshot)? onUpdate,
  }) async {
    queries.add(query);
    artists.add(artist);
    requestedSources.add(sources);
    if (delayed != null) {
      final results = await delayed!.future;
      onUpdate?.call(results);
      return results;
    }
    final partial = LyricSearchResults(
      tracks ?? const [track],
      statuses: {
        for (final source
            in (tracks ?? const [track]).map((t) => t.source).toSet())
          source: LyricSourceStatus(
            source: source,
            phase: searchPending
                ? LyricSourcePhase.pending
                : LyricSourcePhase.ready,
            trackCount: (tracks ?? const [track])
                .where((t) => t.source == source)
                .length,
          ),
        if (hold != null)
          LyricSource.qqMusic: const LyricSourceStatus(
            source: LyricSource.qqMusic,
            phase: LyricSourcePhase.retrying,
            attempt: 2,
          ),
      },
    );
    onUpdate?.call(partial);
    if (moreResults != null) {
      final results = await moreResults!.future;
      onUpdate?.call(results);
      return results;
    }
    if (hold != null) await hold!.future;
    final finished = LyricSearchResults(
      tracks ?? const [track],
      statuses: {
        for (final source
            in (tracks ?? const [track]).map((t) => t.source).toSet())
          source: LyricSourceStatus(
            source: source,
            phase: LyricSourcePhase.ready,
          ),
        if (hold != null)
          LyricSource.qqMusic: const LyricSourceStatus(
            source: LyricSource.qqMusic,
            phase: LyricSourcePhase.ready,
          ),
      },
    );
    onUpdate?.call(finished);
    return finished;
  }

  @override
  Future<DownloadedLyrics> fetch(
    LyricSearchTrack track, {
    CancelToken? cancelToken,
  }) async {
    fetches++;
    activeFetches++;
    if (activeFetches > maxActiveFetches) maxActiveFetches = activeFetches;
    try {
      final pending = pendingLyrics[track.id];
      if (pending != null) await pending.future;
    } finally {
      activeFetches--;
    }
    if (unavailable.contains(track.id)) throw const LyricUnavailableException();
    if (failures.contains(track.id)) throw StateError('Network unavailable');
    return DownloadedLyrics(
      track: track,
      original: wordTimed
          ? TimedSubtitleParser.parsePlatform(
              '[1000,2000](1000,500,0)Hello (1500,1500,0)world\n[5000,2000](5000,1000,0)Sing (6000,1000,0)along',
            )
          : TimedSubtitleParser.parseLrc(
              '[00:01.00]First\n[00:05.00]Second',
              mediaDuration: const Duration(seconds: 8),
            ),
      translation: chinese
          ? TimedSubtitleParser.parseLrc(
              '[00:01]你好世界\n[00:05]一起歌唱',
              mediaDuration: const Duration(seconds: 8),
            )
          : const [],
    );
  }
}
