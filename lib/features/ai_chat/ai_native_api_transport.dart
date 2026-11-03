import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../services/network/network_http.dart';

import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';
import 'ai_token_usage.dart';

/// Native APIs keep their own authentication and request/event schemas.
/// Credentials are headers and are never placed in a URL.
class AiNativeApiTransport {
  AiNativeApiTransport({
    HttpClient Function()? httpClientFactory,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 3),
  }) : _factory =
           httpClientFactory ??
           (() => NetworkHttp.instance.createClient(cancelOnChange: false));

  final HttpClient Function() _factory;
  final Duration connectionTimeout;
  final Duration idleTimeout;

  static Uri endpoint(AiChatSettings settings, {bool models = false}) {
    final uri = Uri.tryParse(settings.baseUrl.trim());
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const AiChatException('请填写有效的 API 地址。');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('key')
      ..remove('api_key');
    if (settings.apiProtocol == AiApiProtocol.anthropic) {
      path = path.replaceFirst(RegExp(r'/(messages|models)$'), '');
      if (path.isEmpty) path = '/v1';
      path = '$path/${models ? 'models' : 'messages'}';
    } else if (settings.apiProtocol == AiApiProtocol.gemini) {
      path = path.replaceFirst(RegExp(r'/models(?:/[^/]+)?$'), '');
      if (path.isEmpty) path = '/v1beta';
      path = '$path/models';
      query.remove('alt');
      if (!models) {
        final model = settings.model.trim().replaceFirst(
          RegExp(r'^models/'),
          '',
        );
        if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(model)) {
          throw const AiChatException('Gemini 模型 ID 格式不正确。');
        }
        path = '$path/$model:streamGenerateContent';
        query['alt'] = 'sse';
      }
    } else {
      throw const AiChatException('此连接没有使用原生 API 协议。');
    }
    return uri.replace(path: path, queryParameters: query, fragment: '');
  }

  static Map<String, dynamic> requestBody(
    AiChatSettings settings,
    List<Map<String, String>> messages,
  ) {
    if (settings.model.trim().isEmpty || settings.maxOutputTokens < 1) {
      throw const AiChatException('请选择模型并设置有效的回答长度。');
    }
    final system = messages
        .where((m) => m['role'] == 'system')
        .map((m) => m['content'] ?? '')
        .join('\n\n');
    final turns = <Map<String, dynamic>>[];
    final gemini = settings.apiProtocol == AiApiProtocol.gemini;
    for (final message in messages) {
      if (message['role'] == 'system') continue;
      final text = message['content'] ?? '';
      if (text.isEmpty) continue;
      final role = message['role'] == 'assistant'
          ? (gemini ? 'model' : 'assistant')
          : 'user';
      final field = gemini ? 'parts' : 'content';
      final Map<String, dynamic> part = gemini
          ? {'text': text}
          : {'type': 'text', 'text': text};
      if (turns.isNotEmpty && turns.last['role'] == role) {
        (turns.last[field] as List).add(part);
      } else {
        turns.add({
          'role': role,
          field: [part],
        });
      }
    }
    if (turns.isEmpty) throw const AiChatException('请先输入一条消息。');
    final info = settings.selectedModelInfo;
    final thinkingEnabled =
        info?.supportsThinking != false &&
        (settings.thinkingEnabled || info?.canDisableThinking == false);
    final limit = info?.maxOutputTokens;
    final output = limit == null
        ? settings.maxOutputTokens
        : settings.maxOutputTokens.clamp(1, limit).toInt();
    final input =
        settings.requestInputTokens ??
        messages.fold<int>(
          0,
          (sum, message) =>
              sum + AiTokenEstimate.text(message['content'] ?? '') + 16,
        );
    final totalInput =
        input + (info?.separateInputOutputLimits == true ? 0 : output);
    if (totalInput > settings.contextTokens ||
        (info?.contextWindow != null && totalInput > info!.contextWindow!) ||
        (info?.inputLimit(thinking: thinkingEnabled) != null &&
            input > info!.inputLimit(thinking: thinkingEnabled)!)) {
      throw const AiChatException(
        '本次请求超过输入预算，请减少资料或调整上下文设置。',
        contextOverflow: true,
      );
    }
    final effort =
        info?.reasoningEfforts.contains(settings.reasoningEffort) == true
        ? settings.reasoningEffort
        : info?.defaultReasoningEffort;
    if (gemini) {
      final generation = <String, dynamic>{'maxOutputTokens': output};
      final model = settings.model.trim().replaceFirst(RegExp(r'^models/'), '');
      if (info?.supportsThinking == true) {
        final thinking = <String, dynamic>{'includeThoughts': true};
        if (model.startsWith('gemini-2.5-')) {
          final cannotDisable = info?.canDisableThinking != true;
          thinking['thinkingBudget'] = !thinkingEnabled && !cannotDisable
              ? 0
              : settings.thinkingBudget > 0
              ? settings.thinkingBudget.clamp(
                  model.contains('-pro') ? 128 : 512,
                  model.contains('-pro') ? 32768 : 24576,
                )
              : -1;
        } else if (model.startsWith('gemini-3') && effort != null) {
          thinking['thinkingLevel'] = thinkingEnabled
              ? effort
              : info!.reasoningEfforts.first;
        }
        generation['thinkingConfig'] = thinking;
      } else if (info?.supportsThinking == false) {
        generation['temperature'] = settings.temperature;
      }
      return {
        'contents': turns,
        if (system.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
        'generationConfig': generation,
      };
    }
    final body = <String, dynamic>{
      'model': settings.model.trim(),
      'max_tokens': output,
      'stream': true,
      'messages': turns,
      if (system.isNotEmpty) 'system': system,
    };
    final types = info?.supportsThinking == false
        ? const <String>[]
        : info?.thinkingTypes ?? const <String>[];
    if (thinkingEnabled &&
        settings.thinkingBudget > 0 &&
        types.contains('enabled') &&
        output > 1024) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': settings.thinkingBudget.clamp(1024, output - 1),
      };
    } else if (thinkingEnabled && types.contains('adaptive')) {
      body['thinking'] = {'type': 'adaptive'};
    } else if (thinkingEnabled && types.contains('enabled') && output > 1024) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': (output ~/ 2).clamp(1024, output - 1),
      };
    } else if (!thinkingEnabled && types.contains('disabled')) {
      body['thinking'] = {'type': 'disabled'};
    }
    if (thinkingEnabled &&
        info?.supportsReasoningEffort == true &&
        effort != null) {
      body['output_config'] = {'effort': effort};
    }
    // New Claude families have removed sampling controls. Leaving these out
    // also works on older models and on native proxy services.
    if (Uri.tryParse(settings.baseUrl)?.host == 'api.anthropic.com') {
      // The first source-data block is stable. Later blocks include playback
      // position and the new question; placing the breakpoint before those
      // preserves the reusable prefix. Custom proxies get no extra fields.
      final content = turns.first['content'];
      if (content is List &&
          content.isNotEmpty &&
          content.first is Map &&
          AiTokenEstimate.text(content.first['text'] as String? ?? '') >=
              1024) {
        (content.first as Map)['cache_control'] = {'type': 'ephemeral'};
      }
    }
    return body;
  }

  void _authenticate(HttpClientRequest request, AiChatSettings settings) {
    if (settings.apiKey.trim().isNotEmpty &&
        !RegExp(r'^[\x21-\x7e]+$').hasMatch(settings.apiKey.trim())) {
      throw const AiChatException('API 密钥包含空格或控制字符，请重新检查粘贴内容。');
    }
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (settings.apiKey.trim().isNotEmpty) {
      request.headers.set(
        settings.apiProtocol == AiApiProtocol.anthropic
            ? 'x-api-key'
            : 'x-goog-api-key',
        settings.apiKey.trim(),
      );
    }
    if (settings.apiProtocol == AiApiProtocol.anthropic) {
      request.headers.set('anthropic-version', '2023-06-01');
    }
  }

  static String _redact(String text, AiChatSettings settings) {
    var result = text;
    for (final key in {settings.apiKey, settings.apiKey.trim()}) {
      if (key.isNotEmpty) result = result.replaceAll(key, '[已隐藏密钥]');
    }
    result = result.replaceAll(
      RegExp(r'(?:Bearer\s+|sk-)[a-zA-Z0-9_-]+'),
      '[已隐藏密钥]',
    );
    return result.length > 600 ? '${result.substring(0, 600)}…' : result;
  }

  Future<Never> _httpError(
    HttpClientResponse response,
    AiChatSettings settings,
  ) async {
    final raw = await _boundedText(response, 65536);
    var detail = '';
    try {
      final decoded = jsonDecode(raw);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map && error['message'] is String) detail = error['message'];
    } catch (_) {
      /* A proxy may respond with HTML. */
    }
    final hint = switch (response.statusCode) {
      401 || 403 => '请检查 API 密钥及模型访问权限。',
      404 => '请检查 API 地址、协议和模型 ID。',
      429 => '服务繁忙或额度不足，请稍后重试。',
      _ => '请检查连接设置后重试。',
    };
    throw AiChatException(
      'AI 服务返回 ${response.statusCode}。$hint'
      '${detail.isEmpty ? '' : '\n${_redact(detail, settings)}'}',
      contextOverflow: AiChatException.isContextOverflow(
        raw,
        statusCode: response.statusCode,
      ),
      statusCode: response.statusCode,
    );
  }

  Future<String> _boundedText(Stream<List<int>> response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(idleTimeout)) {
      if (bytes.length + chunk.length > limit) {
        throw const AiChatException('AI 服务返回的数据过大，请检查 API 地址。');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    final token = cancellation ?? AiChatCancellation();
    final client = _factory()..connectionTimeout = connectionTimeout;
    final remove = token.onCancel(() => client.close(force: true));
    final found = <String, AiModelInfo>{};
    var uri = endpoint(settings, models: true);
    final seenPages = <String>{};
    try {
      for (var page = 0; page < 20 && !token.isCancelled; page++) {
        final request = await client.getUrl(uri).timeout(connectionTimeout);
        _authenticate(request, settings);
        final response = await request.close().timeout(connectionTimeout);
        if (response.statusCode != 200) await _httpError(response, settings);
        dynamic decoded;
        try {
          decoded = jsonDecode(await _boundedText(response, 4 * 1024 * 1024));
        } on FormatException {
          throw const AiChatException('服务返回了无法读取的模型目录，可手动填写模型 ID。');
        }
        if (decoded is! Map) throw const AiChatException('无法读取模型目录。');
        final rows =
            decoded[settings.apiProtocol == AiApiProtocol.gemini
                ? 'models'
                : 'data'];
        if (rows is! List) throw const AiChatException('服务未返回模型目录，可手动填写模型 ID。');
        for (final row in rows) {
          if (row is! Map) continue;
          final info = _model(settings.apiProtocol, row);
          if (info != null) found[info.id] = info;
        }
        final next = settings.apiProtocol == AiApiProtocol.gemini
            ? decoded['nextPageToken']
            : decoded['has_more'] == true
            ? decoded['last_id']
            : null;
        if (next is! String || next.isEmpty || !seenPages.add(next)) break;
        uri = uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            (settings.apiProtocol == AiApiProtocol.gemini
                    ? 'pageToken'
                    : 'after_id'):
                next,
          },
        );
      }
      if (token.isCancelled) return [];
      return found.values.toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
    } catch (_) {
      if (token.isCancelled) return [];
      rethrow;
    } finally {
      remove();
      client.close(force: true);
    }
  }

  static AiModelInfo? _model(AiApiProtocol protocol, Map row) {
    if (protocol == AiApiProtocol.gemini) {
      final methods = row['supportedGenerationMethods'];
      if (methods is List && !methods.contains('generateContent')) return null;
      final name = row['name'];
      if (name is! String || name.isEmpty) return null;
      final id = name.replaceFirst(RegExp(r'^models/'), '');
      var levels = const <String>[];
      if (RegExp(r'^gemini-(3(?:-pro|-flash)|3\.(1|5|6|8)-)').hasMatch(id)) {
        levels = id.startsWith('gemini-3-pro')
            ? const ['low', 'high']
            : id.contains('flash-lite-image')
            ? const ['minimal', 'high']
            : id.startsWith('gemini-3.8') || id.contains('-pro')
            ? const ['low', 'medium', 'high']
            : const ['minimal', 'low', 'medium', 'high'];
      }
      return AiModelInfo.fromJson({
        'id': id,
        'name': row['displayName'],
        'description': row['description'],
        'context_window': row['contextWindow'] ?? row['inputTokenLimit'],
        'max_input_tokens': row['inputTokenLimit'],
        'separate_input_output_limits':
            row['separateInputOutputLimits'] == true ||
            (row['contextWindow'] == null &&
                RegExp(r'^gemini-[123](?:[.-]|$)').hasMatch(id)),
        'max_output_tokens': row['outputTokenLimit'],
        'supports_thinking': row['thinking'],
        'supports_reasoning_effort': levels.isNotEmpty,
        'supports_thinking_budget':
            id.startsWith('gemini-2.5-') && row['thinking'] == true,
        'thinking_types': id.startsWith('gemini-2.5-') && !id.contains('-pro')
            ? ['enabled', 'disabled']
            : ['enabled'],
        'effort': {'supported_levels': levels, 'default_level': 'high'},
      });
    }
    if (row['id'] is! String || row['lifecycle'] == 'retired') return null;
    final capabilities = row['capabilities'] is Map
        ? row['capabilities'] as Map
        : const {};
    final thinking = capabilities['thinking'] is Map
        ? capabilities['thinking'] as Map
        : const {};
    final types = thinking['types'] is Map
        ? thinking['types'] as Map
        : const {};
    final effort = capabilities['effort'] is Map
        ? capabilities['effort'] as Map
        : const {};
    final levels = [
      for (final level in ['low', 'medium', 'high', 'xhigh', 'max'])
        if (effort[level] is Map && effort[level]['supported'] == true) level,
    ];
    return AiModelInfo.fromJson({
      'id': row['id'],
      'name': row['display_name'],
      'description': row['description'],
      'created_at': row['created_at'],
      'context_window': row['context_window'] ?? row['max_input_tokens'],
      'max_input_tokens': row['max_input_tokens'],
      'separate_input_output_limits': row['context_window'] == null,
      'max_output_tokens': row['max_tokens'],
      'supports_thinking': thinking['supported'],
      'thinking_types': [
        for (final type in ['adaptive', 'enabled', 'disabled'])
          if (types[type] is Map && types[type]['supported'] == true) type,
      ],
      'supports_thinking_budget':
          types['enabled'] is Map && types['enabled']['supported'] == true,
      'supports_reasoning_effort': effort['supported'],
      'effort': {'supported_levels': levels, 'default_level': 'high'},
    });
  }

  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    if (cancellation.isCancelled) return;
    final uri = endpoint(settings);
    final body = requestBody(settings, messages);
    final client = _factory()..connectionTimeout = connectionTimeout;
    StreamIterator<String>? events;
    final remove = cancellation.onCancel(() {
      client.close(force: true);
      if (events != null) unawaited(events.cancel());
    });
    try {
      final request = await client.postUrl(uri).timeout(connectionTimeout);
      _authenticate(request, settings);
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(connectionTimeout);
      if (response.statusCode != 200) await _httpError(response, settings);
      var finished = false;
      final usage = <String, dynamic>{};
      events = StreamIterator(_events(response));
      while (await events.moveNext()) {
        final event = events.current;
        if (cancellation.isCancelled) return;
        Map decoded;
        try {
          final value = jsonDecode(event);
          if (value is! Map) throw const FormatException();
          decoded = value;
        } catch (_) {
          throw const AiChatException('AI 返回了无法读取的流式数据。');
        }
        final error = decoded['error'];
        if (error is Map) {
          throw AiChatException(
            'AI 服务错误：${_redact('${error['message'] ?? error['type'] ?? '未知错误'}', settings)}',
            retryable: AiChatTransport.isTransientProviderError(error),
            contextOverflow: AiChatException.isContextOverflow(
              jsonEncode(error),
            ),
          );
        }
        if (settings.apiProtocol == AiApiProtocol.anthropic) {
          switch (decoded['type']) {
            case 'message_start':
              final message = decoded['message'];
              if (message is Map && message['usage'] is Map) {
                usage.addAll(Map<String, dynamic>.from(message['usage']));
              }
            case 'content_block_start':
              final block = decoded['content_block'];
              if (block is Map) {
                yield AiChatDelta(
                  content: block['type'] == 'text'
                      ? block['text'] as String? ?? ''
                      : '',
                  reasoning: block['type'] == 'thinking'
                      ? block['thinking'] as String? ?? ''
                      : '',
                );
              }
            case 'content_block_delta':
              final delta = decoded['delta'];
              if (delta is Map) {
                yield AiChatDelta(
                  content: delta['type'] == 'text_delta'
                      ? delta['text'] as String? ?? ''
                      : '',
                  reasoning: delta['type'] == 'thinking_delta'
                      ? delta['thinking'] as String? ?? ''
                      : '',
                );
              }
            case 'message_delta':
              if (decoded['usage'] is Map) {
                usage.addAll(Map<String, dynamic>.from(decoded['usage']));
              }
              final delta = decoded['delta'];
              if (delta is Map && delta['stop_reason'] != null) {
                yield AiChatDelta(
                  usage: _claudeUsage(usage),
                  finishReason: switch (delta['stop_reason']) {
                    'max_tokens' => 'length',
                    'refusal' => 'content_filter',
                    'tool_use' => 'tool_calls',
                    'pause_turn' => 'aborted',
                    'end_turn' || 'stop_sequence' => 'stop',
                    _ => 'aborted',
                  },
                );
              }
            case 'message_stop':
              finished = true;
              yield AiChatDelta(usage: _claudeUsage(usage));
              return;
          }
        } else {
          final feedback = decoded['promptFeedback'];
          if (feedback is Map && feedback['blockReason'] != null) {
            throw const AiChatException('Gemini 未生成回答，请调整问题或检查服务的内容限制。');
          }
          final rawUsage = decoded['usageMetadata'];
          final normalizedUsage = rawUsage is Map
              ? {
                  ...AiTokenUsage.fromMap(
                    Map<String, dynamic>.from(rawUsage),
                  ).toMap(),
                  if (rawUsage['initialPromptTokenCount'] is num)
                    'context_input_tokens':
                        (rawUsage['initialPromptTokenCount'] as num).toInt(),
                }
              : null;
          final candidates = decoded['candidates'];
          if (candidates is! List || candidates.isEmpty) {
            if (normalizedUsage != null) {
              yield AiChatDelta(usage: normalizedUsage);
            }
            continue;
          }
          final candidate = candidates.first;
          if (candidate is! Map) continue;
          final content = candidate['content'];
          final parts = content is Map ? content['parts'] : null;
          if (parts is List) {
            for (final part in parts) {
              if (part is Map && part['text'] is String) {
                yield AiChatDelta(
                  content: part['thought'] == true ? '' : part['text'],
                  reasoning: part['thought'] == true ? part['text'] : '',
                );
              }
            }
          }
          final reason = candidate['finishReason'];
          if (reason != null) finished = true;
          yield AiChatDelta(
            usage: normalizedUsage,
            finishReason: reason == null
                ? null
                : switch (reason) {
                    'MAX_TOKENS' => 'length',
                    'STOP' => 'stop',
                    'SAFETY' ||
                    'RECITATION' ||
                    'BLOCKLIST' ||
                    'PROHIBITED_CONTENT' ||
                    'SPII' ||
                    'IMAGE_SAFETY' => 'content_filter',
                    _ => 'aborted',
                  },
          );
        }
      }
      if (!finished && !cancellation.isCancelled) {
        throw const AiChatException('AI 连接中断，回答可能不完整，请重试。', retryable: true);
      }
    } catch (_) {
      if (cancellation.isCancelled) return;
      rethrow;
    } finally {
      remove();
      await events?.cancel();
      client.close(force: true);
    }
  }

  static Map<String, dynamic> _claudeUsage(Map<String, dynamic> usage) => {
    ...usage,
    'prompt_tokens':
        (usage['input_tokens'] as num? ?? 0) +
        (usage['cache_read_input_tokens'] as num? ?? 0) +
        (usage['cache_creation_input_tokens'] as num? ?? 0),
    'completion_tokens': usage['output_tokens'],
    'total_tokens':
        (usage['input_tokens'] as num? ?? 0) +
        (usage['cache_read_input_tokens'] as num? ?? 0) +
        (usage['cache_creation_input_tokens'] as num? ?? 0) +
        (usage['output_tokens'] as num? ?? 0),
  };

  Stream<String> _events(Stream<List<int>> source) async* {
    final data = <String>[];
    var size = 0;
    await for (final line
        in source
            .timeout(idleTimeout)
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) yield data.join('\n');
        data.clear();
        size = 0;
      } else if (line.startsWith('data:')) {
        final text = line.substring(5).replaceFirst(RegExp(r'^ '), '');
        size += text.length;
        if (size > 2 * 1024 * 1024) throw const AiChatException('AI 流式消息过大。');
        data.add(text);
      }
    }
    if (data.isNotEmpty) {
      final payload = data.join('\n');
      try {
        jsonDecode(payload);
      } on FormatException {
        throw const AiChatException('AI 流式数据在接收完成前中断。', retryable: true);
      }
      yield payload;
    }
  }
}
