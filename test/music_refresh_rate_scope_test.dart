import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/ui_refresh_rate_scope.dart';

void main() {
  const channel = MethodChannel(
    'com.example.video_player_app/playback_refresh_rate',
  );

  testWidgets(
    'application scope keeps refresh across all routes and dialogs',
    (tester) async {
      final calls = <bool>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add((call.arguments as Map)['active'] as bool);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) => UiRefreshRateScope(child: child!),
          home: const Text('library'),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('player')),
      );
      await tester.pumpAndSettle();
      expect(calls, [true]);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(calls, [true]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(calls, [true, false]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'refresh preference follows route, lifecycle and disposal',
    (tester) async {
      final calls = <Map<Object?, Object?>>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'setActive');
        calls.add(Map<Object?, Object?>.from(call.arguments as Map));
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [AppToast.routeObserver],
          home: const MusicRefreshRateScope(child: Text('music')),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.map((c) => c['active']), [true]);
      final owner = calls.single['owner'];

      // Menus/dialogs leave the animated player visible underneath.
      showDialog<void>(
        context: tester.element(find.text('music')),
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(calls.length, 1);

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('next page')),
      );
      await tester.pumpAndSettle();
      expect(calls.last['active'], false);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(calls.last['active'], true);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(calls.last['active'], false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(calls.length, 4);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.last['active'], true);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.map((c) => c['active']), [
        true,
        false,
        true,
        false,
        true,
        false,
      ]);
      expect(calls.every((call) => call['owner'] == owner), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
