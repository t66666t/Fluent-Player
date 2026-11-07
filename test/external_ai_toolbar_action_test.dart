import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_connection_status.dart';
import 'package:video_player_app/features/external_ai/external_ai_controller.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_screen.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/features/external_ai/external_ai_toolbar_action.dart';
import 'package:video_player_app/services/library_service.dart';

class _ActivityController extends ExternalAiController {
  _ActivityController() {
    preferences = const ExternalAiPreferences(enabled: true, token: 'test');
  }

  DateTime? activity;
  bool enabled = true;

  @override
  bool get running => enabled;
  @override
  DateTime? get lastExternalToolCallAt => enabled ? activity : null;
  @override
  int get externalToolCallCount => lastExternalToolCallAt == null ? 0 : 1;
  @override
  Future<void> initialize(LibraryService library) async {}

  void recordCall() {
    activity = DateTime(2026, 11, 3, 12, 34, 56);
    notifyListeners();
  }

  void closeAccess() {
    enabled = false;
    notifyListeners();
  }
}

class _RealHttpOverrides extends HttpOverrides {}

class _OverviewSource extends ExternalAiDataSource {
  @override
  List<Map<String, dynamic>> get tools => [
    {
      'name': 'player_overview',
      'inputSchema': {'type': 'object'},
    },
  ];
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async => {'readOnly': true, 'mediaCount': 1};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'successful player self-check never verifies an external Agent',
    () async {
      final controller = ExternalAiController();
      controller.preferences = const ExternalAiPreferences(
        enabled: true,
        token: 'test-token',
      );
      controller.server = ExternalAiServer(
        dataSource: _OverviewSource(),
        token: 'test-token',
        onRequest: controller.notifyListeners,
      );
      await controller.server!.start();
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await HttpOverrides.runWithHttpOverrides(
        controller.checkConnection,
        _RealHttpOverrides(),
      );
      expect(controller.diagnostic, contains('播放器连接正常'));
      expect(controller.server!.requestCount, 3);
      expect(controller.externalToolCallCount, 0);
      expect(controller.lastExternalToolCallAt, isNull);
    },
  );

  testWidgets('toolbar opens connection directly and reflects real activity', (
    tester,
  ) async {
    final controller = _ActivityController();
    addTearDown(controller.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            actions: [ExternalAiToolbarAction(controller: controller)],
          ),
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) =>
                ExternalAiConnectionStatus(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('连接外部 AI'), findsOneWidget);
    expect(find.byTooltip('连接外部 AI (Q)\n等待 Agent 调用'), findsOneWidget);
    expect(find.text('等待 Agent 调用'), findsOneWidget);
    controller.recordCall();
    await tester.pump();
    expect(find.text('已收到 Agent 调用 · 12:34:56'), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.hub_outlined)).color,
      externalAiVerifiedColor,
    );
    await tester.tap(find.text('连接外部 AI'));
    await tester.pumpAndSettle();
    expect(find.byType(ExternalAiScreen), findsOneWidget);
    expect(find.text('已收到 Agent 调用 · 12:34:56'), findsOneWidget);
    controller.closeAccess();
    await tester.pumpAndSettle();
    expect(find.text('外部 AI 读取已关闭'), findsOneWidget);
    expect(find.textContaining('已收到 Agent 调用'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ExternalAiScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow and large-font desktop toolbar keeps the entry visible', (
    tester,
  ) async {
    final controller = _ActivityController();
    addTearDown(controller.dispose);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 390.0, 768.0, 1280.0, 1600.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        tester.view.physicalSize = Size(width, 500);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(
                title: const Text('我的媒体库', overflow: TextOverflow.ellipsis),
                actions: [
                  ExternalAiToolbarAction(
                    compact: true,
                    controller: controller,
                  ),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.hub_outlined).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $scale');
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
