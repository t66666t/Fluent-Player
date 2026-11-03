import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

class _RealHttpOverrides extends HttpOverrides {}

HttpClient _client() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttpOverrides());

const _messages = <Map<String, String>>[
  {'role': 'system', 'content': '原始视频资料'},
  {'role': 'user', 'content': '请解释这段视频'},
];

Map<String, dynamic> _chunk({
  String? content,
  String? reasoning,
  String? finish,
  Map<String, dynamic>? usage,
}) => {
  'choices': [
    {
      'delta': {'content': ?content, 'reasoning_content': ?reasoning},
      'finish_reason': finish,
    },
  ],
  'usage': ?usage,
};

String _frame(Map<String, dynamic> value) => 'data: ${jsonEncode(value)}\n\n';

Future<void> _sse(
  HttpRequest request,
  List<Map<String, dynamic>> events,
) async {
  request.response.headers.set('content-type', 'text/event-stream');
  request.response.add(utf8.encode(events.map(_frame).join()));
  await request.response.close();
}

AiChatSettings _settings(
  HttpServer server, {
  AiApiProtocol protocol = AiApiProtocol.openAiCompatible,
}) => AiChatSettings(
  baseUrl: 'http://127.0.0.1:${server.port}',
  apiProtocol: protocol,
  apiKey: 'local-test-key',
  model: switch (protocol) {
    AiApiProtocol.anthropic => 'claude-test',
    AiApiProtocol.gemini => 'gemini-2.5-flash',
    _ => 'deepseek-chat',
  },
);

AiChatTransport _transport({
  List<Duration> delays = const [Duration.zero, Duration.zero],
  Duration idleTimeout = const Duration(seconds: 3),
}) => AiChatTransport(
  httpClientFactory: _client,
  networkRetryDelays: delays,
  idleTimeout: idleTimeout,
);

String _text(List<AiChatDelta> deltas, {bool reasoning = false}) {
  final result = StringBuffer();
  for (final delta in deltas) {
    final snapshot = reasoning
        ? delta.reasoningSnapshot
        : delta.contentSnapshot;
    if (snapshot != null) result.clear();
    result.write(snapshot ?? (reasoning ? delta.reasoning : delta.content));
  }
  return result.toString();
}

Future<HttpServer> _server() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  return server;
}

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(videoId: video.id, title: video.title);
}

Future<(AiChatController, AiConversationStore)> _controller(
  HttpServer server,
  AiChatTransport transport,
) async {
  final directory = await Directory.systemTemp.createTemp('ai_reconnect_test_');
  final store = AiConversationStore(root: directory);
  final controller = AiChatController(
    video: VideoItem(
      id: 'reconnect',
      path: 'local.mp4',
      title: '视频',
      durationMs: 3000,
      lastUpdated: 1,
    ),
    transport: transport,
    conversationStore: store,
    contextLoader: _Loader(),
    initialSettings: _settings(server),
  );
  addTearDown(() async {
    controller.dispose();
    await store.load(controller.video.id);
    await directory.delete(recursive: true);
  });
  await controller.initialize();
  await controller.renameConversation(controller.active!.id, '网络恢复测试');
  return (controller, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'truncated SSE regenerates the same request without duplicate text or usage',
    () async {
      final server = await _server();
      final bodies = <Map<String, dynamic>>[];
      server.listen((request) async {
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        await _sse(
          request,
          bodies.length == 1
              ? [
                  _chunk(
                    content: '旧回答的一半',
                    reasoning: '旧思考',
                    usage: {
                      'prompt_tokens': 10,
                      'completion_tokens': 3,
                      'total_tokens': 13,
                    },
                  ),
                ]
              : [
                  _chunk(reasoning: '新的思考'),
                  _chunk(content: '新的'),
                  _chunk(content: '完整回答'),
                  _chunk(
                    finish: 'stop',
                    usage: {
                      'prompt_tokens': 10,
                      'completion_tokens': 5,
                      'total_tokens': 15,
                    },
                  ),
                ],
        );
      });
      final deltas = await _transport()
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(bodies, hasLength(2));
      expect(bodies[1], bodies[0]);
      expect(_text(deltas), '新的完整回答');
      expect(_text(deltas, reasoning: true), '新的思考');
      expect(deltas.where((d) => d.reconnecting == true), hasLength(1));
      expect(deltas.where((d) => d.reconnecting == false), isNotEmpty);
      expect(
        deltas.where((d) => d.usage != null).last.usage!['total_tokens'],
        28,
      );
    },
  );

  test('new clients recover connection failures before any response', () async {
    final server = await _server();
    server.listen((request) async {
      await request.drain<void>();
      await _sse(request, [_chunk(content: '恢复成功', finish: 'stop')]);
    });
    var clients = 0;
    final transport = AiChatTransport(
      networkRetryDelays: const [Duration.zero, Duration.zero],
      httpClientFactory: () {
        if (++clients <= 2) {
          throw const SocketException('Network is unreachable');
        }
        return _client();
      },
    );
    final deltas = await transport
        .stream(
          settings: _settings(server),
          messages: _messages,
          cancellation: AiChatCancellation(),
        )
        .toList();
    expect(clients, 3);
    expect(_text(deltas), '恢复成功');
  });

  test('idle stream timeout reconnects instead of ending the answer', () async {
    final server = await _server();
    var attempts = 0;
    server.listen((request) async {
      await request.drain<void>();
      if (++attempts == 1) {
        request.response.bufferOutput = false;
        request.response.headers.set('content-type', 'text/event-stream');
        request.response.add(utf8.encode(_frame(_chunk(content: '超时残稿'))));
        await request.response.flush();
      } else {
        await _sse(request, [_chunk(content: '恢复后的回答', finish: 'stop')]);
      }
    });
    final deltas =
        await _transport(idleTimeout: const Duration(milliseconds: 100))
            .stream(
              settings: _settings(server),
              messages: _messages,
              cancellation: AiChatCancellation(),
            )
            .toList();
    expect(attempts, 2);
    expect(_text(deltas), '恢复后的回答');
  });

  test(
    'destroyed TCP stream is retried after preserving its partial text',
    () async {
      final server = await _server();
      final partialReceived = Completer<void>();
      var attempts = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (++attempts == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          final payload = utf8.encode(_frame(_chunk(content: '连接重置前的回答')));
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n'
              'Content-Length: ${payload.length + 1024}\r\n\r\n',
            ),
          );
          socket.add(payload);
          await socket.flush();
          await partialReceived.future;
          socket.destroy();
        } else {
          await _sse(request, [_chunk(content: '重新连接后的完整回答', finish: 'stop')]);
        }
      });
      final deltas = <AiChatDelta>[];
      await _transport()
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .forEach((delta) {
            deltas.add(delta);
            if (delta.content == '连接重置前的回答') partialReceived.complete();
          });
      expect(attempts, 2);
      expect(_text(deltas), '重新连接后的完整回答');
    },
  );

  test(
    'persistent failures stop at the retry limit and retain the latest partial',
    () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        await request.drain<void>();
        await _sse(request, [_chunk(content: '残稿 ${++attempts}')]);
      });
      final deltas = <AiChatDelta>[];
      await expectLater(
        _transport()
            .stream(
              settings: _settings(server),
              messages: _messages,
              cancellation: AiChatCancellation(),
            )
            .forEach(deltas.add),
        throwsA(
          isA<AiChatException>().having(
            (e) => e.message,
            'bounded failure',
            contains('已自动重试 2 次'),
          ),
        ),
      );
      expect(attempts, 3);
      expect(_text(deltas), '残稿 3');
    },
  );

  test(
    'stop during backoff finishes immediately without another request',
    () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        attempts++;
        await request.drain<void>();
        await _sse(request, [_chunk(content: '已收到的回答')]);
      });
      final reconnecting = Completer<void>();
      final cancellation = AiChatCancellation();
      final deltas = <AiChatDelta>[];
      final pending = _transport(delays: const [Duration(minutes: 1)])
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: cancellation,
          )
          .forEach((delta) {
            deltas.add(delta);
            if (delta.reconnecting == true) reconnecting.complete();
          });
      await reconnecting.future;
      cancellation.cancel();
      await pending.timeout(const Duration(seconds: 1));
      expect(attempts, 1);
      expect(_text(deltas), '已收到的回答');
    },
  );

  for (final status in [408, 500, 502, 503, 504]) {
    test('temporary HTTP $status recovers with a new request', () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (++attempts == 1) {
          request.response.statusCode = status;
          await request.response.close();
        } else {
          await _sse(request, [_chunk(content: 'OK', finish: 'stop')]);
        }
      });
      final deltas = await _transport()
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(attempts, 2);
      expect(_text(deltas), 'OK');
    });
  }

  for (final status in [400, 401, 402, 403, 404, 429]) {
    test(
      'HTTP $status requires a user fix and is not repeatedly submitted',
      () async {
        final server = await _server();
        var attempts = 0;
        server.listen((request) async {
          attempts++;
          await request.drain<void>();
          request.response.statusCode = status;
          await request.response.close();
        });
        await expectLater(
          _transport()
              .stream(
                settings: _settings(server),
                messages: _messages,
                cancellation: AiChatCancellation(),
              )
              .toList(),
          throwsA(
            isA<AiChatException>().having(
              (e) => e.statusCode,
              'HTTP status',
              status,
            ),
          ),
        );
        expect(attempts, 1);
      },
    );
  }

  test('malformed events are reported without network retries', () async {
    final server = await _server();
    var attempts = 0;
    server.listen((request) async {
      attempts++;
      await request.drain<void>();
      request.response.write('data: broken json\n\n');
      await request.response.close();
    });
    await expectLater(
      _transport()
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList(),
      throwsA(
        isA<AiChatException>().having(
          (e) => e.message,
          'parse error',
          contains('JSON'),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test('certificate errors are not retried', () async {
    var attempts = 0;
    final transport = AiChatTransport(
      httpClientFactory: () {
        attempts++;
        throw const HandshakeException('certificate verification failed');
      },
    );
    await expectLater(
      transport
          .stream(
            settings: const AiChatSettings(),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList(),
      throwsA(
        isA<AiChatException>().having(
          (e) => e.message,
          'certificate',
          contains('证书'),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test(
    'a network interruption during TLS setup recovers with a fresh connection',
    () async {
      final server = await _server();
      server.listen((request) async {
        await request.drain<void>();
        await _sse(request, [_chunk(content: '连接恢复', finish: 'stop')]);
      });
      var clients = 0;
      final transport = AiChatTransport(
        networkRetryDelays: const [Duration.zero],
        httpClientFactory: () {
          if (++clients == 1) {
            throw const HandshakeException(
              'Connection terminated during handshake',
            );
          }
          return _client();
        },
      );
      final deltas = await transport
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(clients, 2);
      expect(_text(deltas), '连接恢复');
    },
  );

  for (final splitUtf8 in [false, true]) {
    test(
      'recovers EOF in the middle of ${splitUtf8 ? 'a UTF8 character' : 'an SSE frame'}',
      () async {
        final server = await _server();
        var attempts = 0;
        server.listen((request) async {
          await request.drain<void>();
          if (++attempts == 1) {
            request.response.headers.set('content-type', 'text/event-stream');
            request.response.add(utf8.encode(_frame(_chunk(content: '部分输出'))));
            request.response.add(
              utf8.encode('data: {"choices":[{"delta":{"content":"'),
            );
            if (splitUtf8) {
              request.response.add(utf8.encode('中').take(1).toList());
            }
            await request.response.close();
          } else {
            await _sse(request, [_chunk(content: '完整输出', finish: 'stop')]);
          }
        });
        final deltas = await _transport()
            .stream(
              settings: _settings(server),
              messages: _messages,
              cancellation: AiChatCancellation(),
            )
            .toList();
        expect(attempts, 2);
        expect(_text(deltas), '完整输出');
      },
    );
  }

  for (final protocol in AiApiProtocol.values) {
    test(
      '${protocol.name} retries structured server errors inside SSE',
      () async {
        final server = await _server();
        var attempts = 0;
        server.listen((request) async {
          await request.drain<void>();
          if (++attempts == 1) {
            await _sse(request, [
              {
                'error': {
                  'type': 'overloaded_error',
                  'message': 'Temporarily overloaded',
                },
              },
            ]);
            return;
          }
          await _sse(request, switch (protocol) {
            AiApiProtocol.anthropic => [
              {
                'type': 'content_block_delta',
                'delta': {'type': 'text_delta', 'text': '恢复'},
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'end_turn'},
              },
              {'type': 'message_stop'},
            ],
            AiApiProtocol.gemini => [
              {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': '恢复'},
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
              },
            ],
            _ => [_chunk(content: '恢复', finish: 'stop')],
          });
        });
        final deltas = await _transport()
            .stream(
              settings: _settings(server, protocol: protocol),
              messages: _messages,
              cancellation: AiChatCancellation(),
            )
            .toList();
        expect(attempts, 2);
        expect(_text(deltas), '恢复');
      },
    );
  }

  test(
    'cancelling a retry does not cancel another conversation on the same transport',
    () async {
      final server = await _server();
      final release = Completer<void>();
      final waiting = Completer<void>();
      final otherStarted = Completer<void>();
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if ((body['messages'] as List).last['content'] == '保持这条回答') {
          otherStarted.complete();
          await release.future;
          await _sse(request, [_chunk(content: '另一条回答完成', finish: 'stop')]);
        } else {
          await _sse(request, [_chunk(content: '第一条残稿')]);
        }
      });
      final transport = _transport(delays: const [Duration(minutes: 1)]);
      final cancellation = AiChatCancellation();
      final first = transport
          .stream(
            settings: _settings(server),
            messages: _messages,
            cancellation: cancellation,
          )
          .forEach((delta) {
            if (delta.reconnecting == true) waiting.complete();
          });
      final other = transport
          .stream(
            settings: _settings(server),
            messages: const [
              {'role': 'user', 'content': '保持这条回答'},
            ],
            cancellation: AiChatCancellation(),
          )
          .toList();
      await Future.wait([waiting.future, otherStarted.future]);
      cancellation.cancel();
      await first.timeout(const Duration(seconds: 1));
      release.complete();
      expect(_text(await other), '另一条回答完成');
    },
  );

  for (final protocol in [AiApiProtocol.anthropic, AiApiProtocol.gemini]) {
    test('${protocol.name} recovers an incomplete native stream', () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        await request.drain<void>();
        final first = ++attempts == 1;
        await _sse(
          request,
          protocol == AiApiProtocol.anthropic
              ? [
                  {
                    'type': 'content_block_delta',
                    'delta': {
                      'type': 'text_delta',
                      'text': first ? '半条回答' : '完整回答',
                    },
                  },
                  if (!first)
                    {
                      'type': 'message_delta',
                      'delta': {'stop_reason': 'end_turn'},
                    },
                  if (!first) {'type': 'message_stop'},
                ]
              : [
                  {
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {'text': first ? '半条回答' : '完整回答'},
                          ],
                        },
                        if (!first) 'finishReason': 'STOP',
                      },
                    ],
                  },
                ],
        );
      });
      final deltas = await _transport()
          .stream(
            settings: _settings(server, protocol: protocol),
            messages: _messages,
            cancellation: AiChatCancellation(),
          )
          .toList();
      expect(attempts, 2);
      expect(_text(deltas), '完整回答');
    });
  }

  test(
    'a finished response does not regenerate when only its trailer is dropped',
    () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        attempts++;
        await request.drain<void>();
        request.response.bufferOutput = false;
        request.response.headers.set('content-type', 'text/event-stream');
        request.response.add(
          utf8.encode(_frame(_chunk(content: '已完成', finish: 'stop'))),
        );
        await request.response.flush();
        // Leave the usage trailer open until the stream's idle timeout.
      });
      final deltas =
          await _transport(idleTimeout: const Duration(milliseconds: 100))
              .stream(
                settings: _settings(server),
                messages: _messages,
                cancellation: AiChatCancellation(),
              )
              .toList();
      expect(attempts, 1);
      expect(_text(deltas), '已完成');
    },
  );

  test(
    'successful empty retry cannot label an old partial answer complete',
    () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        await request.drain<void>();
        await _sse(
          request,
          ++attempts == 1 ? [_chunk(content: '旧残稿')] : [_chunk(finish: 'stop')],
        );
      });
      final (controller, _) = await _controller(server, _transport());
      await controller.send('问题');
      expect(attempts, 2);
      expect(controller.active!.messages.last.status, 'error');
      expect(controller.active!.messages.last.content, isEmpty);
      expect(controller.error, contains('空回答'));
    },
  );

  test(
    'controller keeps one live turn and persists the recovered answer',
    () async {
      final server = await _server();
      var attempts = 0;
      final bodies = <Map<String, dynamic>>[];
      server.listen((request) async {
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        await _sse(
          request,
          ++attempts == 1
              ? [_chunk(content: '已有的部分回答')]
              : [_chunk(content: '恢复的完整回答', finish: 'stop')],
        );
      });
      final (controller, store) = await _controller(
        server,
        _transport(delays: const [Duration(milliseconds: 100)]),
      );
      final waiting = Completer<void>();
      controller.addListener(() {
        if (controller.reconnecting && !waiting.isCompleted) waiting.complete();
      });
      final sending = controller.send('原始问题');
      await waiting.future;
      expect(controller.generating, isTrue);
      expect(controller.error, isNull);
      expect(controller.active!.messages.last.status, 'streaming');
      expect(controller.active!.messages.last.content, '已有的部分回答');
      expect(controller.generationStatus, contains('自动重连'));
      // Settings changed during a reply must not change its retried request.
      controller.adoptSettings(
        controller.settings.copyWith(model: 'changed-model'),
      );
      await controller.send('不应并发发送');
      await sending;
      expect(attempts, 2);
      expect(bodies[1], bodies[0]);
      expect(controller.active!.messages, hasLength(2));
      expect(controller.active!.messages.last.content, '恢复的完整回答');
      expect(controller.active!.messages.last.status, 'complete');
      expect(controller.reconnecting, isFalse);
      expect(controller.error, isNull);
      expect(
        (await store.load(controller.video.id)).single.messages.last.content,
        '恢复的完整回答',
      );
    },
  );

  test(
    'stopping a controller during reconnect preserves a cancelled partial answer',
    () async {
      final server = await _server();
      var attempts = 0;
      server.listen((request) async {
        attempts++;
        await request.drain<void>();
        await _sse(request, [_chunk(content: '保留这段回答')]);
      });
      final (controller, store) = await _controller(
        server,
        _transport(delays: const [Duration(minutes: 1)]),
      );
      final waiting = Completer<void>();
      controller.addListener(() {
        if (controller.reconnecting && !waiting.isCompleted) waiting.complete();
      });
      final sending = controller.send('暂停之前的问题');
      await waiting.future;
      controller.stop();
      await sending.timeout(const Duration(seconds: 1));
      expect(attempts, 1);
      expect(controller.generating, isFalse);
      expect(controller.error, isNull);
      final saved = (await store.load(
        controller.video.id,
      )).single.messages.last;
      expect(saved.status, 'cancelled');
      expect(saved.content, '保留这段回答');
    },
  );
}
