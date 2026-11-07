import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_controller.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/theme/app_typography.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _MemoryStore extends ExternalAiPreferencesStore {
  _MemoryStore(this.value);

  ExternalAiPreferences value;
  bool rejectSave = false;

  @override
  Future<ExternalAiPreferences> load() async => value;

  @override
  Future<void> save(ExternalAiPreferences preferences) async {
    if (rejectSave) throw const FileSystemException('test save failure');
    value = preferences;
  }
}

class _WidgetController extends ExternalAiController {
  _WidgetController({
    bool enabled = true,
    String? scopeFolderId,
    String? preferredClient = 'codex',
    this.promptFactory,
  }) {
    preferences = ExternalAiPreferences(
      token: ExternalAiPreferences.generateToken(),
      enabled: enabled,
      scopeFolderId: scopeFolderId,
      preferredClient: preferredClient,
    );
  }

  final Future<String> Function(ExternalAiClient)? promptFactory;
  final List<ExternalAiClient> promptRequests = [];

  @override
  bool get running => preferences!.enabled;

  @override
  Uri? get endpoint => running ? Uri.parse('http://127.0.0.1:38461/mcp') : null;

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
    promptRequests.add(client);
    return await (promptFactory?.call(client) ??
        Future.value('请连接播放器：${client.name} ${endpoint!}'));
  }

  @override
  Future<void> update(ExternalAiPreferences next) async {
    preferences = next;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<int> availablePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  test(
    'controller enables and disables listener and persists access choices',
    () async {
      final store = _MemoryStore(
        ExternalAiPreferences(
          token: ExternalAiPreferences.generateToken(),
          port: await availablePort(),
        ),
      );
      final controller = ExternalAiController(store: store);
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await controller.initialize(LibraryService());
      expect(controller.running, isFalse);
      expect(controller.preferences!.enabled, isFalse);
      await controller.update(
        controller.preferences!.copyWith(
          enabled: true,
          scopeFolderId: 'course',
        ),
      );
      expect(controller.running, isTrue);
      expect(store.value.enabled, isTrue);
      expect(store.value.scopeFolderId, 'course');
      expect(store.value.includeConversations, isFalse);
      expect(controller.endpoint!.host, '127.0.0.1');
      await controller.update(controller.preferences!.copyWith(enabled: false));
      expect(controller.running, isFalse);
      expect(store.value.enabled, isFalse);
      expect(store.value.scopeFolderId, 'course');
    },
  );

  test(
    'failed settings write closes access and preserves saved authorization',
    () async {
      final store = _MemoryStore(
        ExternalAiPreferences(
          token: ExternalAiPreferences.generateToken(),
          port: await availablePort(),
        ),
      );
      final controller = ExternalAiController(store: store);
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await controller.initialize(LibraryService());
      await controller.update(controller.preferences!.copyWith(enabled: true));
      expect(controller.running, isTrue);
      store.rejectSave = true;
      await controller.update(
        controller.preferences!.copyWith(includeConversations: true),
      );
      expect(controller.running, isFalse);
      expect(store.value.includeConversations, isFalse);
      expect(controller.error, isNotNull);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'remembering an Agent preserves the running service and authorization',
    () async {
      final store = _MemoryStore(
        ExternalAiPreferences(
          token: ExternalAiPreferences.generateToken(),
          port: await availablePort(),
          enabled: true,
          scopeFolderId: 'course',
        ),
      );
      final controller = ExternalAiController(store: store);
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await controller.initialize(LibraryService());
      final server = controller.server;
      final endpoint = controller.endpoint;
      final token = controller.preferences!.token;
      expect(controller.running, isTrue);
      await controller.rememberClient(ExternalAiClient.workBuddy);
      expect(store.value.preferredClient, 'workBuddy');
      expect(controller.preferences!.preferredClient, 'workBuddy');
      expect(controller.server, same(server));
      expect(controller.running, isTrue);
      expect(controller.endpoint, endpoint);
      expect(controller.preferences!.token, token);
      expect(controller.preferences!.scopeFolderId, 'course');
      expect(controller.preferences!.includeConversations, isFalse);
      store.rejectSave = true;
      await controller.rememberClient(ExternalAiClient.codex);
      expect(controller.preferences!.preferredClient, 'workBuddy');
      expect(controller.server, same(server));
      expect(controller.running, isTrue);
      expect(controller.endpoint, endpoint);
      expect(controller.error, isNotNull);
    },
  );

  test(
    'diagnostic reports an uninitialized library rather than a successful read',
    () async {
      final store = _MemoryStore(
        ExternalAiPreferences(
          token: ExternalAiPreferences.generateToken(),
          port: await availablePort(),
        ),
      );
      final controller = ExternalAiController(store: store);
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      expect(LibraryService().isInitialized, isFalse);
      await controller.initialize(LibraryService());
      await controller.update(controller.preferences!.copyWith(enabled: true));
      await HttpOverrides.runWithHttpOverrides(
        controller.checkConnection,
        _RealHttpOverrides(),
      );
      expect(controller.diagnostic, isNotNull);
      expect(controller.diagnostic, contains('媒体库'));
      expect(controller.diagnostic, isNot(contains('连接正常，可提供')));
      expect(controller.busy, isFalse);
    },
  );

  Widget screen(
    _WidgetController controller, {
    double scale = 1,
    bool reducedMotion = false,
  }) => MaterialApp(
    theme: _appTheme(),
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reducedMotion,
      ),
      child: child!,
    ),
    home: ExternalAiScreen(controller: controller),
  );

  testWidgets(
    'first visit requires an Agent and remembers WorkBuddy on reopening',
    (tester) async {
      final controller = _WidgetController(
        preferredClient: null,
        promptFactory: (client) async => _longPrompt(client),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(screen(controller));
      await tester.pumpAndSettle();
      expect(controller.promptRequests, isEmpty);
      expect(
        find.byKey(const ValueKey('external-ai-copy-prompt')),
        findsNothing,
      );
      expect(find.byKey(_excerptKey), findsNothing);
      final selector = find.byKey(const ValueKey('external-ai-agent-selector'));
      expect(
        tester
            .widget<CapsuleDropdownButtonFormField<ExternalAiClient>>(selector)
            .initialValue,
        isNull,
      );

      await _selectAgent(tester, 'WorkBuddy');
      expect(controller.preferences!.preferredClient, 'workBuddy');
      expect(controller.promptRequests, [ExternalAiClient.workBuddy]);
      expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.workBuddy));
      expect(find.text('复制给 WorkBuddy 的提示词'), findsOneWidget);
      expect(
        find.text(externalAiClientActivationNotice(ExternalAiClient.workBuddy)),
        findsOneWidget,
      );
      final guide = find.text('2. 在 WorkBuddy 中完成连接');
      await _reveal(tester, guide);
      expect(
        find.byKey(const ValueKey('external-ai-client-steps')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      final steps = tester.widget<SelectableText>(
        find.byKey(const ValueKey('external-ai-client-steps')),
      );
      expect(
        steps.data,
        externalAiClientInfo(ExternalAiClient.workBuddy).steps,
      );
      expect(steps.data, contains('信任'));
      expect(steps.data, contains('开关'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(screen(controller));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CapsuleDropdownButtonFormField<ExternalAiClient>>(selector)
            .initialValue,
        ExternalAiClient.workBuddy,
      );
      expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.workBuddy));
      expect(controller.promptRequests, [
        ExternalAiClient.workBuddy,
        ExternalAiClient.workBuddy,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('small desktop window remains scrollable with large text', (
    tester,
  ) async {
    final controller = _WidgetController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 460), const Size(600, 320)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(screen(controller, scale: 1.5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('高级设置'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'missing authorized folder stays selected without widening access',
    (tester) async {
      final controller = _WidgetController(
        scopeFolderId: 'deleted-course-folder',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(screen(controller));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.preferences!.scopeFolderId, 'deleted-course-folder');
      final dropdown = tester.widget<CapsuleDropdownButtonFormField<String>>(
        find.byType(CapsuleDropdownButtonFormField<String>),
      );
      expect(dropdown.initialValue, 'deleted-course-folder');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'first connection requires an explicit Agent choice and remembers it',
    (tester) async {
      final controller = _WidgetController(preferredClient: null);
      addTearDown(controller.dispose);
      await tester.pumpWidget(screen(controller));
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('external-ai-agent-selector'));
      expect(
        tester
            .widget<CapsuleDropdownButtonFormField<ExternalAiClient>>(selector)
            .initialValue,
        isNull,
      );
      expect(controller.promptRequests, isEmpty);
      expect(find.byKey(_excerptKey), findsNothing);
      await _selectAgent(tester, 'Codex');
      expect(
        controller.preferences!.preferredClient,
        ExternalAiClient.codex.name,
      );
      expect(controller.promptRequests, [ExternalAiClient.codex]);
      expect(_excerpt(tester).data, '请连接播放器：codex ${controller.endpoint!}');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('copy connection config uses current endpoint and credential', (
    tester,
  ) async {
    final controller = _WidgetController();
    addTearDown(controller.dispose);
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
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(screen(controller));
    await tester.pumpAndSettle();
    await _selectAgent(tester, 'Codex');
    await tester.scrollUntilVisible(
      find.text('其他连接方式'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('其他连接方式'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('复制配置'));
    await tester.tap(find.text('复制配置'));
    await tester.pumpAndSettle();
    expect(copied, contains(controller.endpoint.toString()));
    expect(copied, contains(controller.preferences!.token));
    expect(find.textContaining('已复制连接配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'primary action copies Agent connection prompt without manual config',
    (tester) async {
      final controller = _WidgetController(
        promptFactory: (client) async => _longPrompt(client),
      );
      addTearDown(controller.dispose);
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
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await tester.pumpWidget(screen(controller));
      await tester.pumpAndSettle();
      await _selectAgent(tester, 'Codex');
      expect(find.text('复制配置'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('external-ai-copy-prompt')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('external-ai-copy-prompt')),
      );
      await tester.tap(find.byKey(const ValueKey('external-ai-copy-prompt')));
      await tester.pumpAndSettle();
      expect(copied, _longPrompt(ExternalAiClient.codex));
      expect(find.textContaining('已复制给 Codex 的完整提示词'), findsOneWidget);
      expect(find.text('复制配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('access switch and conversation checkbox are independent', (
    tester,
  ) async {
    final controller = _WidgetController(enabled: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(screen(controller));
    await tester.pumpAndSettle();
    expect(find.text('复制配置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('external-ai-read-access')));
    await tester.pumpAndSettle();
    expect(controller.preferences!.enabled, isTrue);
    expect(controller.preferences!.includeConversations, isFalse);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(controller.preferences!.includeConversations, isTrue);
    expect(controller.preferences!.enabled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long agent name remains usable in a narrow window', (
    tester,
  ) async {
    final controller = _WidgetController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 500));
    await tester.pumpWidget(screen(controller, scale: 1.5));
    await tester.pumpAndSettle();
    final selector = find.byType(
      CapsuleDropdownButtonFormField<ExternalAiClient>,
    );
    await tester.scrollUntilVisible(
      selector,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(selector), alignment: .3);
    await tester.pumpAndSettle();
    await tester.tap(selector);
    await tester.pumpAndSettle();
    final choice = find.text('其他支持 MCP 的 Agent');
    await tester.scrollUntilVisible(
      choice,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await Scrollable.ensureVisible(tester.element(choice), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('其他支持 MCP 的 Agent'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'connection preview follows Agent selection and resets expansion',
    (tester) async {
      final controller = _WidgetController(
        promptFactory: (client) async => _longPrompt(client),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(screen(controller, reducedMotion: true));
      await tester.pumpAndSettle();
      await _selectAgent(tester, 'Codex');
      expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.codex));
      expect(_excerpt(tester).maxLines, inInclusiveRange(4, 6));
      expect(find.byKey(_previewKey), findsNothing);
      final requestsBefore = controller.promptRequests.length;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(controller.promptRequests, hasLength(requestsBefore));
      await _reveal(tester, find.text('展开全文'));
      await tester.tap(find.text('展开全文'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byKey(_previewKey)).data,
        _longPrompt(ExternalAiClient.codex),
      );
      await _reveal(tester, find.text('收起'));
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.byKey(_previewKey), findsNothing);
      expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.codex));
      await _reveal(tester, find.text('展开全文'));
      await tester.tap(find.text('展开全文'));
      await tester.pumpAndSettle();
      await _selectAgent(tester, 'WorkBuddy');
      expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.workBuddy));
      expect(find.byKey(_previewKey), findsNothing);
      expect(controller.preferences!.includeConversations, isFalse);
      expect(controller.preferences!.scopeFolderId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late preview generation cannot overwrite newer authorization', (
    tester,
  ) async {
    final oldPrompt = Completer<String>();
    final newPrompt = Completer<String>();
    var generation = 0;
    final controller = _WidgetController(
      promptFactory: (_) =>
          generation++ == 0 ? oldPrompt.future : newPrompt.future,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(screen(controller));
    await tester.pump();
    expect(controller.promptRequests, hasLength(1));
    await controller.update(
      controller.preferences!.copyWith(includeConversations: true),
    );
    await tester.pump();
    expect(controller.promptRequests, hasLength(2));
    newPrompt.complete('已更新授权范围的连接提示词');
    await tester.pump();
    await tester.pump();
    oldPrompt.complete('旧授权范围的连接提示词');
    await tester.pumpAndSettle();
    expect(_excerpt(tester).data, '已更新授权范围的连接提示词');
    expect(find.text('旧授权范围的连接提示词'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled access discards pending preview and disposal is safe', (
    tester,
  ) async {
    final pending = Completer<String>();
    final controller = _WidgetController(promptFactory: (_) => pending.future);
    addTearDown(controller.dispose);
    await tester.pumpWidget(screen(controller));
    await tester.pump();
    await controller.update(controller.preferences!.copyWith(enabled: false));
    await tester.pump();
    pending.complete('关闭前尚未生成的旧提示词');
    await tester.pumpAndSettle();
    expect(find.byKey(_excerptKey), findsNothing);
    expect(find.byKey(_previewKey), findsNothing);
    expect(find.text('关闭前尚未生成的旧提示词'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closing the page during preview generation does not update disposed state',
    (tester) async {
      final pending = Completer<String>();
      final controller = _WidgetController(
        promptFactory: (_) => pending.future,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(screen(controller));
      await tester.pump();
      expect(controller.promptRequests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete('页面关闭后才完成的提示词');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop widths and system text scales keep access and prompt controls usable',
    (tester) async {
      final controller = _WidgetController(
        promptFactory: (client) async => _longPrompt(client),
      );
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final width in [320.0, 390.0, 768.0, 1280.0, 1600.0]) {
        for (final scale in [1.0, 1.5, 2.0]) {
          await tester.binding.setSurfaceSize(Size(width, 900));
          await tester.pumpWidget(screen(controller, scale: scale));
          await tester.pumpAndSettle();
          await _selectAgent(tester, 'Codex');
          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale',
          );
          expect(_excerpt(tester).data, _longPrompt(ExternalAiClient.codex));
          await _reveal(
            tester,
            find.byKey(const ValueKey('external-ai-copy-prompt')),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale after scrolling',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );

  testWidgets(
    'render dark Chinese connection previews across widths and text scales',
    (tester) async {
      final controller = _WidgetController(
        promptFactory: (client) async => _longPrompt(client),
      );
      final capture = GlobalKey();
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> save(String name) async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('.artifacts/external-ai/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }

      for (final width in [320.0, 390.0, 768.0, 1280.0, 1600.0]) {
        for (final scale in [1.0, 1.5, 2.0]) {
          await tester.binding.setSurfaceSize(Size(width, 1000));
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: _appTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: ExternalAiScreen(controller: controller),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _selectAgent(tester, 'Codex');
          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale',
          );
          final name =
              'connect-screen-${width.round()}-s${scale.toString().replaceAll('.', '_')}';
          await save(name);
          if ((width == 1280 || width == 390) && scale == 1) {
            final agentSelector = find.byKey(
              const ValueKey('external-ai-agent-selector'),
            );
            await _reveal(tester, agentSelector);
            await tester.tap(agentSelector);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await save('$name-agent-menu');
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            final scopeSelector = find.byType(
              CapsuleDropdownButtonFormField<String>,
            );
            await _reveal(tester, scopeSelector);
            await tester.tap(scopeSelector);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await save('$name-scope-menu');
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
          if (width == 1280 && scale == 1) await save('connect-screen');
          if (width == 390 && scale == 1) await save('connect-screen-narrow');
          if (width < 768) {
            await _reveal(tester, find.byKey(_excerptKey));
            await save('$name-prompt');
          }
          if ((width == 1280 || width == 390) && scale == 1) {
            await _reveal(tester, find.text('展开全文'));
            await tester.tap(find.text('展开全文'));
            await tester.pumpAndSettle();
            expect(
              tester.widget<SelectableText>(find.byKey(_previewKey)).data,
              _longPrompt(ExternalAiClient.codex),
            );
            await save('$name-expanded');
            if (width == 390) {
              await tester.drag(
                find.byType(Scrollable).first,
                const Offset(0, -650),
              );
              await tester.pumpAndSettle();
              await save('$name-expanded-end');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
    skip: !const bool.fromEnvironment('EXTERNAL_AI_PREVIEW'),
  );
}

ThemeData _appTheme() => ThemeData(
  brightness: Brightness.dark,
  primarySwatch: Colors.blue,
  scaffoldBackgroundColor: const Color(0xFF121212),
  fontFamily: 'Noto Sans SC',
  textTheme: appTextTheme(),
  colorScheme: const ColorScheme.dark(
    primary: Colors.blue,
    surface: Color(0xFF121212),
  ),
  useMaterial3: true,
);

const _excerptKey = ValueKey('external-ai-connection-excerpt');
const _previewKey = ValueKey('external-ai-connection-preview');

Text _excerpt(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_excerptKey));

String _longPrompt(ExternalAiClient client) => externalAiConnectionPrompt(
  client,
  setupFilePath:
      'D:\\用户资料\\学习课程与字幕文稿\\Fluent Player\\external_ai\\fluent-player-${client.name}-setup.json',
  serverName: 'fluent_player',
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await Scrollable.ensureVisible(tester.element(target), alignment: .3);
  await tester.pumpAndSettle();
}

Future<void> _selectAgent(WidgetTester tester, String label) async {
  final selector = find.byType(
    CapsuleDropdownButtonFormField<ExternalAiClient>,
  );
  final current = tester
      .widget<CapsuleDropdownButtonFormField<ExternalAiClient>>(selector)
      .initialValue;
  if (current != null && externalAiClientInfo(current).label == label) return;
  await _reveal(tester, selector);
  await tester.tap(selector);
  await tester.pumpAndSettle();
  final choice = find.text(label);
  await tester.scrollUntilVisible(
    choice,
    180,
    scrollable: find.byType(Scrollable).last,
  );
  await Scrollable.ensureVisible(tester.element(choice), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}
