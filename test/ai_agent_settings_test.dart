import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_agent_catalog.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';

class _AgentTransport extends AiChatTransport {
  final requests = <AiChatSettings>[];

  @override
  Future<AiCliStatus> inspectCli(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    requests.add(settings);
    return AiCliStatus(
      executablePath: settings.executablePath,
      version: 'ACP fixture',
      loggedIn: true,
    );
  }
}

void main() {
  test('installed ACP commands do not invoke package downloaders', () {
    expect(
      aiAgentPresets.map((value) => value.backend).toSet().length,
      aiAgentPresets.length,
    );
    expect(AiBackend.geminiCli.agentPreset!.arguments, ['--acp']);
    expect(AiBackend.cursor.agentPreset!.executable, 'cursor-agent');
    expect(AiBackend.claude.agentPreset!.executable, 'claude-agent-acp');
    for (final preset in aiAgentPresets) {
      expect(preset.executable, isNot(anyOf('npx', 'uvx', 'npm')));
      expect(preset.supportsPlatform('android'), isFalse);
      expect(preset.supportsPlatform('ios'), isFalse);
    }
    expect(
      AiBackend.qoder.agentPreset!.supportsPlatform(
        'windows',
        architecture: 'arm64',
      ),
      isFalse,
    );
    expect(
      AiBackend.qwenCode.agentPreset!.supportsPlatform(
        'windows',
        architecture: 'x64',
      ),
      isTrue,
    );
  });

  test('all Agent profiles round-trip without dropping legacy CLI choices', () {
    final profiles = <String, AiCliProfile>{
      for (final backend in AiBackend.values.where((b) => b != AiBackend.api))
        backend.name: AiCliProfile(
          executablePath: '/installed/${backend.name}',
          cliArguments: ['--profile', 'profile with spaces'],
          model: '${backend.name}/model',
          reasoningEffort: 'high',
          models: [AiModelInfo(id: '${backend.name}/model')],
        ),
    };
    profiles['future-agent'] = const AiCliProfile(
      executablePath: '/future-agent',
      model: 'future-model',
    );
    final original = AiChatSettings(
      backend: AiBackend.acp,
      executablePath: '/installed/custom agent',
      cliArguments: const ['acp', '--profile', 'learning'],
      cliProfiles: profiles,
    );
    final restored = AiChatSettings.fromJson(original.toJson());
    expect(restored.backend, AiBackend.acp);
    expect(restored.cliArguments, original.cliArguments);
    expect(restored.cliProfiles.keys, profiles.keys);
    for (final name in profiles.keys) {
      expect(restored.cliProfiles[name]!.toJson(), profiles[name]!.toJson());
    }
    final legacy = AiChatSettings.fromJson({
      'version': 3,
      'backend': 'codex',
      'executablePath': 'C:/tools/codex.exe',
      'cliProfiles': {
        'codex': {'model': 'existing-model'},
        'opencode': {'model': 'provider/existing-model'},
      },
    });
    expect(legacy.backend, AiBackend.codex);
    expect(legacy.cliArguments, isEmpty);
    expect(legacy.cliProfiles['opencode']!.model, 'provider/existing-model');
  });

  test(
    'custom argument parsing preserves argument boundaries and rejects damage',
    () {
      expect(aiParseAgentArguments('["--acp", "a b", "中文"]'), [
        '--acp',
        'a b',
        '中文',
      ]);
      expect(aiParseAgentArguments(''), isEmpty);
      for (final invalid in ['--acp', '{}', '[1]', '["\\u0000"]']) {
        expect(() => aiParseAgentArguments(invalid), throwsFormatException);
      }
      final damaged = AiChatSettings.fromJson({
        'backend': 'acp',
        'cliArguments': ['--acp', 5],
      });
      expect(damaged.cliArguments, isEmpty);
    },
  );

  test(
    'changing custom launch arguments invalidates cached model capabilities',
    () {
      const settings = AiChatSettings(
        backend: AiBackend.acp,
        executablePath: '/agent',
        cliArguments: ['--profile', 'one'],
        model: 'same-name',
        cliProfiles: {
          'acp': AiCliProfile(
            executablePath: '/agent',
            cliArguments: ['--profile', 'one'],
            models: [AiModelInfo(id: 'same-name', contextWindow: 128000)],
          ),
        },
      );
      expect(settings.selectedModelInfo?.contextWindow, 128000);
      expect(
        settings.copyWith(cliArguments: ['--profile', 'two']).selectedModelInfo,
        isNull,
      );
    },
  );

  Future<void> open(
    WidgetTester tester,
    AiChatSettings settings,
    _AgentTransport transport,
    Future<void> Function(AiChatSettings) onSave,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiSettingsDialog(
            settings: settings,
            transport: transport,
            onSave: onSave,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> selectBackend(WidgetTester tester, String label) async {
    await tap(tester, find.byKey(const ValueKey('ai-settings-backend')));
    await tap(tester, find.text(label).last);
  }

  testWidgets(
    'custom executable and JSON arguments persist per Agent',
    (tester) async {
      AiChatSettings? saved;
      final transport = _AgentTransport();
      await open(
        tester,
        const AiChatSettings(
          backend: AiBackend.acp,
          executablePath: '/custom agent',
          model: 'custom-model',
          cliArguments: ['--acp', '--profile', 'learning'],
        ),
        transport,
        (value) async => saved = value,
      );
      await selectBackend(tester, '桌面 · Qwen Code');
      await tester.pump(const Duration(milliseconds: 450));
      expect(saved?.backend, AiBackend.qwenCode);
      expect(saved?.model, isEmpty);
      await selectBackend(tester, '桌面 · 自定义 ACP Agent');
      await tester.pump(const Duration(milliseconds: 450));
      expect(saved?.backend, AiBackend.acp);
      expect(saved?.executablePath, '/custom agent');
      expect(saved?.cliArguments, ['--acp', '--profile', 'learning']);
      expect(saved?.model, 'custom-model');
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'malformed custom arguments block persistence and detection',
    (tester) async {
      final saved = <AiChatSettings>[];
      final transport = _AgentTransport();
      await open(
        tester,
        const AiChatSettings(
          backend: AiBackend.acp,
          executablePath: '/custom agent',
          model: '',
        ),
        transport,
        (value) async => saved.add(value),
      );
      final arguments = find.byKey(
        const ValueKey('ai-settings-agent-arguments'),
      );
      await tester.ensureVisible(arguments);
      await tester.enterText(arguments, '[1]');
      await tester.pump(const Duration(milliseconds: 450));
      await tap(tester, find.byKey(const ValueKey('ai-detect-cli')));
      expect(transport.requests, isEmpty);
      expect(saved, isEmpty);
      expect(find.textContaining('参数必须是最多 64 项'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'mobile hides every CLI backend and restores API settings without losing desktop profiles',
    (tester) async {
      for (final backend in AiBackend.values) {
        final writes = <AiChatSettings>[];
        final transport = _AgentTransport();
        await open(
          tester,
          AiChatSettings(
            backend: backend,
            model: backend == AiBackend.api
                ? 'remembered-api-model'
                : 'stored-cli-model',
            apiKey: 'fixture-api-key',
            apiModel: 'remembered-api-model',
            apiReasoningEffort: 'medium',
            reasoningEffort: 'high',
            executablePath: '/installed-agent',
            cliArguments: const ['--acp', '--profile', 'saved'],
          ),
          transport,
          (value) async => writes.add(value),
        );
        expect(writes, isEmpty);
        expect(find.byKey(const ValueKey('ai-detect-cli')), findsNothing);
        expect(
          find.byKey(const ValueKey('ai-settings-agent-arguments')),
          findsNothing,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('ai-settings-model')),
              )
              .controller!
              .text,
          'remembered-api-model',
        );
        await tap(tester, find.byKey(const ValueKey('ai-settings-backend')));
        expect(find.textContaining('桌面 ·'), findsNothing);
        expect(find.text('API 服务'), findsWidgets);
        await tap(tester, find.text('API 服务').last);
        await tester.enterText(
          find.byKey(const ValueKey('ai-settings-model')),
          'edited-api-model',
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        expect(writes.single.backend, AiBackend.api);
        expect(writes.single.model, 'edited-api-model');
        if (backend != AiBackend.api) {
          final retained = writes.single.cliProfiles[backend.name]!;
          expect(retained.model, 'stored-cli-model');
          expect(retained.reasoningEffort, 'high');
          expect(retained.executablePath, '/installed-agent');
          expect(retained.cliArguments, ['--acp', '--profile', 'saved']);
          expect(writes.single.reasoningEffort, 'medium');
        }
        expect(transport.requests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
