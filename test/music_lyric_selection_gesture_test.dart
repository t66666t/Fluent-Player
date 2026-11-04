import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/controllers/music_lyric_pointer_transaction.dart';
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

List<SubtitleItem> get _lyrics => [
  for (var index = 0; index < 6; index++)
    SubtitleItem(
      index: index,
      startTime: Duration(seconds: index * 5),
      endTime: Duration(seconds: index * 5 + 4),
      text: 'Lyric $index',
    ),
];

Future<void> _pump(
  WidgetTester tester,
  List<Duration> seeks,
  List<MusicLyricSelectionRequest> selections,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MusicLyricView(
          subtitles: _lyrics,
          onSeek: seeks.add,
          onRequestTextSelection: selections.add,
          applyEdgeFade: false,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets(
    'lyric long press obeys the live haptic switch without disabling selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final calls = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              calls.add(call.arguments);
            }
            return null;
          });
      addTearDown(() {
        settings.resetForTest();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final seeks = <Duration>[];
      final selections = <MusicLyricSelectionRequest>[];
      await _pump(tester, seeks, selections);
      await tester.longPress(find.text('Lyric 2'));
      await tester.pump();
      expect(calls, ['HapticFeedbackType.selectionClick']);
      expect(selections, hasLength(1));
      calls.clear();
      await settings.saveEnableHapticFeedback(false);
      await tester.longPress(find.text('Lyric 3'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(selections, hasLength(2));
      expect(seeks, isEmpty);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  test('release at the long-press boundary commits only one action', () {
    expect(
      resolveMusicLyricPointerRelease(
        consumed: false,
        movedBeyondSlop: false,
        held: kLongPressTimeout - const Duration(milliseconds: 1),
      ),
      MusicLyricPointerCommit.tap,
    );
    expect(
      resolveMusicLyricPointerRelease(
        consumed: false,
        movedBeyondSlop: false,
        held: kLongPressTimeout,
      ),
      MusicLyricPointerCommit.longPress,
    );
    expect(
      resolveMusicLyricPointerRelease(
        consumed: true,
        movedBeyondSlop: false,
        held: kLongPressTimeout,
      ),
      MusicLyricPointerCommit.none,
    );
    expect(
      resolveMusicLyricPointerRelease(
        consumed: false,
        movedBeyondSlop: true,
        held: kLongPressTimeout * 2,
      ),
      MusicLyricPointerCommit.none,
    );
  });

  testWidgets('a short press seeks once and does not select', (tester) async {
    final seeks = <Duration>[];
    final selections = <MusicLyricSelectionRequest>[];
    await _pump(tester, seeks, selections);
    await tester.tap(find.text('Lyric 2'));
    await tester.pump(const Duration(seconds: 1));
    expect(seeks, [const Duration(seconds: 10)]);
    expect(selections, isEmpty);
  });

  testWidgets('a long press selects the pressed group and never seeks', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final selections = <MusicLyricSelectionRequest>[];
    await _pump(tester, seeks, selections);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Lyric 2')),
    );
    await tester.pump(kLongPressTimeout);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(seeks, isEmpty);
    expect(selections, hasLength(1));
    expect(selections.single.groupId, 'p:2');
    expect(selections.single.awaitingPointer, isTrue);
  });

  testWidgets(
    'leaving the slop and returning cancels both tap and long press',
    (tester) async {
      final seeks = <Duration>[];
      final selections = <MusicLyricSelectionRequest>[];
      await _pump(tester, seeks, selections);
      final point = tester.getCenter(find.text('Lyric 2'));
      final gesture = await tester.startGesture(point);
      await gesture.moveBy(const Offset(0, 12));
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(kLongPressTimeout);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(seeks, isEmpty);
      expect(selections, isEmpty);
    },
  );

  testWidgets('a second finger and a cancelled pointer do not select', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final selections = <MusicLyricSelectionRequest>[];
    await _pump(tester, seeks, selections);
    final point = tester.getCenter(find.text('Lyric 1'));
    final first = await tester.startGesture(point);
    final second = await tester.startGesture(point + const Offset(30, 0));
    await tester.pump(kLongPressTimeout);
    await second.up();
    await first.up();
    final cancelled = await tester.startGesture(point);
    await cancelled.cancel();
    await tester.pump(const Duration(milliseconds: 200));
    expect(seeks, isEmpty);
    expect(selections, isEmpty);
  });

  testWidgets('mouse right click does not seek or enter selection', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final selections = <MusicLyricSelectionRequest>[];
    await _pump(tester, seeks, selections);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Lyric 3')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(seeks, isEmpty);
    expect(selections, isEmpty);
  });
}
