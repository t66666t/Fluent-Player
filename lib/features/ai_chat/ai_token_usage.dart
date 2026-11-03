import 'dart:convert';
import 'ai_agent_catalog.dart';
import 'ai_chat_settings.dart';

/// Local estimates are deliberately labelled as estimates. The provider's
/// usage always takes precedence; cached input is a subset of input, not extra.
abstract final class AiTokenEstimate {
  static int text(String value) {
    var tokens = 0.0;
    var asciiRun = 0;
    void flush() {
      tokens += (asciiRun / 3).ceil();
      asciiRun = 0;
    }

    for (final rune in value.runes) {
      if (rune < 128 && rune > 32) {
        asciiRun++;
      } else {
        flush();
        if (rune <= 32) {
          tokens += .5;
        } else if (rune >= 0x3400 && rune <= 0x9fff) {
          tokens += 2;
        } else {
          tokens += utf8.encode(String.fromCharCode(rune)).length;
        }
      }
    }
    flush();
    return tokens.ceil();
  }
}

class AiTokenUsage {
  const AiTokenUsage({
    this.input,
    this.output,
    this.total,
    this.cached,
    this.cacheWrite,
    this.reasoning,
    this.cacheMiss,
  });
  final int? input, output, total, cached, cacheWrite, reasoning;
  final int? cacheMiss;
  double? get cacheHitRate => cached != null && input != null && input! > 0
      ? (cached! / input!).clamp(0.0, 1.0)
      : null;
  bool get complete => input != null && output != null;

  static Map<String, dynamic>? merge(
    Map<String, dynamic>? previous,
    Map<String, dynamic>? incoming,
  ) {
    if (incoming == null) return previous;
    final result = {...?previous};
    for (final entry in incoming.entries) {
      if (entry.value == null) continue;
      final old = result[entry.key];
      result[entry.key] = old is Map && entry.value is Map
          ? merge(
              Map<String, dynamic>.from(old),
              Map<String, dynamic>.from(entry.value),
            )
          : entry.value;
    }
    return result;
  }

  static int? _count(dynamic value) =>
      value is num && value.isFinite && value >= 0 ? value.toInt() : null;
  factory AiTokenUsage.fromMap(Map<String, dynamic>? raw) {
    final data = raw ?? const <String, dynamic>{};
    final details =
        data['prompt_tokens_details'] ?? data['input_tokens_details'];
    final outputDetails =
        data['completion_tokens_details'] ?? data['output_tokens_details'];
    final cache = data['cache'];
    final cached = _count(
      data['prompt_cache_hit_tokens'] ??
          data['cached_input_tokens'] ??
          data['cache_read_input_tokens'] ??
          data['cachedContentTokenCount'] ??
          (details is Map ? details['cached_tokens'] : null) ??
          (cache is Map ? cache['read'] : null),
    );
    final write = _count(
      data['cache_creation_input_tokens'] ??
          data['cache_write_input_tokens'] ??
          (details is Map ? details['cache_write_tokens'] : null) ??
          (cache is Map ? cache['write'] : null),
    );
    var input = _count(
      data['prompt_tokens'] ??
          data['promptTokenCount'] ??
          data['input_tokens'] ??
          data['input'],
    );
    if (data['prompt_tokens'] == null &&
        data['input_tokens'] != null &&
        (data.containsKey('cache_read_input_tokens') ||
            data.containsKey('cache_creation_input_tokens'))) {
      input = (input ?? 0) + (cached ?? 0) + (write ?? 0);
    }
    if (data['prompt_tokens'] == null &&
        data['input_tokens'] == null &&
        data['input'] != null &&
        cache is Map) {
      input = (input ?? 0) + (cached ?? 0) + (write ?? 0);
    }
    final reasoning = _count(
      data['thoughtsTokenCount'] ??
          data['reasoning_output_tokens'] ??
          (outputDetails is Map ? outputDetails['reasoning_tokens'] : null) ??
          data['reasoning'],
    );
    var output = _count(
      data['completion_tokens'] ??
          data['output_tokens'] ??
          data['output'] ??
          data['candidatesTokenCount'],
    );
    if (data['completion_tokens'] == null &&
        data['candidatesTokenCount'] != null) {
      output = (output ?? 0) + (reasoning ?? 0);
    }
    if (data['completion_tokens'] == null &&
        data['output_tokens'] == null &&
        data['output'] != null &&
        cache is Map) {
      output = (output ?? 0) + (reasoning ?? 0);
    }
    return AiTokenUsage(
      input: input,
      output: output,
      total:
          _count(
            data['total_tokens'] ?? data['totalTokenCount'] ?? data['total'],
          ) ??
          (input != null && output != null ? input + output : null),
      cached: cached,
      cacheWrite: write,
      reasoning: reasoning,
      cacheMiss: _count(data['prompt_cache_miss_tokens']),
    );
  }

  Map<String, dynamic> toMap() => {
    if (input != null) 'prompt_tokens': input,
    if (output != null) 'completion_tokens': output,
    if (total != null) 'total_tokens': total,
    if (cached != null) 'prompt_cache_hit_tokens': cached,
    if (cacheMiss != null) 'prompt_cache_miss_tokens': cacheMiss,
    if (cacheWrite != null) 'cache_creation_input_tokens': cacheWrite,
    if (reasoning != null)
      'completion_tokens_details': {'reasoning_tokens': reasoning},
  };
}

/// Preserve the reply's original interface, not the currently selected model.
/// Legacy replies use identifiable raw CLI fields; ambiguous ones stay generic.
class AiUsagePresentation {
  const AiUsagePresentation(this.kind);
  final String kind;
  factory AiUsagePresentation.forReply(
    Map<String, dynamic> info,
    Map<String, dynamic>? raw,
  ) {
    final backend = info['backend'];
    final agent = AiBackend.values
        .where((value) => value.name == backend)
        .firstOrNull;
    if (agent?.usesAcp == true) {
      return AiUsagePresentation('agent:${agent!.name}');
    }
    if (backend == 'codex' || raw?.containsKey('cached_input_tokens') == true) {
      return const AiUsagePresentation('codex');
    }
    if (backend == 'opencode' || raw?['cache'] is Map) {
      return const AiUsagePresentation('opencode');
    }
    if (info['api_protocol'] == 'anthropic' ||
        raw?.containsKey('cache_read_input_tokens') == true) {
      return const AiUsagePresentation('claude');
    }
    if (info['api_protocol'] == 'gemini' ||
        raw?.containsKey('promptTokenCount') == true) {
      return const AiUsagePresentation('gemini');
    }
    if (info['provider_host'] == 'api.deepseek.com') {
      return const AiUsagePresentation('deepseek');
    }
    if (info['provider_host'] == 'api.openai.com') {
      return const AiUsagePresentation('openai');
    }
    if (backend == 'api') return const AiUsagePresentation('compatible');
    return const AiUsagePresentation('generic');
  }
  String get label => switch (kind) {
    'codex' => 'Codex CLI',
    'opencode' => 'OpenCode CLI',
    'claude' => 'Claude 原生接口',
    'gemini' => 'Gemini 原生接口',
    'deepseek' => 'DeepSeek API',
    'openai' => 'OpenAI API',
    'compatible' => '自定义兼容接口',
    _ =>
      kind.startsWith('agent:')
          ? '${AiBackend.values.firstWhere((value) => value.name == kind.substring(6)).label} · ACP'
          : '接口来源未记录或自定义接口',
  };
  bool get cli =>
      kind == 'codex' || kind == 'opencode' || kind.startsWith('agent:');
  bool get showCacheRate => !cli && kind != 'generic';
  String get cachedLabel => kind == 'codex'
      ? '已复用输入'
      : kind == 'deepseek'
      ? '缓存命中输入'
      : '缓存输入';
  String get rateLabel => kind == 'deepseek' ? '缓存命中率' : '缓存输入占比';
  String footer(AiTokenUsage usage) {
    if (!showCacheRate || usage.cacheHitRate == null) return '';
    if (usage.cacheHitRate == 0) return kind == 'deepseek' ? ' · 本次未命中缓存' : '';
    return ' · 缓存 ${percent(usage.cacheHitRate!)}';
  }

  static String percent(double ratio) => ratio <= 0
      ? '0%'
      : ratio < .001
      ? '<0.1%'
      : '${(ratio * 100).toStringAsFixed(1)}%';
}

/// Character comparison is diagnostic only, not provider token/cache matching.
Map<String, dynamic> aiCachePrefixTrace(
  List<Map<String, String>>? previous,
  List<Map<String, String>> current,
) {
  if (previous == null) return {'cache_prefix_state': '没有上一条请求可比较'};
  var shared = 0;
  final length = previous.length < current.length
      ? previous.length
      : current.length;
  for (var i = 0; i < length; i++) {
    if (previous[i]['role'] != current[i]['role']) {
      return {
        'cache_prefix_chars': shared,
        'cache_prefix_state': '第 ${i + 1} 条消息角色变化',
      };
    }
    final before = previous[i]['content'] ?? '',
        after = current[i]['content'] ?? '';
    final count = before.length < after.length ? before.length : after.length;
    var matched = 0;
    while (matched < count &&
        before.codeUnitAt(matched) == after.codeUnitAt(matched)) {
      matched++;
    }
    shared += matched;
    if (before != after) {
      return {
        'cache_prefix_chars': shared,
        'cache_prefix_state': i == 0 && current[i]['role'] == 'system'
            ? '系统提示词变化'
            : '第 ${i + 1} 条消息内容变化（资料、播放位置、历史或提问）',
      };
    }
  }
  return {'cache_prefix_chars': shared, 'cache_prefix_state': '已有消息前缀相同'};
}

/// Accumulates separate requests, never separate cumulative SSE usage events.
class AiUsageAccumulator {
  int calls = 0,
      reportedCalls = 0,
      input = 0,
      output = 0,
      total = 0,
      cached = 0,
      cacheReportedCalls = 0;
  void add(Map<String, dynamic>? raw) {
    calls++;
    final usage = AiTokenUsage.fromMap(raw);
    if (usage.total != null) {
      reportedCalls++;
      total += usage.total!;
      input += usage.input ?? 0;
      output += usage.output ?? 0;
    }
    if (usage.cached != null) {
      cacheReportedCalls++;
      cached += usage.cached!;
    }
  }

  Map<String, dynamic> toMap() => {
    'calls': calls,
    'reported_calls': reportedCalls,
    'prompt_tokens': input,
    'completion_tokens': output,
    'total_tokens': total,
    if (calls > 0 && cacheReportedCalls == calls)
      'prompt_cache_hit_tokens': cached,
  };
}
