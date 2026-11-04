import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _Source extends ExternalAiDataSource {
  int calls = 0;
  bool fail = false;
  bool plainResult = false;
  bool toolError = false;
  Completer<void>? hold;
  Completer<void>? started;
  String text = '完整中文文稿';

  @override
  List<Map<String, dynamic>> get tools => [
    {
      'name': 'read_transcript',
      'description': '读取文字资料',
      'inputSchema': {'type': 'object'},
    },
  ];

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    calls++;
    started?.complete();
    await hold?.future;
    if (fail) {
      throw const FileSystemException(
        'secret token and private path must not be disclosed',
        'C:/private/library/transcript.srt',
      );
    }
    if (plainResult) return {'text': text, 'hasMore': false};
    return {
      'isError': toolError,
      'content': [
        {'type': 'text', 'text': text},
      ],
      'structuredContent': {'text': text, 'offset': arguments['offset'] ?? 0},
    };
  }
}

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

Map<String, dynamic> _rpc(
  String method, {
  Object id = 1,
  Map<String, dynamic>? params,
}) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loopback MCP transport', () {
    late _Source source;
    late ExternalAiServer server;
    late HttpClient client;
    late Uri endpoint;

    setUp(() async {
      source = _Source();
      server = ExternalAiServer(dataSource: source, token: _token);
      endpoint = await server.start();
      client = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _RealHttpOverrides(),
      );
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    Future<(int, Object?)> send(
      Object? body, {
      String method = 'POST',
      String? token = _token,
      String? origin,
      String? host,
      String? version,
      String path = '/mcp',
      ContentType? contentType,
      bool raw = false,
      bool connectionCheck = false,
    }) async {
      final request = await client.openUrl(
        method,
        endpoint.replace(path: path),
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (origin != null) request.headers.set('origin', origin);
      if (host != null) request.headers.set('host', host);
      if (version != null) request.headers.set('MCP-Protocol-Version', version);
      if (connectionCheck) {
        request.headers.set(ExternalAiServer.connectionCheckHeader, 'true');
      }
      if (body != null) {
        request.headers.contentType = contentType ?? ContentType.json;
        request.write(raw ? body : jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      // The UI notification follows HttpResponse.close's completion on the
      // server, which can run just after the client receives the final byte.
      await Future<void>.delayed(Duration.zero);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    }

    test(
      'binds IPv4 loopback and repeated start retains its endpoint',
      () async {
        expect(endpoint.host, '127.0.0.1');
        expect(await server.start(), endpoint);
        expect(server.isRunning, isTrue);
        expect(source.calls, 0);
      },
    );

    test('requires the exact bearer token before listing or reading', () async {
      expect((await send(_rpc('tools/list'), token: null)).$1, 401);
      expect((await send(_rpc('tools/list'), token: 'wrong')).$1, 401);
      expect(source.calls, 0);
      expect(server.requestCount, 0);
    });

    test('rejects hostile origins and rebound host names', () async {
      expect(
        (await send(_rpc('ping'), origin: 'https://attacker.example')).$1,
        403,
      );
      expect((await send(_rpc('ping'), origin: 'null')).$1, 403);
      expect((await send(_rpc('ping'), origin: 'http://localhost:1')).$1, 403);
      expect((await send(_rpc('ping'), host: 'attacker.example')).$1, 403);
      expect(server.requestCount, 0);
      expect(
        (await send(
          _rpc('ping'),
          origin: 'http://localhost:${endpoint.port}',
        )).$1,
        200,
      );
    });

    test(
      'negotiates supported versions and publishes read-only tools',
      () async {
        for (final version in ExternalAiServer.supportedProtocolVersions) {
          final response = await send(
            _rpc('initialize', params: {'protocolVersion': version}),
          );
          final result = (response.$2 as Map)['result'] as Map;
          expect(result['protocolVersion'], version);
          expect((result['capabilities'] as Map).keys, ['tools']);
        }
        final fallback = await send(
          _rpc('initialize', params: {'protocolVersion': 'future-version'}),
        );
        expect(
          ((fallback.$2 as Map)['result'] as Map)['protocolVersion'],
          ExternalAiServer.supportedProtocolVersions.last,
        );
        final response = await send(_rpc('tools/list'));
        final tool =
            (((response.$2 as Map)['result'] as Map)['tools'] as List).single
                as Map;
        expect((tool['annotations'] as Map)['readOnlyHint'], isTrue);
        expect((tool['annotations'] as Map)['destructiveHint'], isFalse);
        expect(server.lastRequestAt, isNotNull);
      },
    );

    test(
      'notifications accepted, GET unsupported, unknown methods fail',
      () async {
        final notification = await send({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        });
        expect(notification, (202, null));
        expect((await send(null, method: 'GET')).$1, 405);
        expect((await send(_rpc('ping'), path: '/other')).$1, 404);
        final unknown = await send(_rpc('delete_media'));
        expect(((unknown.$2 as Map)['error'] as Map)['code'], -32601);
        expect(source.calls, 0);
      },
    );

    test('validates format, body size and protocol headers', () async {
      final invalid = await send('[', raw: true);
      expect(((invalid.$2 as Map)['error'] as Map)['code'], -32700);
      final array = await send([_rpc('ping')]);
      expect(((array.$2 as Map)['error'] as Map)['code'], -32600);
      expect(
        (await send(_rpc('ping'), version: 'unsupported-version')).$1,
        400,
      );
      expect((await send(_rpc('ping'), contentType: ContentType.text)).$1, 415);
      final huge = await send('x' * (server.maxRequestBytes + 1), raw: true);
      expect(huge.$1, 413);
      expect(source.calls, 0);
    });

    test(
      'dispatches known queries and never dispatches unknown tools',
      () async {
        final response = await send(
          _rpc(
            'tools/call',
            params: {
              'name': 'read_transcript',
              'arguments': {'offset': 120},
            },
          ),
        );
        final result = (response.$2 as Map)['result'] as Map;
        expect((result['structuredContent'] as Map)['offset'], 120);
        expect((result['structuredContent'] as Map)['text'], '完整中文文稿');
        final unknown = await send(
          _rpc('tools/call', params: {'name': 'delete_media'}),
        );
        expect(((unknown.$2 as Map)['error'] as Map)['code'], -32602);
        expect(source.calls, 1);
      },
    );

    test(
      'provider failures do not disclose private paths or credentials',
      () async {
        source.fail = true;
        final response = await send(
          _rpc('tools/call', params: {'name': 'read_transcript'}),
        );
        expect(((response.$2 as Map)['result'] as Map)['isError'], isTrue);
        expect(jsonEncode(response.$2), isNot(contains('C:/private')));
        expect(jsonEncode(response.$2), isNot(contains('secret token')));
      },
    );

    test('only successful external tool responses verify access', () async {
      final call = _rpc('tools/call', params: {'name': 'read_transcript'});
      await send(_rpc('initialize'));
      await send(_rpc('tools/list'));
      await send(_rpc('ping'));
      await send(call, connectionCheck: true);
      await send(call, token: 'wrong');
      await send(_rpc('tools/call', params: {'name': 'missing_tool'}));
      source.fail = true;
      await send(call);
      source.fail = false;
      source.toolError = true;
      await send(call);
      expect(server.externalToolCallCount, 0);
      expect(server.lastExternalToolCallAt, isNull);

      source.toolError = false;
      await send(call);
      expect(server.externalToolCallCount, 1);
      expect(server.lastExternalToolCallAt, isNotNull);
      await send(_rpc('tools/list'));
      await send(call, connectionCheck: true);
      expect(server.externalToolCallCount, 1);
      await send(call);
      expect(server.externalToolCallCount, 2);
      await server.stop();
      expect(server.externalToolCallCount, 0);
      expect(server.lastExternalToolCallAt, isNull);
      endpoint = await server.start();
      expect(server.externalToolCallCount, 0);
      expect(server.lastExternalToolCallAt, isNull);
    });

    test(
      'domain JSON has both structured and textual MCP representations',
      () async {
        source.plainResult = true;
        final response = await send(
          _rpc('tools/call', params: {'name': 'read_transcript'}),
        );
        final result = (response.$2 as Map)['result'] as Map;
        expect(result['isError'], isFalse);
        expect((result['structuredContent'] as Map)['text'], '完整中文文稿');
        final text =
            ((result['content'] as List).single as Map)['text'] as String;
        expect(jsonDecode(text), result['structuredContent']);
      },
    );

    test('oversized responses explicitly require bounded reads', () async {
      await server.stop();
      server = ExternalAiServer(
        dataSource: source,
        token: _token,
        maxResponseBytes: 1024,
      );
      endpoint = await server.start();
      source.text = '文稿' * 2000;
      final response = await send(
        _rpc('tools/call', params: {'name': 'read_transcript'}),
      );
      expect(((response.$2 as Map)['error'] as Map)['code'], -32001);
      expect((response.$2 as Map).containsKey('result'), isFalse);
      expect(server.externalToolCallCount, 0);
      expect(server.lastExternalToolCallAt, isNull);
    });

    test(
      'revoking a listener closes already pending reads before returning data',
      () async {
        source.hold = Completer<void>();
        source.started = Completer<void>();
        source.text = 'revoked private document';
        final request = await client.postUrl(endpoint);
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        request.write(
          jsonEncode(_rpc('tools/call', params: {'name': 'read_transcript'})),
        );
        final responseText = request
            .close()
            .then(utf8.decodeStream)
            .catchError((Object _) => 'connection closed');
        await source.started!.future;
        await server.stop();
        source.hold!.complete();
        expect(await responseText, isNot(contains('revoked private document')));
        expect(server.isRunning, isFalse);
        expect(server.externalToolCallCount, 0);
        expect(server.lastExternalToolCallAt, isNull);
      },
    );

    test('stop closes listener and server can explicitly restart', () async {
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(server.endpoint, isNull);
      endpoint = await server.start();
      expect((await send(_rpc('ping'))).$1, 200);
    });
  });

  group('external access preferences', () {
    late Directory root;
    late ExternalAiPreferencesStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('external-ai-preferences-');
      store = ExternalAiPreferencesStore(root: root);
    });

    tearDown(() async => root.delete(recursive: true));

    test(
      'default off, strong stable credential and independent scope',
      () async {
        final initial = await store.load();
        expect(initial.enabled, isFalse);
        expect(initial.includeConversations, isFalse);
        expect(initial.port, ExternalAiPreferences.defaultPort);
        expect(initial.token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect((await store.load()).token, initial.token);
        await store.save(
          initial.copyWith(enabled: true, scopeFolderId: 'course-folder'),
        );
        final reloaded = await store.load();
        expect(reloaded.enabled, isTrue);
        expect(reloaded.scopeFolderId, 'course-folder');
        expect(reloaded.token, initial.token);
        expect(
          reloaded.copyWith(clearScopeFolderId: true).scopeFolderId,
          isNull,
        );
        expect(ExternalAiPreferences.generateToken(), isNot(initial.token));
      },
    );

    test(
      'invalid persisted settings preserved without silently rotating token',
      () async {
        await store.load();
        final file = (await root.list(recursive: true).toList())
            .whereType<File>()
            .single;
        await file.writeAsString('{broken settings');
        await expectLater(store.load(), throwsFormatException);
        expect(await file.readAsString(), '{broken settings');
      },
    );

    test('invalid saves do not overwrite a valid access setup', () async {
      final initial = await store.load();
      expect(
        () => store.save(initial.copyWith(port: 0)),
        throwsFormatException,
      );
      expect((await store.load()).token, initial.token);
      expect((await store.load()).port, initial.port);
    });
  });
}
