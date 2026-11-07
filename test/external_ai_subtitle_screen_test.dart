import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_action_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_actions.dart';
import 'package:video_player_app/features/external_ai/external_ai_approvals.dart';
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_controller.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_screen.dart';
import 'package:video_player_app/features/external_ai/external_ai_subtitle_backend.dart';
import 'package:video_player_app/features/external_ai/external_ai_subtitle_processing.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';

class _Backend extends Fake implements ExternalAiSubtitleBackend {
  @override
  void addTaskListener(void Function() listener) {}
  @override
  void removeTaskListener(void Function() listener) {}
  @override
  List<ExternalAiNativeTask> tasks() => [];
}

class _Controller extends ExternalAiController {
  _Controller() {
    preferences = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: true,
      allowTaskControl: true,
      allowSubtitleWrite: true,
      preferredClient: 'codex',
    );
  }
  @override
  bool get running => true;
  @override
  Uri? get endpoint => Uri.parse('http://127.0.0.1:38461/mcp');
  @override
  Future<void> initialize(LibraryService library) async {}
  @override
  Future<String> connectionPrompt(ExternalAiClient client) async => '连接播放器';
}

void main() {
  testWidgets(
    'subtitle UI offers independent choices and opens an empty native secret field',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _Controller();
      late Directory root;
      late ExternalAiSubtitleProcessing processing;
      late ExternalAiApprovals approvals;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'subtitle-native-secret-ui-',
        );
        approvals = ExternalAiApprovals(
          store: ExternalAiActionStore(root, name: 'approvals'),
          preferences: () => controller.preferences,
        );
        processing = ExternalAiSubtitleProcessing(
          library: ExternalAiLibrarySource(
            videos: () => [],
            folders: () => [],
            children: (_) => [],
          ),
          backend: _Backend(),
          store: ExternalAiActionStore(root, name: 'subtitles'),
          approvals: approvals,
          preferences: () => controller.preferences,
          generation: () => 0,
        );
        await processing.initialize();
        await processing.callTool('subtitle_service_configure', {
          'name': '新接口',
          'baseUrl': 'https://subtitle.example.test/v1',
          'model': 'instruction-model',
          'requestId': 'native-config-request',
        });
        controller.subtitleProcessing = processing;
        processing.addListener(controller.notifyListeners);
      });
      await tester.pumpWidget(
        MaterialApp(home: ExternalAiScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('优化由谁处理'), findsOneWidget);
      expect(find.text('翻译由谁处理'), findsOneWidget);
      final open = find.text('填写密钥并保存…');
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byType(AiSubtitleApiDialog), findsOneWidget);
      final editors = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .toList();
      expect(
        editors.where((e) => e.obscureText).single.controller.text,
        isEmpty,
      );
      expect(
        editors.any(
          (e) => e.controller.text == 'https://subtitle.example.test/v1',
        ),
        true,
      );
      expect(
        editors.any((e) => e.controller.text == 'instruction-model'),
        true,
      );
      expect(processing.connectionRequests.single['status'], 'awaiting_user');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await controller.shutdown();
        approvals.dispose();
        await root.delete(recursive: true);
      });
      controller.dispose();
    },
  );
}
