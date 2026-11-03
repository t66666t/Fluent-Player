import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';

class _Transport extends AiChatTransport {
  final catalogCalls = <AiChatSettings>[];
  final testCalls = <AiChatSettings>[];
  bool loggedIn = true;
  @override
  Future<AiCliStatus> inspectCli(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async => AiCliStatus(
    executablePath: 'C:/Tools/${settings.backend.name}.exe',
    version: 'fixture CLI 1.0',
    loggedIn: settings.backend == AiBackend.codex ? loggedIn : null,
  );
  @override
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    catalogCalls.add(settings);
    return [
      AiModelInfo(
        id: settings.backend == AiBackend.codex
            ? 'account-model'
            : 'provider/model-b',
        name: '目录模型',
        contextWindow: 128000,
        reasoningEfforts: const ['low', 'high'],
        defaultReasoningEffort: 'low',
        supportsThinking: true,
        supportsReasoningEffort: true,
      ),
    ];
  }

  @override
  Future<String> testConnection(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    testCalls.add(settings);
    return '连接成功：OK';
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _Transport transport,
    AiChatSettings settings,
    ValueChanged<AiChatSettings> saved, {
    Size size = const Size(1100, 850),
    Future<void> Function(AiChatSettings)? onSave,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showDialog<AiChatSettings>(
                  context: context,
                  builder: (_) => AiSettingsDialog(
                    settings: settings,
                    transport: transport,
                    onSave: onSave,
                  ),
                );
                if (result != null) saved(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> backend(WidgetTester tester, String label) async {
    await tap(tester, find.byKey(const ValueKey('ai-settings-backend')));
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'selecting a model persists before barrier dismissal and releases search keyboard',
    (tester) async {
      final transport = _Transport();
      AiChatSettings? persisted;
      await open(
        tester,
        transport,
        const AiChatSettings(backend: AiBackend.codex, model: 'old'),
        (_) {},
        onSave: (value) async {
          persisted = value;
        },
      );
      await tap(tester, find.byKey(const ValueKey('ai-load-models')));
      await tap(tester, find.byKey(const ValueKey('ai-settings-model')));
      expect(tester.testTextInput.isVisible, isTrue);
      await tap(tester, find.byKey(const ValueKey('ai-select-model')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-model-search')),
        '目录模型',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录模型').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(persisted?.model, 'account-model');
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tapAt(const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsDialog), findsNothing);
      expect(persisted?.model, 'account-model');
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'directory paths resolve, CLI models become selectable, and connection uses the selected model',
    (tester) async {
      final transport = _Transport();
      AiChatSettings? saved;
      await open(
        tester,
        transport,
        const AiChatSettings(
          backend: AiBackend.codex,
          executablePath: 'C:/install/bin',
          model: '',
        ),
        (value) => saved = value,
      );
      await tap(tester, find.byKey(const ValueKey('ai-load-models')));
      expect(transport.catalogCalls.single.backend, AiBackend.codex);
      final model = tester.widget<TextFormField>(
        find.byKey(const ValueKey('ai-settings-model')),
      );
      expect(model.controller!.text, 'account-model');
      await tap(tester, find.byKey(const ValueKey('ai-select-model')));
      expect(find.text('目录模型'), findsOneWidget);
      await tester.tap(find.text('目录模型'));
      await tester.pumpAndSettle();
      expect(find.text('CLI 思考等级'), findsOneWidget);
      await tap(tester, find.text('测试连接'));
      expect(transport.testCalls.single.model, 'account-model');
      expect(transport.testCalls.single.executablePath, 'C:/Tools/codex.exe');
      expect(find.text('连接成功：OK'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.cliProfiles['codex']!.model, 'account-model');
      expect(saved!.selectedModelInfo!.reasoningEfforts, ['low', 'high']);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
  testWidgets(
    'API Codex and OpenCode retain separate models and cached directories during switching',
    (tester) async {
      final transport = _Transport();
      AiChatSettings? saved;
      await open(
        tester,
        transport,
        const AiChatSettings(
          model: 'api-model',
          cliProfiles: {
            'codex': AiCliProfile(
              executablePath: 'codex-path',
              model: 'codex-model',
            ),
            'opencode': AiCliProfile(
              executablePath: 'opencode-path',
              model: 'provider/model',
            ),
          },
        ),
        (value) => saved = value,
      );
      String selected() => tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-settings-model')),
          )
          .controller!
          .text;
      await backend(tester, '桌面 · Codex CLI');
      expect(selected(), 'codex-model');
      await backend(tester, '桌面 · OpenCode CLI');
      expect(selected(), 'provider/model');
      await backend(tester, 'API 服务');
      expect(selected(), 'api-model');
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.cliProfiles['codex']!.executablePath, 'codex-path');
      expect(saved!.cliProfiles['opencode']!.executablePath, 'opencode-path');
      expect(saved!.apiModel, 'api-model');
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
  testWidgets(
    'reopening CLI settings restores the API model saved in a previous session',
    (tester) async {
      final settings = AiChatSettings.fromJson(
        const AiChatSettings(
          backend: AiBackend.codex,
          model: 'codex-model',
          apiModel: 'saved-api-model',
          apiReasoningEffort: 'medium',
        ).toJson(),
      );
      AiChatSettings? saved, persisted;
      await open(
        tester,
        _Transport(),
        settings,
        (value) => saved = value,
        onSave: (value) async => persisted = value,
      );
      await backend(tester, 'API 服务');
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('ai-settings-model')),
            )
            .controller!
            .text,
        'saved-api-model',
      );
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.reasoningEffort, 'medium');
      expect(persisted?.backend, AiBackend.api);
      expect(persisted?.cliProfiles['codex']?.model, 'codex-model');
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
  testWidgets(
    'installed but logged-out Codex reports login state before invoking the model',
    (tester) async {
      final transport = _Transport()..loggedIn = false;
      await open(
        tester,
        transport,
        const AiChatSettings(backend: AiBackend.codex, model: 'model-a'),
        (_) {},
        size: const Size(320, 640),
      );
      await tap(tester, find.byKey(const ValueKey('ai-detect-cli')));
      expect(find.textContaining('尚未登录'), findsWidgets);
      await tap(tester, find.text('测试连接'));
      expect(transport.testCalls, isEmpty);
      expect(find.textContaining('codex login'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
