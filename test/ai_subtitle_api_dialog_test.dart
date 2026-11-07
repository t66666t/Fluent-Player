import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';

class _Models extends AiChatTransport {
  final requests = <AiChatSettings>[];
  final cancellations = <AiChatCancellation?>[];
  final replies = <Completer<List<AiModelInfo>>>[];
  @override
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) {
    requests.add(settings);
    cancellations.add(cancellation);
    final reply = Completer<List<AiModelInfo>>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const initial = AiSubtitleApiSettings(
    baseUrl: 'https://example.test/v1',
    model: 'original',
  );
  const preview = bool.fromEnvironment('SUBTITLE_SETTINGS_PREVIEW');
  setUpAll(() async {
    if (!preview) return;
    await (FontLoader('SubtitlePreview')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  Future<void> mount(
    WidgetTester tester,
    _Models transport, {
    AiSubtitleApiSettings settings = initial,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: AiSubtitleApiDialog(settings: settings, transport: transport),
    ),
  );

  testWidgets(
    'Enter checks edited key once, without a duplicate from focus loss',
    (tester) async {
      final transport = _Models();
      await mount(tester, transport);
      await tester.enterText(
        find.byKey(const ValueKey('subtitle-api-key')),
        'sk-test',
      );
      expect(transport.requests, isEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.apiKey, 'sk-test');
      expect(find.text('检查中…'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(transport.requests, hasLength(1));
      transport.replies.single.complete([
        const AiModelInfo(id: 'connected-model'),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('subtitle-api-model')))
            .controller!
            .text,
        'connected-model',
      );
      expect(find.text('已连通，可以选择模型。'), findsOneWidget);
      expect(find.byKey(const ValueKey('subtitle-api-check')), findsOneWidget);
    },
  );

  testWidgets(
    'leaving the key field checks once and unchanged focus changes do not recheck',
    (tester) async {
      final transport = _Models();
      await mount(tester, transport);
      await tester.enterText(
        find.byKey(const ValueKey('subtitle-api-key')),
        'sk-test',
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-api-url')));
      await tester.pump();
      expect(transport.requests, hasLength(1));
      transport.replies.single.complete([]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('subtitle-api-key')));
      await tester.tap(find.byKey(const ValueKey('subtitle-api-url')));
      await tester.pumpAndSettle();
      expect(transport.requests, hasLength(1));
    },
  );

  testWidgets('editing credentials cancels and ignores stale model results', (
    tester,
  ) async {
    final transport = _Models();
    await mount(tester, transport);
    await tester.enterText(
      find.byKey(const ValueKey('subtitle-api-key')),
      'sk-first',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('subtitle-api-key')),
      'sk-second',
    );
    expect(transport.cancellations.first!.isCancelled, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(transport.requests, hasLength(2));
    transport.replies[0].complete([const AiModelInfo(id: 'stale-model')]);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('subtitle-api-model')))
          .controller!
          .text,
      'original',
    );
    transport.replies[1].complete([const AiModelInfo(id: 'current-model')]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('subtitle-api-model')))
          .controller!
          .text,
      'current-model',
    );
  });

  testWidgets(
    'saved credentials are not probed merely by opening or focusing the form',
    (tester) async {
      final transport = _Models();
      await mount(
        tester,
        transport,
        settings: initial.copyWith(apiKey: 'sk-existing'),
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-api-key')));
      await tester.tap(find.byKey(const ValueKey('subtitle-api-url')));
      await tester.pumpAndSettle();
      expect(transport.requests, isEmpty);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(800, 600),
  ]) {
    testWidgets('endpoint form stays reachable at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme: preview
                ? ThemeData.dark().textTheme.apply(
                    fontFamily: 'SubtitlePreview',
                  )
                : null,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: AiSubtitleApiDialog(settings: initial, transport: _Models()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('subtitle-api-check')),
      );
      expect(
        tester.widget(find.byKey(const ValueKey('subtitle-api-check'))),
        isA<FilledButton>(),
      );
      expect(tester.takeException(), isNull);
      if (preview) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/subtitle-settings-ux/previews/interface-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
