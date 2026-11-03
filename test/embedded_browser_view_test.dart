import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/embedded_browser_view.dart';
import 'support/embedded_browser_platform.dart';

void main() {
  late BrowserTestPlatform platform;
  setUp(() {
    platform = BrowserTestPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  Widget app({
    bool active = true,
    Future<void> Function()? discard,
    VoidCallback? unavailable,
    void Function(InAppWebViewController, int)? progress,
  }) => MaterialApp(
    home: Scaffold(
      body: EmbeddedBrowserView(
        browserId: 'fixture',
        active: active,
        allowPageZoom: true,
        initialUrlRequest: URLRequest(url: WebUri('https://example.com/login')),
        initialSettings: InAppWebViewSettings(
          useHybridComposition: false,
          disableContextMenu: true,
          isTextInteractionEnabled: false,
          thirdPartyCookiesEnabled: true,
        ),
        onDiscardNativeView: discard,
        onControllerUnavailable: unavailable,
        onProgressChanged: progress,
      ),
    ),
  );

  testWidgets(
    'shared policy keeps native pinch and captcha gestures without request interception',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final params = platform.params;
      expect(params.initialSettings!.useHybridComposition, true);
      expect(params.initialSettings!.disableContextMenu, false);
      expect(params.initialSettings!.isTextInteractionEnabled, true);
      expect(params.initialSettings!.useOnRenderProcessGone, true);
      expect(params.initialSettings!.supportZoom, true);
      expect(params.initialSettings!.builtInZoomControls, true);
      expect(params.initialSettings!.displayZoomControls, false);
      expect(params.initialSettings!.thirdPartyCookiesEnabled, true);
      expect(params.gestureRecognizers, isNotEmpty);
      expect(params.shouldInterceptRequest, isNull);
      expect(params.onLoadResource, isNull);
      expect(
        params.initialUserScripts!.single.source,
        embeddedBrowserZoomScript,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'native activity never calls website JavaScript; stale facades still identify the native view',
    (tester) async {
      var latestProgress = 0;
      void progress(InAppWebViewController _, int value) =>
          latestProgress = value;
      await tester.pumpWidget(app(progress: progress));
      await tester.pump();
      final controller = platform.controllers.single;
      controller.callbacks.onProgressChanged!(controller.api, 42);
      expect(latestProgress, 42);
      await tester.pumpWidget(app(active: false, progress: progress));
      expect(controller.pauses, greaterThan(0));
      await tester.pumpWidget(app(progress: progress));
      final resumes = controller.resumes;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final pauses = controller.pauses;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.resumes, greaterThan(resumes));
      expect(pauses, greaterThan(1));
      expect(controller.javascriptCalls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'visible native browser stays rendered across input focus changes',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final controller = platform.controllers.single;
      final pauses = controller.pauses;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(controller.pauses, pauses);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(controller.pauses, greaterThan(pauses));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dialogs retain browser pixels; opaque routes pause the renderer',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final controller = platform.controllers.single;
      final pauses = controller.pauses;
      final context = tester.element(find.byType(EmbeddedBrowserView));
      final dialog = showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Browser menu')),
      );
      await tester.pumpAndSettle();
      expect(controller.pauses, pauses);
      Navigator.of(context).pop();
      await dialog;
      await tester.pumpAndSettle();
      final page = Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Next page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.pauses, greaterThan(pauses));
      Navigator.of(context).pop();
      await page;
      await tester.pumpAndSettle();
      expect(controller.resumes, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final crash in [false, true, null]) {
    testWidgets(
      'renderer exit $crash detaches, awaits cleanup and rejects old callbacks after retry',
      (tester) async {
        final cleanup = Completer<void>();
        var discarded = 0, invalidations = 0, latestProgress = 0;
        await tester.pumpWidget(
          app(
            discard: () {
              discarded++;
              return cleanup.future;
            },
            unavailable: () => invalidations++,
            progress: (_, value) => latestProgress = value,
          ),
        );
        await tester.pump();
        final old = platform.controllers.single;
        final lastPage = WebUri('https://example.com/auth/step2');
        old.callbacks.onLoadStart!(old.api, lastPage);
        if (crash == null) {
          old.callbacks.onWebContentProcessDidTerminate!(old.api);
        } else {
          old.callbacks.onRenderProcessGone!(
            old.api,
            RenderProcessGoneDetail(didCrash: crash),
          );
        }
        await tester.pumpAndSettle();
        expect(find.byType(InAppWebView), findsNothing);
        expect(invalidations, 1);
        expect(discarded, 1);
        await tester.tap(find.text('重新打开网页'));
        await tester.pump();
        expect(platform.controllers, hasLength(1));
        cleanup.complete();
        await tester.pumpAndSettle();
        expect(platform.controllers, hasLength(2));
        final fresh = platform.controllers.last;
        expect(fresh.callbacks.initialUrlRequest!.url, lastPage);
        old.callbacks.onProgressChanged!(old.api, 99);
        old.callbacks.onRenderProcessGone!(
          old.api,
          RenderProcessGoneDetail(didCrash: true),
        );
        expect(latestProgress, 0);
        expect(invalidations, 1);
        fresh.callbacks.onProgressChanged!(fresh.api, 50);
        expect(latestProgress, 50);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'native browser detaches during route exit before the route finishes',
    (tester) async {
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(
        Navigator.of(homeContext).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: EmbeddedBrowserView(
                browserId: 'login',
                initialUrlRequest: URLRequest(
                  url: WebUri('https://example.com'),
                ),
                initialSettings: InAppWebViewSettings(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final native = platform.controllers.single;
      Navigator.of(homeContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byType(InAppWebView), findsNothing);
      expect(native.pauses, greaterThan(0));
      expect(native.javascriptCalls, 0);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
