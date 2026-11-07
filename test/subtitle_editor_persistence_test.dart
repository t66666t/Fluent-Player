import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_editor_persistence.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/utils/deferred_subtitle_edits.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/widgets/landscape_subtitle_editor_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_editor_panel.dart';

List<SubtitleItem> _cues(String text, {bool timed = false}) => [
  SubtitleItem(
    index: 1,
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 3),
    text: text,
    timedSpans: timed
        ? [
            SubtitleTimedSpan(
              textStart: 0,
              textEnd: text.length,
              startTime: const Duration(seconds: 1),
              endTime: const Duration(seconds: 3),
            ),
          ]
        : const [],
  ),
];

Widget _editor({
  required bool landscape,
  required String path,
  String? documentId,
  required List<SubtitleItem> subtitles,
  required Future<void> Function(List<SubtitleItem>) onChanged,
}) {
  const groups = {'Group A': 'a.srt', 'Group B': 'b.srt'};
  return MaterialApp(
    home: Scaffold(
      body: landscape
          ? LandscapeSubtitleEditorSidebar(
              key: const ValueKey('editor'),
              groups: groups,
              activeGroupPath: path,
              documentId: documentId,
              subtitles: subtitles,
              currentSubtitleIndex: 0,
              currentPlaybackPosition: Duration.zero,
              onSelectGroupPath: (_) async {},
              onCreateGroup: (_) async {},
              onRenameGroup: (_, _) async {},
              onSubtitlesChanged: onChanged,
              onSeekTo: (_) {},
              onClose: () {},
            )
          : SubtitleEditorPanel(
              key: const ValueKey('editor'),
              groups: groups,
              activeGroupPath: path,
              documentId: documentId,
              subtitles: subtitles,
              currentSubtitleIndex: 0,
              currentPlaybackPosition: Duration.zero,
              onSelectGroupPath: (_) async {},
              onCreateGroup: (_) async {},
              onRenameGroup: (_, _) async {},
              onSubtitlesChanged: onChanged,
              onSeekTo: (_) {},
              onBack: () {},
              isExpanded: false,
              onToggleExpanded: () {},
            ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queued edits remain pending until the last acknowledgement', () async {
    final edits = DeferredSubtitleEdits();
    final aEntered = Completer<void>(), aRelease = Completer<void>();
    final bEntered = Completer<void>(), bRelease = Completer<void>();
    edits.schedule(_cues('A'), (_) async {
      aEntered.complete();
      await aRelease.future;
    });
    final a = edits.flush();
    await aEntered.future;
    edits.schedule(_cues('B'), (_) async {
      bEntered.complete();
      await bRelease.future;
    });
    final b = edits.flush();
    expect(edits.hasPending, isTrue);
    aRelease.complete();
    await a;
    await bEntered.future;
    expect(edits.hasPending, isTrue);
    bRelease.complete();
    await b;
    expect(edits.hasPending, isFalse);
  });

  group('editor lifecycle', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.subtitleEditorAutoFollow = false;
    });
    tearDown(() => SettingsService().resetForTest());

    for (final landscape in [false, true]) {
      testWidgets(
        'failed save stays in the editor and retries the draft, landscape=$landscape',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = landscape
              ? const Size(844, 390)
              : const Size(390, 844);
          addTearDown(tester.view.reset);
          var reject = true;
          final saved = <String>[];
          await tester.pumpWidget(
            _editor(
              landscape: landscape,
              path: 'a.srt',
              subtitles: _cues('original'),
              onChanged: (items) async {
                if (reject) {
                  throw FileSystemException(
                    'private storage diagnostic',
                    'a.srt',
                  );
                }
                saved.add(items.single.text);
              },
            ),
          );
          await tester.pump();
          await tester.enterText(
            find.byType(TextField).first,
            'keep this draft',
          );
          await tester.pump(const Duration(milliseconds: 221));
          await tester.pump();
          expect(tester.takeException(), isA<FileSystemException>());
          expect(
            find.byKey(const ValueKey('subtitle-editor-save-error')),
            findsOneWidget,
          );
          expect(find.text('字幕修改尚未保存，请重试。'), findsOneWidget);
          expect(
            find.textContaining('private storage diagnostic'),
            findsNothing,
          );
          expect(find.byType(AlertDialog), findsNothing);
          reject = false;
          final retry = find.byKey(
            const ValueKey('subtitle-editor-retry-save'),
          );
          await tester.ensureVisible(retry);
          await tester.pumpAndSettle();
          await tester.tap(retry);
          await tester.pumpAndSettle();
          expect(saved, ['keep this draft']);
          expect(
            find.byKey(const ValueKey('subtitle-editor-save-error')),
            findsNothing,
          );
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'keep this draft',
          );
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'adopting an editable copy keeps a pending draft, landscape=$landscape',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = landscape
              ? const Size(960, 720)
              : const Size(420, 860);
          addTearDown(tester.view.reset);
          final saved = <String>[];
          await tester.pumpWidget(
            _editor(
              landscape: landscape,
              path: 'a.srt',
              documentId: 'same document',
              subtitles: _cues('earlier saved text'),
              onChanged: (items) async => saved.add(items.single.text),
            ),
          );
          await tester.pump();
          await tester.enterText(
            find.byType(TextField).first,
            'new pending text',
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pumpWidget(
            _editor(
              landscape: landscape,
              path: 'b.srt',
              documentId: 'same document',
              subtitles: _cues('earlier saved text'),
              onChanged: (items) async => saved.add(items.single.text),
            ),
          );
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'new pending text',
          );
          await tester.pump(const Duration(milliseconds: 221));
          expect(saved, ['new pending text']);
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('last edit survives immediate close, landscape=$landscape', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = landscape
            ? const Size(960, 720)
            : const Size(420, 860);
        addTearDown(tester.view.reset);
        final saved = <List<SubtitleItem>>[];
        await tester.pumpWidget(
          _editor(
            landscape: landscape,
            path: 'a.srt',
            subtitles: _cues('original'),
            onChanged: (items) async => saved.add(items),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField).first, 'last edit');
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          saved,
          isEmpty,
          reason: 'the autosave debounce is still pending',
        );
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump();
        expect(saved, hasLength(1));
        expect(saved.single.single.text, 'last edit');
        await tester.pump(const Duration(seconds: 1));
        expect(
          saved,
          hasLength(1),
          reason: 'closing must not leave a second timer',
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'switching groups flushes the captured A callback, landscape=$landscape',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = landscape
              ? const Size(960, 720)
              : const Size(420, 860);
          addTearDown(tester.view.reset);
          final a = <String>[];
          final b = <String>[];
          await tester.pumpWidget(
            _editor(
              landscape: landscape,
              path: 'a.srt',
              subtitles: _cues('A original'),
              onChanged: (items) async => a.add(items.single.text),
            ),
          );
          await tester.pump();
          await tester.enterText(find.byType(TextField).first, 'A final edit');
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pumpWidget(
            _editor(
              landscape: landscape,
              path: 'b.srt',
              subtitles: _cues('B original'),
              onChanged: (items) async => b.add(items.single.text),
            ),
          );
          await tester.pump();
          expect(a, ['A final edit']);
          expect(
            b,
            isEmpty,
            reason: 'the old pending callback must not target B',
          );
          final field = tester.widget<TextField>(find.byType(TextField).first);
          expect(field.controller!.text, 'B original');
          await tester.enterText(find.byType(TextField).first, 'B edit');
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump();
          expect(a, ['A final edit']);
          expect(b, ['B edit']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('library-owned subtitle persistence', () {
    late Directory root;
    late _SubtitleLibrary library;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('subtitle_editor_persist_');
      library = _SubtitleLibrary(root);
      library.addVideo('video-a');
      library.addVideo('video-b');
    });
    tearDown(() async {
      library._videos.clear();
      await SubtitleEditorPersistence.retryPendingForExit();
      library.dispose();
      await root.delete(recursive: true);
    });

    Future<String> owned(String video, String name, String text) async {
      final path = p.join(root.path, 'managed', video, name);
      await File(path).parent.create(recursive: true);
      await SubtitleEditorPersistence.write(path, _cues(text));
      return path;
    }

    Future<String> external(String name) async {
      final file = File(p.join(root.path, 'external', name));
      await file.parent.create(recursive: true);
      await file.writeAsString('external original must remain unchanged');
      return file.path;
    }

    test(
      'external source stays untouched and queued edits share one managed copy',
      () async {
        final source = await external('original.srt');
        final results = await Future.wait([
          for (final text in ['first', 'second', 'last'])
            SubtitleEditorPersistence.save(
              library: library,
              videoId: 'video-a',
              sourcePath: source,
              subtitles: _cues(text),
            ),
        ]);
        expect(
          await File(source).readAsString(),
          'external original must remain unchanged',
        );
        expect(results.toSet(), hasLength(1));
        expect(library.allocations, ['video-a']);
        expect(library.getVideo('video-a')!.localSubtitles!.values, [
          results.first,
        ]);
        expect(
          library.getVideo('video-a')!.managedSubtitleAssets,
          hasLength(1),
        );
        expect(
          SubtitleParser.parseSrt(
            await File(results.first).readAsString(),
          ).single.text,
          'last',
        );
      },
    );

    test(
      'owned SRT is updated in place and its word timing remains usable',
      () async {
        final path = await owned('video-a', 'asr.srt', 'original');
        final cues = _cues('new timed words', timed: true);
        final output = await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-a',
          sourcePath: path,
          subtitles: cues,
        );
        expect(output, path);
        expect(library.allocations, isEmpty);
        final text = await File(path).readAsString();
        final restored = await SubtitleWordTimingStore.attach(
          path,
          text,
          SubtitleParser.parseSrt(text),
        );
        expect(restored.single.text, cues.single.text);
        expect(restored.single.timedSpans, cues.single.timedSpans);
        expect(library.refreshed, [('video-a', path)]);
        expect(
          await File(SubtitleWordTimingStore.pathFor(path)).exists(),
          isTrue,
        );
      },
    );

    test(
      'the same external source edited for different media creates independent copies',
      () async {
        final source = await external('shared.srt');
        final a = await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-a',
          sourcePath: source,
          subtitles: _cues('A edit'),
        );
        final b = await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-b',
          sourcePath: source,
          subtitles: _cues('B edit'),
        );
        expect(a, isNot(b));
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A edit',
        );
        expect(
          SubtitleParser.parseSrt(await File(b).readAsString()).single.text,
          'B edit',
        );
        expect(library.getVideo('video-a')!.localSubtitles!.values, [a]);
        expect(library.getVideo('video-b')!.localSubtitles!.values, [b]);
      },
    );

    test(
      'captured pending media and snapshot survive switching the active document',
      () async {
        final a = await owned('video-a', 'a.srt', 'A original');
        final b = await owned('video-b', 'b.srt', 'B original');
        var activeVideo = 'video-a';
        var activePath = a;
        final edits = DeferredSubtitleEdits();
        final capturedVideo = activeVideo;
        final capturedPath = activePath;
        final draft = _cues('A pending edit');
        edits.schedule(draft, (items) async {
          await SubtitleEditorPersistence.save(
            library: library,
            videoId: capturedVideo,
            sourcePath: capturedPath,
            subtitles: items,
          );
        });
        activeVideo = 'video-b';
        activePath = b;
        draft[0] = _cues('unrelated new active state').single;
        await edits.flush();
        expect(activeVideo, 'video-b');
        expect(activePath, b);
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A pending edit',
        );
        expect(
          SubtitleParser.parseSrt(await File(b).readAsString()).single.text,
          'B original',
        );
        expect(library.notified, ['video-a']);
      },
    );

    test(
      'a failed disk write keeps old SRT and does not poison later saves',
      () async {
        final path = await owned('video-a', 'a.srt', 'old saved text');
        final oldBytes = await File(path).readAsBytes();
        final blocker = await Directory('$path.editor.next').create();
        await expectLater(
          SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-a',
            sourcePath: path,
            subtitles: _cues('failed edit'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File(path).readAsBytes(), oldBytes);
        await blocker.delete();
        await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-a',
          sourcePath: path,
          subtitles: _cues('latest successful edit'),
        );
        await SubtitleEditorPersistence.retryPending(library);
        expect(
          SubtitleParser.parseSrt(await File(path).readAsString()).single.text,
          'latest successful edit',
        );
        expect(await File('$path.editor.next').exists(), isFalse);
      },
    );

    test(
      'a failed source alias cannot overwrite its newer editable copy',
      () async {
        final source = await external('source.ass');
        library.onRefresh = (_, path) async {
          if ((await File(
            path,
          ).readAsString()).contains('older failed draft')) {
            throw FileSystemException('temporary metadata failure', path);
          }
        };
        await expectLater(
          SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-a',
            sourcePath: source,
            subtitles: _cues('older failed draft'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        final copy = library.getVideo('video-a')!.localSubtitles!.values.single;
        expect(
          SubtitleEditorPersistence.documentKey(library, 'video-a', copy),
          SubtitleEditorPersistence.documentKey(library, 'video-a', source),
        );
        await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-a',
          sourcePath: copy,
          subtitles: _cues('newer successful draft'),
        );
        library.onRefresh = null;
        await SubtitleEditorPersistence.retryPending(library);
        expect(
          SubtitleParser.parseSrt(await File(copy).readAsString()).single.text,
          'newer successful draft',
        );
        expect(library.allocations, hasLength(1));
      },
    );

    test(
      'closed document failure blocks exit until its storage recovers',
      () async {
        final a = await owned('video-a', 'exit-a.srt', 'A original');
        final b = await owned('video-b', 'exit-b.srt', 'B original');
        final blocker = await Directory('$a.editor.next').create();
        await expectLater(
          SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-a',
            sourcePath: a,
            subtitles: _cues('A recovered at exit'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        await SubtitleEditorPersistence.save(
          library: library,
          videoId: 'video-b',
          sourcePath: b,
          subtitles: _cues('B already saved'),
        );
        await expectLater(
          SubtitleEditorPersistence.retryPendingForExit(),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A original',
        );
        await blocker.delete();
        await SubtitleEditorPersistence.retryPendingForExit();
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A recovered at exit',
        );
        expect(
          SubtitleParser.parseSrt(await File(b).readAsString()).single.text,
          'B already saved',
        );
        await SubtitleEditorPersistence.retryPendingForExit();
      },
    );

    test(
      'exit retry does not resurrect an intentionally removed media',
      () async {
        final a = await owned('video-a', 'removed.srt', 'original');
        await Directory('$a.editor.next').create();
        await expectLater(
          SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-a',
            sourcePath: a,
            subtitles: _cues('unsaved edit'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        library._videos.remove('video-a');
        await SubtitleEditorPersistence.retryPendingForExit();
        expect(library.getVideo('video-a'), isNull);
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'original',
        );
      },
    );

    test(
      'A failure survives replacing its editor, B success, and explicit recovery',
      () async {
        final a = await owned('video-a', 'a.srt', 'A original');
        final b = await owned('video-b', 'b.srt', 'B original');
        final blocker = await Directory('$a.editor.next').create();
        var edits = DeferredSubtitleEdits();
        edits.schedule(_cues('A saved after recovery'), (items) async {
          await SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-a',
            sourcePath: a,
            subtitles: items,
          );
        });
        await expectLater(edits.flush(), throwsA(isA<FileSystemException>()));
        // The failed editor can disappear. Its library retains this document.
        edits = DeferredSubtitleEdits();
        edits.schedule(_cues('B success'), (items) async {
          await SubtitleEditorPersistence.save(
            library: library,
            videoId: 'video-b',
            sourcePath: b,
            subtitles: items,
          );
        });
        await edits.flush();
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A original',
        );
        expect(
          SubtitleParser.parseSrt(await File(b).readAsString()).single.text,
          'B success',
        );
        await blocker.delete();
        await SubtitleEditorPersistence.retryPending(library);
        expect(
          SubtitleParser.parseSrt(await File(a).readAsString()).single.text,
          'A saved after recovery',
        );
        expect(
          SubtitleParser.parseSrt(await File(b).readAsString()).single.text,
          'B success',
        );
      },
    );
  });
}

/// Only the library boundary is simulated. Serialization, replacement, timing
/// companions, queues and the editor widgets above use production code.
class _SubtitleLibrary extends ChangeNotifier implements LibraryService {
  _SubtitleLibrary(this.root);
  final Directory root;
  final _videos = <String, VideoItem>{};
  final allocations = <String>[];
  final refreshed = <(String, String)>[];
  final notified = <String?>[];
  Future<void> Function(String, String)? onRefresh;

  void addVideo(String id) {
    _videos[id] = VideoItem(
      id: id,
      path: p.join(root.path, '$id.mp4'),
      title: id,
      durationMs: 60000,
      lastUpdated: 1,
    );
  }

  @override
  VideoItem? getVideo(String id) => _videos[id];

  @override
  Future<bool> subtitleFileBelongsToCard(String videoId, String path) async =>
      p.isWithin(p.join(root.path, 'managed', videoId), path);

  @override
  Future<String> allocateSubtitleFile(
    String videoId,
    String preferredFileName,
  ) async {
    allocations.add(videoId);
    final directory = await Directory(
      p.join(root.path, 'managed', videoId),
    ).create(recursive: true);
    return p.join(directory.path, 'edited-${allocations.length}.srt');
  }

  @override
  ManagedSubtitleAsset? managedSubtitleAssetForPath(
    String videoId,
    String path,
  ) => _videos[videoId]?.managedSubtitleAssets
      .where((asset) => p.equals(asset.path, path))
      .firstOrNull;

  @override
  Future<ManagedSubtitleAsset?> registerManagedSubtitleAsset(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? sourceAssetId,
    String? language,
    String? wordTimingPath,
    bool shareWithBilibiliPart = true,
    bool generatedName = false,
    String? contentHash,
    String? sourceLabel,
    String? entryId,
    int? offsetMs,
    bool machineGenerated = false,
    void Function()? authorize,
  }) async {
    authorize?.call();
    final item = _videos[videoId]!;
    final asset = ManagedSubtitleAsset(
      assetId: '$videoId:${item.managedSubtitleAssets.length}',
      path: path,
      kind: kind,
      displayName: displayName,
      sourceAssetId: sourceAssetId,
      language: language,
      wordTimingPath: wordTimingPath,
      createdAt: 1,
    );
    item.managedSubtitleAssets = [...item.managedSubtitleAssets, asset];
    return asset;
  }

  @override
  Future<void> updateVideoLocalSubtitles(
    String videoId,
    Map<String, String>? subtitles,
  ) async {
    _videos[videoId]!.localSubtitles = Map.of(subtitles ?? {});
  }

  @override
  Future<void> refreshSubtitleWordTimingBinding(
    String videoId,
    String path,
  ) async {
    refreshed.add((videoId, path));
    await onRefresh?.call(videoId, path);
  }

  @override
  void notifySubtitleFilesChanged({String? videoId}) => notified.add(videoId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
