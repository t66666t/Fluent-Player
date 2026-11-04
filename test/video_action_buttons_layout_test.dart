import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

const _actions = ['语音转录', '批量字幕导入', '新建合集', '导入媒体'];

Finder _cell(String identity) =>
    find.byKey(ValueKey('action-button-cell-$identity'));

Finder _disc(String identity) =>
    find.byKey(ValueKey('action-button-disc-$identity'));

Future<void> _mount(
  WidgetTester tester,
  SettingsService settings, {
  required Size size,
  bool labels = true,
  double textScale = 1,
  double? maxHeight,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  settings.isActionButtonsCollapsed = false;
  settings.showActionButtonLabels = labels;
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          floatingActionButtonLocation: const PlaybackActionButtonsLocation(),
          floatingActionButton: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: VideoActionButtons(maxExpandedHeight: maxHeight),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
  });

  tearDown(() => settings.resetForTest());

  testWidgets(
    'remaining actions align above the toggle without empty button slots',
    (tester) async {
      addTearDown(tester.view.reset);
      for (final size in const [
        Size(360, 640),
        Size(844, 390),
        Size(768, 1024),
        Size(1440, 900),
      ]) {
        for (final labels in [true, false]) {
          await _mount(tester, settings, size: size, labels: labels);
          final toggle = tester.getRect(_cell('toggle'));
          Rect? previous;
          for (final identity in [..._actions, 'toggle']) {
            final rect = tester.getRect(_cell(identity));
            expect(rect.center.dx, closeTo(toggle.center.dx, 0.01));
            expect(_disc(identity).hitTestable(), findsOneWidget);
            if (previous != null) {
              expect(rect.top - previous.bottom, inInclusiveRange(4, 6.01));
            }
            previous = rect;
          }

          await tester.tap(_disc('toggle'));
          await tester.pumpAndSettle();
          expect(settings.isActionButtonsCollapsed, isTrue);
          expect(tester.getRect(_cell('toggle')), rectMoreOrLessEquals(toggle));
          for (final identity in _actions) {
            expect(_cell(identity), findsNothing);
          }

          await tester.tap(_disc('toggle'));
          await tester.pumpAndSettle();
          expect(settings.isActionButtonsCollapsed, isFalse);
          expect(tester.getRect(_cell('toggle')), rectMoreOrLessEquals(toggle));
          expect(tester.takeException(), isNull);
        }
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'short windows scroll every action while the toggle stays fixed',
    (tester) async {
      addTearDown(tester.view.reset);
      await _mount(
        tester,
        settings,
        size: const Size(640, 360),
        textScale: 2,
        maxHeight: 200,
      );
      final toggle = tester.getRect(_cell('toggle'));
      final scroll = find.byKey(const ValueKey('action-rail-scroll'));
      expect(tester.getRect(scroll).height, lessThan(200));
      for (final identity in _actions) {
        await tester.ensureVisible(_disc(identity));
        await tester.pumpAndSettle();
        expect(_disc(identity).hitTestable(), findsOneWidget);
        expect(
          tester.getCenter(_disc(identity)).dx,
          closeTo(toggle.center.dx, 0.01),
        );
        expect(tester.getRect(_cell('toggle')), rectMoreOrLessEquals(toggle));
      }
      expect(tester.takeException(), isNull);
    },
  );
}
