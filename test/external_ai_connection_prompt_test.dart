import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_controller.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/app_data_paths.dart';
import 'package:video_player_app/utils/app_branding.dart';

class _ClipboardController extends ExternalAiController {
  _ClipboardController(this.prompt) {
    preferences = const ExternalAiPreferences(
      enabled: true,
      token: 'clipboard-token-must-not-appear',
      preferredClient: 'codex',
    );
  }
  final String prompt;
  int copies = 0;
  @override
  bool get running => true;
  @override
  Uri? get endpoint => Uri.parse('http://127.0.0.1:38461/mcp');
  @override
  Future<void> initialize(LibraryService library) async {}
  @override
  Future<void> rememberClient(ExternalAiClient client) async {
    busy = true;
    notifyListeners();
    await Future<void>.value();
    preferences = preferences!.copyWith(preferredClient: client.name);
    busy = false;
    notifyListeners();
  }

  @override
  Future<String> connectionPrompt(ExternalAiClient client) async {
    copies++;
    return prompt;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('fluent_ai_prompt_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  Future<ExternalAiController> controller({bool enable = true}) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final store = ExternalAiPreferencesStore(root: directory);
    await store.save(
      ExternalAiPreferences(
        token: ExternalAiPreferences.generateToken(),
        port: port,
      ),
    );
    final value = ExternalAiController(store: store);
    addTearDown(() async {
      await value.shutdown();
      value.dispose();
    });
    await value.initialize(LibraryService());
    if (enable) await value.update(value.preferences!.copyWith(enabled: true));
    return value;
  }

  test(
    'connection instruction points to per-client app-owned file and never embeds credential',
    () async {
      final value = await controller();
      final token = value.preferences!.token;
      final serverName = kMcpServerName;
      for (final client in [
        ExternalAiClient.codex,
        ExternalAiClient.workBuddy,
        ExternalAiClient.qwenWork,
      ]) {
        final prompt = await value.connectionPrompt(client);
        final file = File(
          p.join(
            directory.path,
            'external_ai',
            '$kAppDataFolderName-${client.name}-setup.json',
          ),
        );
        expect(await file.exists(), isTrue);
        final payload = jsonDecode(await file.readAsString()) as Map;
        expect(payload['version'], 1);
        expect(payload['application'], kAppDataFolderName);
        expect(payload['client'], client.name);
        expect(payload['serverName'], serverName);
        expect(payload['readOnly'], isTrue);
        expect(payload['endpoint'], value.endpoint.toString());
        expect(
          payload['configuration'],
          externalAiClientConfiguration(
            client,
            endpoint: value.endpoint!,
            token: token,
            serverName: serverName,
          ),
        );
        expect(prompt, contains(jsonEncode(file.absolute.path)));
        expect(prompt, contains('player_overview'));
        expect(prompt, contains('library_browse'));
        expect(prompt, isNot(contains(token)));
        expect(prompt, isNot(contains('Bearer $token')));
      }
      final setupFiles = await Directory(
        p.join(directory.path, 'external_ai'),
      ).list().where((entity) => entity.path.endsWith('-setup.json')).toList();
      expect(setupFiles, hasLength(3));
    },
  );

  test(
    'rotating access refreshes only its own setup document and disabled access refuses a prompt',
    () async {
      final value = await controller();
      final originalToken = value.preferences!.token;
      final first = await value.connectionPrompt(ExternalAiClient.codex);
      final file = File(
        p.join(
          directory.path,
          'external_ai',
          '$kAppDataFolderName-codex-setup.json',
        ),
      );
      final nextToken = ExternalAiPreferences.generateToken();
      await value.update(value.preferences!.copyWith(token: nextToken));
      final second = await value.connectionPrompt(ExternalAiClient.codex);
      expect(second, first);
      final contents = await file.readAsString();
      expect(contents, contains(nextToken));
      expect(contents, isNot(contains(originalToken)));
      expect(second, isNot(contains(nextToken)));
      await value.update(value.preferences!.copyWith(enabled: false));
      await expectLater(
        value.connectionPrompt(ExternalAiClient.workBuddy),
        throwsStateError,
      );
      expect(
        await File(
          p.join(
            directory.path,
            'external_ai',
            '$kAppDataFolderName-workBuddy-setup.json',
          ),
        ).exists(),
        isFalse,
      );
    },
  );

  testWidgets('primary copy button places the setup instruction on clipboard', (
    tester,
  ) async {
    final prompt = List.filled(
      16,
      '请连接播放器，读取本机连接说明文件并验证媒体库。完整提示词末尾也需要复制。',
    ).join('\n');
    final value = _ClipboardController(prompt);
    addTearDown(value.dispose);
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ExternalAiScreen(controller: value)),
    );
    await tester.pumpAndSettle();
    expect(value.copies, 1);
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('external-ai-connection-excerpt')),
    );
    expect(preview.data, prompt);
    expect(
      find.byKey(const ValueKey('external-ai-connection-preview')),
      findsNothing,
    );
    final button = find.byKey(const ValueKey('external-ai-copy-prompt'));
    await tester.scrollUntilVisible(
      button,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(button), alignment: .3);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(value.copies, 1);
    expect(copied, prompt);
    expect(copied, isNot(contains(value.preferences!.token)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
