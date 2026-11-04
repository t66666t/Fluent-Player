import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/music_lyric_workspace_layout.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';
import 'package:video_player_app/widgets/music_lyric_selection_pane.dart';

SubtitleItem _cue(int index, String text, String translation) {
  return SubtitleItem(
    index: index,
    startTime: Duration(seconds: index * 4),
    endTime: Duration(seconds: index * 4 + 3),
    text: text,
    lyricTranslation: translation,
  );
}

List<SubtitleItem> get _lyrics => [
  _cue(0, 'Hello', '你好'),
  _cue(1, 'Stay with me', '留在我身边'),
  _cue(2, 'Morning', '清晨'),
];

Future<MusicLyricSelectionController> _openPane(
  WidgetTester tester, {
  Size size = const Size(800, 600),
  MusicLyricTrackDisplayMode mode = MusicLyricTrackDisplayMode.both,
  TargetPlatform platform = TargetPlatform.windows,
  List<SubtitleItem>? lyrics,
  double textScale = 1,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.binding.setSurfaceSize(size);
  final controller = MusicLyricSelectionController();
  controller.begin(
    mediaId: 'song',
    primary: lyrics ?? _lyrics,
    secondary: const [],
    splitSubtitleByLine: false,
    mode: mode,
    groupId: 'p:1',
    time: const Duration(seconds: 4),
    awaitingPointer: false,
  );
  final display = resolveMusicLyricEffectiveDisplay(
    preference: mode,
    availability: const MusicLyricTrackAvailability(
      hasPrimaryText: true,
      hasSecondaryText: true,
      imageOnly: false,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: RepaintBoundary(
            child: MusicLyricSelectionPane(
              controller: controller,
              display: display,
              onModeChanged: controller.switchMode,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return controller;
}

Offset _pointAt(WidgetTester tester, int offset) {
  final render = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final box = render
      .getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      )
      .first;
  return render.localToGlobal(box.toRect().center);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform long press selects text inside the document',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = await _openPane(
          tester,
          size: const Size(390, 844),
          platform: platform,
        );
        final editable = tester.widget<EditableText>(find.byType(EditableText));
        expect(editable.style.fontSize, 16);
        expect(editable.style.fontWeight, FontWeight.w400);
        expect(editable.readOnly, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.longPressAt(_pointAt(tester, 1));
        await tester.pump();
        expect(controller.document.textFor(controller.selection), 'Hello');
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
        if (platform == TargetPlatform.android) {
          await tester.pump(const Duration(milliseconds: 200));
          final render = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final before = controller.selection;
          final endpoint = render.getEndpointsForSelection(before).last.point;
          final handle = render.localToGlobal(endpoint) + const Offset(8, 8);
          final gesture = await tester.startGesture(handle);
          await gesture.moveBy(const Offset(0, 30));
          controller.syncPlaybackHighlight(const Duration(seconds: 9));
          await tester.pump();
          await gesture.moveBy(const Offset(0, 100));
          await gesture.up();
          await tester.pump();
          expect(controller.selection.start, before.start);
          expect(controller.selection.end, greaterThan(before.end));
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'sentence taps select a range in either direction and copy visible text',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _openPane(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('music-lyric-selection-sentence')),
      );
      await tester.pump();
      final groups = controller.document.groups;
      for (final pair in [
        [0, 2],
        [2, 0],
      ]) {
        await tester.tapAt(_pointAt(tester, groups[pair.first].documentStart));
        await tester.pump();
        expect(
          controller.selection,
          controller.document.selectionForGroup(groups[pair.first].groupId),
        );
        await tester.tapAt(_pointAt(tester, groups[pair.last].documentStart));
        await tester.pump();
        expect(
          controller.document.textFor(controller.selection),
          controller.document.fullText,
        );
      }
      await tester.tap(
        find.byKey(const ValueKey('music-lyric-selection-copy')),
      );
      await tester.pump();
      expect(copied, [controller.document.fullText]);
      expect(copied.single, 'Hello\n你好\nStay with me\n留在我身边\nMorning\n清晨');
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .controller
            .selection,
        controller.selection,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sentence selection survives a swipe to another screen of lyrics',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _openPane(
        tester,
        size: const Size(390, 640),
        platform: TargetPlatform.android,
        lyrics: [
          for (var i = 0; i < 40; i++) _cue(i, 'Lyric sentence $i', '第 $i 句翻译'),
        ],
      );
      await tester.tap(
        find.byKey(const ValueKey('music-lyric-selection-sentence')),
      );
      await tester.pump();
      final groups = controller.document.groups;
      await tester.tapAt(_pointAt(tester, groups.first.documentStart));
      await tester.pump();
      final before = controller.selection;
      await tester.drag(find.byType(EditableText), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(controller.selection, before);
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.scrollController!.offset, greaterThan(0));
      final viewport = tester.getRect(find.byType(EditableText));
      final lastVisible = groups.lastWhere(
        (group) => viewport.contains(_pointAt(tester, group.documentStart)),
      );
      await tester.tapAt(_pointAt(tester, lastVisible.documentStart));
      await tester.pump();
      expect(controller.selection.start, 0);
      expect(controller.selection.end, lastVisible.documentEnd);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new lyrics keep the selection document viewport in place', (
    tester,
  ) async {
    final controller = await _openPane(tester);
    final before = tester.getRect(find.byType(EditableText));
    final selection = controller.selection;
    controller.noteSource(
      mediaId: 'song',
      primary: [..._lyrics, _cue(3, 'Next line', '下一句')],
      secondary: const [],
      splitSubtitleByLine: false,
    );
    await tester.pump();
    expect(tester.getRect(find.byType(EditableText)), before);
    expect(controller.selection, selection);
    expect(find.byTooltip('歌词已更新，重新载入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'phone actions fit with large system text in both selection modes',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(568, 320),
      ]) {
        await _openPane(
          tester,
          size: size,
          textScale: 2,
          platform: TargetPlatform.android,
        );
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.tap(
          find.byKey(const ValueKey('music-lyric-selection-sentence')),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$size sentence mode');
        final field = tester.getRect(find.byType(EditableText));
        final copy = tester.getRect(
          find.byKey(const ValueKey('music-lyric-selection-copy')),
        );
        expect(copy.height, greaterThanOrEqualTo(44));
        expect(field.bottom, lessThan(copy.top));
      }
    },
  );

  testWidgets(
    'capture mobile lyric selection previews',
    (tester) async {
      const output = String.fromEnvironment('LYRIC_SELECTION_PREVIEWS');
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        for (final font in {
          'Inter': 'assets/fonts/Inter-Regular.otf',
          'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
          'Roboto': 'assets/fonts/Roboto_Condensed-Regular.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
      final lyrics = [
        _cue(0, 'The evening light is fading', '暮色正在缓缓退去'),
        _cue(1, 'We keep on moving through the night', '我们继续穿过这个夜晚'),
        _cue(2, 'A little closer to the morning', '离晨光又近了一些'),
        _cue(3, 'Let every moment find its way', '让每一刻找到它的方向'),
        _cue(4, 'The melody will stay with you', '旋律会一直陪伴你'),
        _cue(
          5,
          'And all the words we never said will find a home among the stars',
          '那些没来得及说出口的话，会在星光里找到归处',
        ),
        _cue(6, 'We carry on, we carry on', '我们继续向前，继续向前'),
      ];
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 2);
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          picture.dispose();
        });
      }

      for (final width in [320.0, 390.0]) {
        final controller = await _openPane(
          tester,
          size: Size(width, 760),
          platform: TargetPlatform.android,
          lyrics: lyrics,
        );
        await capture('phone-${width.toInt()}');
        await tester.tap(
          find.byKey(const ValueKey('music-lyric-selection-sentence')),
        );
        await tester.pump();
        await tester.tapAt(
          _pointAt(tester, controller.document.groups[1].documentStart),
        );
        await tester.pump();
        await tester.tapAt(
          _pointAt(tester, controller.document.groups[3].documentStart),
        );
        await capture('phone-${width.toInt()}-sentence');
        final before = tester.getRect(find.byType(EditableText));
        await tester.tap(
          find.byKey(const ValueKey('music-lyric-selection-copy')),
        );
        await tester.pump();
        expect(tester.getRect(find.byType(EditableText)), before);
        await capture('phone-${width.toInt()}-copied');
      }
    },
    skip: const String.fromEnvironment('LYRIC_SELECTION_PREVIEWS').isEmpty,
  );

  test('column plans follow the readable minimums', () {
    expect(
      planMusicLyricSelectionColumns(
        vertical: true,
        width: 390,
        height: 844,
        gap: 0,
        toolsTop: 0,
      ).variant,
      MusicLyricWorkspaceVariant.vertical,
    );
    expect(
      planMusicLyricSelectionColumns(
        vertical: false,
        width: 568,
        height: 320,
        gap: 16,
        toolsTop: 64,
      ).degraded,
      isTrue,
    );
    final compact = planMusicLyricSelectionColumns(
      vertical: false,
      width: 844,
      height: 390,
      gap: 16,
      toolsTop: 64,
    );
    expect(compact.compactColumns, isTrue);
    expect(compact.leftWidth, inInclusiveRange(220, 320));
    expect(
      planMusicLyricSelectionColumns(
        vertical: false,
        width: 1280,
        height: 720,
        gap: 24,
        toolsTop: 0,
      ).variant,
      MusicLyricWorkspaceVariant.standardColumns,
    );
    expect(
      musicLyricSelectionChromeTier(innerWidth: 480, textScale: 1),
      MusicLyricSelectionChromeTier.wide,
    );
    expect(
      musicLyricSelectionChromeTier(innerWidth: 360, textScale: 1),
      MusicLyricSelectionChromeTier.stacked,
    );
    expect(
      musicLyricSelectionChromeTier(innerWidth: 420, textScale: 2),
      MusicLyricSelectionChromeTier.menu,
    );
  });

  testWidgets('android draws drag handles for the pressed lyric', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openPane(tester, platform: TargetPlatform.android);
    await tester.pump();
    expect(find.byType(EditableText), findsOneWidget);
    final names = <String>{};
    void walk(Element element) {
      names.add(element.widget.runtimeType.toString());
      element.visitChildren(walk);
    }

    for (final element in find.byType(Overlay).evaluate()) {
      element.visitChildren(walk);
    }
    expect(
      names,
      contains('_SelectionHandleOverlay'),
      reason: names.join('\n'),
    );
  });

  testWidgets('copy and select-all use the visible document', (tester) async {
    final controller = await _openPane(tester);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(find.text('歌词选取'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('music-lyric-selection-field')),
      findsOneWidget,
    );
    final copyButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('music-lyric-selection-copy')),
    );
    expect(
      copyButton.onPressed,
      isNotNull,
      reason: '${controller.selection} / ${controller.document.fullText}',
    );
    await tester.tap(find.byKey(const ValueKey('music-lyric-selection-copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      controller.statusMessage,
      '已复制',
      reason:
          'sel=${controller.selection} text=${controller.document.textFor(controller.selection)} can=${controller.canCopy}',
    );
    expect(
      controller.document.textFor(controller.selection),
      'Stay with me\n留在我身边',
    );
    final field = tester.getRect(
      find.byKey(const ValueKey('music-lyric-selection-field')),
    );
    await tester.tapAt(field.bottomCenter - const Offset(0, 20));
    await tester.pump();
    expect(controller.selection.isCollapsed, isTrue);

    await tester.tap(find.byKey(const ValueKey('music-lyric-selection-all')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('music-lyric-selection-copy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      controller.document.textFor(controller.selection),
      controller.document.fullText,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to primary clears a bilingual range', (tester) async {
    final controller = await _openPane(tester);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.tap(find.text('主字幕'));
    await tester.pump();
    expect(controller.mode, MusicLyricTrackDisplayMode.primary);
    expect(controller.statusMessage, '显示内容已切换，请重新选择');
    expect(controller.selection.isCollapsed, isTrue);
    expect(find.text('显示内容已切换，请重新选择'), findsOneWidget);
  });

  testWidgets('sizes from phone to desktop do not overflow the pane', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const sizes = <Size>[
      Size(320, 568),
      Size(390, 844),
      Size(568, 320),
      Size(844, 390),
      Size(768, 1024),
      Size(1280, 720),
      Size(480, 280),
    ];
    for (final size in sizes) {
      await _openPane(tester, size: size);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(
        find.byKey(const ValueKey('music-lyric-selection-done')),
        findsOneWidget,
      );
    }
  });

  testWidgets(
    'long press enters selection and the releasing finger misses copy',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicLyricRegion(
              mediaId: 'song',
              subtitles: _lyrics,
              secondarySubtitles: const [],
              splitSubtitleByLine: false,
              preference: MusicLyricTrackDisplayMode.both,
              onPreferenceChanged: (_) {},
              onSeek: seeks.add,
              anchorFraction: 0.2,
              applyEdgeFade: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hello')),
      );
      await tester.pump(kLongPressTimeout);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('music-lyric-selection-copy')),
        findsOneWidget,
      );
      final copy = tester.getCenter(
        find.byKey(const ValueKey('music-lyric-selection-copy')),
      );
      await gesture.moveTo(copy);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(seeks, isEmpty);
      expect(find.text('歌词选取'), findsOneWidget);
    },
  );

  testWidgets(
    'escape leaves selection before the page and large type still fits',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(800, 640));
      final regionKey = GlobalKey<MusicLyricRegionState>();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: MusicLyricRegion(
                key: regionKey,
                mediaId: 'song',
                subtitles: _lyrics,
                secondarySubtitles: const [],
                splitSubtitleByLine: false,
                preference: MusicLyricTrackDisplayMode.both,
                onPreferenceChanged: (_) {},
                applyEdgeFade: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hello')),
      );
      await tester.pump(kLongPressTimeout);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(regionKey.currentState!.isSelectionActive, isTrue);
      expect(tester.takeException(), isNull);
      regionKey.currentState!.handleEscape();
      await tester.pump();
      expect(regionKey.currentState!.isSelectionActive, isFalse);
      expect(find.text('Hello'), findsWidgets);
    },
  );
}
