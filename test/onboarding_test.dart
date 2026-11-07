import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/onboarding/onboarding_screen.dart';
import 'package:video_player_app/features/onboarding/onboarding_store.dart';
import 'package:video_player_app/services/settings_service.dart';

const _previews = bool.fromEnvironment('ONBOARDING_PREVIEWS');
const _capture = ValueKey('setup-capture');

void main() {
  setUpAll(() async {
    if (!_previews) return;
    await (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<SettingsService> open(
    WidgetTester tester, {
    Size size = const Size(1100, 900),
    double scale = 1,
    Future<void> Function(BuildContext, OnboardingDestination)? destination,
  }) async {
    SharedPreferences.setMockInitialValues({
      'copyImportedMediaToPrivateStorage': false,
      'autoPlayOnPageEntry': true,
      'mediaLibraryRestoreLastPage': true,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(primary: Colors.blue),
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans SC'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('原页面'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OnboardingScreen(
                      settings: settings,
                      preview: true,
                      openDestination: destination ?? (_, _) async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('原页面'));
    await tester.pumpAndSettle();
    return settings;
  }

  Future<void> click(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    final toggle = find.descendant(of: finder, matching: find.byType(Switch));
    await tester.tap(toggle.evaluate().length == 1 ? toggle : finder);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!_previews) return;
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_capture),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.artifacts/onboarding/settings-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (name, size, scale) in [
    ('desktop', const Size(1280, 900), 1.0),
    ('phone', const Size(390, 844), 1.0),
    ('small-phone', const Size(320, 568), 1.0),
    ('landscape', const Size(844, 390), 1.0),
    ('large-text', const Size(320, 568), 2.0),
  ]) {
    testWidgets('settings and all destinations remain reachable at $name', (
      tester,
    ) async {
      final opened = <OnboardingDestination>[];
      await open(
        tester,
        size: size,
        scale: scale,
        destination: (_, page) async {
          opened.add(page);
        },
      );
      expect(tester.takeException(), isNull);
      await capture(tester, name);
      if (scale == 1) {
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          closeTo(0, .1),
          reason: 'The initial choices should fit on one screen at $name.',
        );
      }
      final restore = find.byKey(const ValueKey('mediaLibraryRestoreLastPage'));
      await click(tester, restore);
      final picker = find.byKey(const ValueKey('onboarding-startup-entry'));
      expect(picker, findsOneWidget);
      if (scale == 1) {
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          closeTo(0, .1),
        );
      }
      await capture(tester, '$name-startup');
      await click(tester, restore);
      for (final page in const [
        OnboardingDestination.network,
        OnboardingDestination.subtitleServices,
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('onboarding-${page.name}')),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await click(tester, find.byKey(ValueKey('onboarding-${page.name}')));
        expect(tester.takeException(), isNull);
      }
      expect(opened, const [
        OnboardingDestination.network,
        OnboardingDestination.subtitleServices,
      ]);
      expect(
        find.byKey(const ValueKey('onboarding-close')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-done')).hitTestable(),
        findsOneWidget,
      );
      await click(tester, find.byKey(const ValueKey('onboarding-done')));
      expect(find.text('原页面'), findsOneWidget);
    });
  }

  testWidgets(
    'options save immediately, startup picker retains the selected page',
    (tester) async {
      final settings = await open(tester);
      await click(
        tester,
        find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
      );
      await click(tester, find.byKey(const ValueKey('autoPlayOnPageEntry')));
      await click(
        tester,
        find.byKey(const ValueKey('mediaLibraryRestoreLastPage')),
      );
      await click(
        tester,
        find.byKey(const ValueKey('onboarding-startup-entry')),
      );
      await click(tester, find.text('播客').last);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('copyImportedMediaToPrivateStorage'), isTrue);
      expect(prefs.getBool('autoPlayOnPageEntry'), isFalse);
      expect(prefs.getBool('mediaLibraryRestoreLastPage'), isFalse);
      expect(prefs.getString('mediaLibraryStartupEntry'), 'podcasts');
      expect(settings.mediaLibraryStartupEntry, 'podcasts');
      await click(tester, find.byKey(const ValueKey('onboarding-close')));
      await tester.tap(find.text('原页面'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
            )
            .value,
        isTrue,
      );
      expect(find.text('播客'), findsOneWidget);
    },
  );

  testWidgets('a real settings subpage returns to setup without losing edits', (
    tester,
  ) async {
    final settings = await open(
      tester,
      destination: (context, _) => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(appBar: AppBar(title: const Text('网络子页'))),
        ),
      ),
    );
    await click(
      tester,
      find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
    );
    await click(tester, find.byKey(const ValueKey('onboarding-network')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('使用前设置'), findsOneWidget);
    expect(settings.copyImportedMediaToPrivateStorage, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening failure is retryable and does not block closing', (
    tester,
  ) async {
    await open(
      tester,
      destination: (_, _) async => throw StateError('offline'),
    );
    await click(tester, find.byKey(const ValueKey('onboarding-network')));
    expect(find.text('暂时无法打开，请稍后重试。'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('原页面'), findsOneWidget);
  });

  test(
    'new installation offers once, existing settings skip automatic setup',
    () async {
      SharedPreferences.setMockInitialValues({});
      await OnboardingStore.prepareFirstLaunch();
      expect(await OnboardingStore.shouldShow(), isTrue);
      await OnboardingStore.markHandled();
      expect(await OnboardingStore.shouldShow(), isFalse);
      SharedPreferences.setMockInitialValues({'subtitleStyle': 'existing'});
      await OnboardingStore.prepareFirstLaunch();
      expect(await OnboardingStore.shouldShow(), isFalse);
    },
  );
}
