import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../services/library_service.dart';
import '../../services/media_playback_service.dart';
import '../../services/transcription_manager.dart';
import '../../services/subtitle_translate_settings.dart';
import '../../utils/app_data_paths.dart';
import 'external_ai_library_source.dart';
import 'external_ai_preferences.dart';
import 'external_ai_server.dart';
import 'external_ai_clients.dart';
import 'external_ai_playback_source.dart';
import 'external_ai_actions.dart';
import 'external_ai_action_backend.dart';
import 'external_ai_action_store.dart';
import 'external_ai_approvals.dart';
import 'external_ai_preparation.dart';
import 'external_ai_document_backend.dart';

class ExternalAiController extends ChangeNotifier {
  ExternalAiController({ExternalAiPreferencesStore? store})
    : store = store ?? ExternalAiPreferencesStore();
  static final instance = ExternalAiController();
  final ExternalAiPreferencesStore store;
  ExternalAiPreferences? preferences;
  ExternalAiServer? server;
  ExternalAiDataSource? _source;
  ExternalAiActions? _actions;
  ExternalAiPreparation? _preparation;
  ExternalAiApprovals? approvals;
  SubtitleTranslateSettings? _translationSettings;
  TranscriptionManager? _transcriptionManager;
  int _accessGeneration = 0;
  void attachTranscriptionManager(
    TranscriptionManager manager, {
    SubtitleTranslateSettings? translationSettings,
  }) {
    _transcriptionManager = manager;
    _translationSettings = translationSettings;
  }

  Future<void>? _initializing;
  bool busy = false;
  String? error;
  String? diagnostic;
  bool get running => server?.isRunning == true;
  Uri? get endpoint => server?.endpoint;
  DateTime? get lastExternalToolCallAt =>
      running ? server?.lastExternalToolCallAt : null;
  int get externalToolCallCount =>
      running ? server?.externalToolCallCount ?? 0 : 0;
  Future<void> initialize(LibraryService library) =>
      _initializing ??= _initialize(library);
  Future<void> _initialize(LibraryService library) async {
    if (!ExternalAiPreferences.isDesktopSupported) return;
    try {
      preferences = await store.load();
      final reader = ExternalAiLibrarySource.fromLibrary(
        library,
        scopeFolder: () => preferences?.scopeFolderId,
        conversationsAllowed: () => preferences?.includeConversations == true,
        playback: () => externalAiPlaybackSnapshot(MediaPlaybackService()),
      );
      _source = reader;
      final manager = _transcriptionManager;
      if (manager != null) {
        try {
          await manager.initialize();
          final root = store.root ?? await resolveAppDataDirectory();
          approvals = ExternalAiApprovals(
            store: ExternalAiActionStore(root, name: 'approvals-v1'),
            preferences: () => preferences,
          );
          await approvals!.initialize();
          approvals!.addListener(notifyListeners);
          final backend = ExternalAiPlayerBackend(
            library: library,
            manager: manager,
            translationSettings: _translationSettings,
          );
          _preparation = ExternalAiPreparation(
            library: reader,
            documents: ExternalAiDocumentBackend(library: library),
            processing: backend,
            approvals: approvals!,
            store: ExternalAiActionStore(root, name: 'preparation-v1'),
            preferences: () => preferences,
            generation: () => _accessGeneration,
          );
          await _preparation!.initialize();
          _actions = ExternalAiActions(
            library: reader,
            backend: backend,
            approvals: approvals,
            store: ExternalAiActionStore(
              store.root ?? await resolveAppDataDirectory(),
            ),
            preferences: () => preferences,
            generation: () => _accessGeneration,
          );
          try {
            await _actions!.initialize();
          } catch (_) {
            error = '外部 AI 操作历史无法读取，资料读取仍可用；原记录已保留。';
          }
          _source = ExternalAiApplicationSource(
            reader,
            _actions!,
            _preparation,
          );
        } catch (_) {
          error = '外部 AI 操作记录无法读取，资料读取仍可用；原记录已保留。';
          _source = reader;
        }
      } else {
        _source = reader;
      }
      if (preferences!.enabled) await _start();
    } catch (_) {
      error = '连接设置载入失败，原文件已保留。';
    }
    notifyListeners();
  }

  Future<void> _start() async {
    final settings = preferences!;
    server = ExternalAiServer(
      dataSource: _source!,
      token: settings.token,
      serverName: kAppDataFolderName.endsWith('Community')
          ? 'fluent_player_community'
          : 'fluent_player',
      onRequest: notifyListeners,
    );
    await server!.start(port: settings.port);
  }

  Future<void> update(ExternalAiPreferences next) async {
    if (busy || _source == null) return;
    busy = true;
    _accessGeneration++;
    error = null;
    diagnostic = null;
    notifyListeners();
    try {
      await server?.stop();
      await store.save(next);
      preferences = next;
      if (next.enabled) await _start();
    } on SocketException {
      error = '连接端口被占用，请在高级设置中换一个端口后重试。';
    } catch (_) {
      error = '连接设置未能应用，请检查存储位置后重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> checkConnection() async {
    if (!running || busy) return;
    busy = true;
    diagnostic = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      Future<Map<String, dynamic>> rpc(String method, int id) async {
        final request = await client.postUrl(endpoint!);
        request.headers.set(ExternalAiServer.connectionCheckHeader, 'true');
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${preferences!.token}',
        );
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/json, text/event-stream',
        );
        request.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            if (method == 'tools/call')
              'params': {
                'name': 'player_overview',
                'arguments': <String, dynamic>{},
              },
            if (method == 'initialize')
              'params': {
                'protocolVersion': '2025-11-25',
                'capabilities': {},
                'clientInfo': {
                  'name': 'player-connection-check',
                  'version': '1',
                },
              },
          }),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        final data =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        if (response.statusCode != 200 || data['error'] != null) {
          throw StateError('check');
        }
        return data;
      }

      await rpc('initialize', 1);
      final list = await rpc('tools/list', 2);
      final overview = await rpc('tools/call', 3);
      if (overview['result']['isError'] == true) {
        diagnostic = '服务已连接，媒体库正在加载或当前资料不可读取，请稍后重试。';
        return;
      }
      diagnostic =
          '播放器连接正常，可提供 ${(list['result']['tools'] as List).length} 项已授权工具。请在 Agent 中提问完成最终验证。';
    } catch (_) {
      diagnostic = '连接检测失败，请重新启用后重试。';
    } finally {
      client.close(force: true);
      busy = false;
      notifyListeners();
    }
  }

  Future<void> rememberClient(ExternalAiClient client) async {
    final current = preferences;
    if (busy || current == null || current.preferredClient == client.name) {
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final next = current.copyWith(preferredClient: client.name);
      await store.save(next);
      preferences = next;
    } catch (_) {
      error = '未能记住所选助手，请检查存储位置。当前读取权限未变。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Copyable instructions contain only the path. The credential stays in an
  /// app-owned local file, separate from exported conversations and settings.
  Future<String> connectionPrompt(ExternalAiClient client) async {
    if (!running || preferences == null) {
      throw StateError('请先开启外部 AI 连接');
    }
    final root = store.root ?? await resolveAppDataDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}external_ai',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}$kAppDataFolderName-${client.name}-setup.json',
    );
    final name = kAppDataFolderName.endsWith('Community')
        ? 'fluent_player_community'
        : 'fluent_player';
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'application': kAppDataFolderName,
        'client': client.name,
        'serverName': name,
        'endpoint': endpoint.toString(),
        'readOnly':
            !preferences!.allowTaskControl && !preferences!.allowSubtitleWrite,
        'permissions': {
          'taskControl': preferences!.allowTaskControl,
          'subtitleWrite': preferences!.allowSubtitleWrite,
          'mediaFiles': false,
          'autoTaskDecisions': preferences!.autoTaskDecisions,
          'autoModelDownloads': preferences!.autoModelDownloads,
          'autoRemoteProcessing': preferences!.autoRemoteProcessing,
        },
        'configuration': externalAiClientConfiguration(
          client,
          endpoint: endpoint!,
          token: preferences!.token,
          serverName: name,
        ),
      }),
      flush: true,
    );
    return externalAiConnectionPrompt(
      client,
      setupFilePath: file.absolute.path,
      serverName: name,
    );
  }

  Future<void> shutdown() async {
    _accessGeneration++;
    await server?.stop();
    await _preparation?.shutdown();
    approvals?.removeListener(notifyListeners);
    await _actions?.shutdown();
  }
}
