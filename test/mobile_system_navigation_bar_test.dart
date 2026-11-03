import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/mobile_system_navigation_bar.dart';

void main() {
  test('system icon contrast follows the two actual background colors', () {
    final style = MobileSystemNavigationBar.styleFor(
      backgroundColor: Colors.white,
      bottomBackgroundColor: Colors.black,
    );
    expect(style.statusBarColor, Colors.transparent);
    expect(style.systemNavigationBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
    expect(style.systemStatusBarContrastEnforced, isFalse);
    expect(style.systemNavigationBarContrastEnforced, isFalse);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'status style restores after a covering route on $platform',
      (tester) async {
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.reset);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData.dark(useMaterial3: true),
            builder: (_, child) => MobileSystemNavigationBar(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          SystemChrome.latestStyle!.statusBarIconBrightness,
          Brightness.light,
        );
        expect(SystemChrome.latestStyle!.statusBarBrightness, Brightness.dark);
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const MobileSystemNavigationBar(
                backgroundColor: Colors.white,
                child: Scaffold(
                  backgroundColor: Colors.white,
                  body: SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          SystemChrome.latestStyle!.statusBarIconBrightness,
          Brightness.dark,
        );
        expect(SystemChrome.latestStyle!.statusBarBrightness, Brightness.light);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(SystemChrome.latestStyle!.statusBarColor, Colors.transparent);
        expect(
          SystemChrome.latestStyle!.statusBarIconBrightness,
          Brightness.light,
        );
        expect(SystemChrome.latestStyle!.statusBarBrightness, Brightness.dark);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'Android navigation stays transparent across routes and sheets',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 32);
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          navigatorKey: navigator,
          builder: (_, child) => MobileSystemNavigationBar(child: child!),
          home: Scaffold(appBar: AppBar(title: const Text('home'))),
        ),
      );
      await tester.pumpAndSettle();

      void expectTransparentNavigation() {
        final style = SystemChrome.latestStyle!;
        expect(style.systemNavigationBarColor, Colors.transparent);
        expect(style.systemNavigationBarDividerColor, Colors.transparent);
        expect(style.systemNavigationBarContrastEnforced, isFalse);
        expect(style.systemNavigationBarIconBrightness, Brightness.light);
      }

      expectTransparentNavigation();
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(appBar: AppBar(title: const Text('next'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectTransparentNavigation();
      unawaited(
        showModalBottomSheet<void>(
          context: tester.element(find.text('next')),
          builder: (_) => const SizedBox(height: 200),
        ),
      );
      await tester.pumpAndSettle();
      expectTransparentNavigation();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expectTransparentNavigation();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
