import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'ai_chat_controller.dart';
import 'ai_compaction_dialog.dart';
import 'ai_chat_layout.dart';
import 'ai_chat_models.dart';
import 'ai_chat_settings.dart';
import 'ai_token_usage.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

String aiTokenNumber(int? value) {
  if (value == null) return '未返回';
  return value.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );
}

class AiResponseUsage extends StatelessWidget {
  const AiResponseUsage({super.key, required this.message});
  final AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final usage = AiTokenUsage.fromMap(message.usage);
    final info = message.responseInfo ?? const <String, dynamic>{};
    final presentation = AiUsagePresentation.forReply(info, message.usage);
    final hasCache =
        usage.cached != null ||
        usage.cacheWrite != null ||
        usage.cacheMiss != null;
    final showReasoning =
        usage.reasoning != null &&
        (usage.reasoning! > 0 || info['supports_thinking'] == true);
    final estimated = info['estimated_output'] as int?;
    final preparation = info['preparation_usage'];
    final prep = preparation is Map
        ? Map<String, dynamic>.from(preparation)
        : null;
    final title = AiTokenUsage.fromMap(
      info['title_usage'] is Map
          ? Map<String, dynamic>.from(info['title_usage'])
          : null,
    );
    final hasTitle = info['title_requested'] == true;
    final planning = AiTokenUsage.fromMap(
      info['planning_usage'] is Map
          ? Map<String, dynamic>.from(info['planning_usage'])
          : null,
    );
    final hasPlanning = info.containsKey('planning_usage');
    final extraCalls = <Map<String, dynamic>>[
      for (final key in ['compaction', 'overflow_recovery'])
        if (info[key] is Map && (info[key]['calls'] as int? ?? 0) > 0)
          Map<String, dynamic>.from(info[key]),
      if (info['overflow_attempt_usage'] is Map)
        {
          'usage': info['overflow_attempt_usage'],
          'calls': info['overflow_attempt_usage']['calls'] ?? 1,
        },
    ];
    final extraTotal = extraCalls.fold<int>(
      0,
      (n, entry) =>
          n +
          (entry['usage'] is Map
              ? AiTokenUsage.fromMap(
                      Map<String, dynamic>.from(entry['usage']),
                    ).total ??
                    0
              : 0),
    );
    final extrasComplete = extraCalls.every(
      (entry) =>
          entry['usage'] is Map &&
          entry['usage']['reported_calls'] == entry['calls'],
    );
    final knownTotal =
        (usage.total ?? 0) +
        (prep?['total_tokens'] as int? ?? 0) +
        (title.total ?? 0) +
        (planning.total ?? 0) +
        extraTotal;
    final hasPrep = (prep?['calls'] as int? ?? 0) > 0;
    final generation = info['generation_usage'];
    final complete =
        usage.total != null &&
        (generation is! Map ||
            generation['calls'] == generation['reported_calls']) &&
        (!hasPrep || prep?['calls'] == prep?['reported_calls']) &&
        (!hasTitle || title.complete) &&
        (!hasPlanning || planning.complete) &&
        extrasComplete;
    final label = usage.total != null || hasPrep || extraCalls.isNotEmpty
        ? '${complete ? '' : '已知 '}${aiTokenNumber(knownTotal)} token${presentation.footer(usage)}'
        : message.status == 'streaming'
        ? '生成中 · 等待用量'
        : estimated != null
        ? '输出约 ${aiTokenNumber(estimated)} token'
        : '服务未返回用量';
    return Align(
      alignment: Alignment.centerRight,
      child: DesktopButtonClickRegion(child: TextButton.icon(
        key: ValueKey('ai-response-usage-${message.id}'),
        onPressed: () => showAiNearbyNote(
          context: context,
          title: const Text('答复用量'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                  for (final extra in extraCalls)
                    Text(
                      '上下文压缩或超窗恢复请求：${extra['calls']} 次 · 已知 ${extra['usage'] is Map ? AiTokenUsage.fromMap(Map<String, dynamic>.from(extra['usage'])).total ?? 0 : 0} token',
                    ),
                  if (info['compaction'] is Map)
                    Text('${info['compaction']['message']}'),
                  if (info['model'] != null) Text('模型：${info['model']}'),
                  Text('统计来源：${presentation.label}'),
                  const SizedBox(height: 8),
                  Text('本次回答输入：${aiTokenNumber(usage.input)} token'),
                  Text(
                    '本次回答输出：${aiTokenNumber(usage.output)} token${showReasoning ? '（含思考）' : ''}',
                  ),
                  Text('本次回答合计：${aiTokenNumber(usage.total)} token'),
                  if (generation is Map &&
                      (generation['calls'] as int? ?? 0) > 1)
                    Text(
                      '含自动续写：${generation['calls']} 次生成，${generation['reported_calls']} 次返回完整用量',
                    ),
                  if (hasPlanning)
                    Text('理解问题与选择资料：${aiTokenNumber(planning.total)} token'),
                  if (info['planning_warning'] != null)
                    Text('${info['planning_warning']}'),
                  if (showReasoning)
                    Text('其中思考：${aiTokenNumber(usage.reasoning)} token'),
                  if (usage.cached != null)
                    Text(
                      '${presentation.cachedLabel}：${aiTokenNumber(usage.cached)} token',
                    ),
                  if (presentation.showCacheRate && usage.cacheHitRate != null)
                    Text(
                      '${presentation.rateLabel}：${AiUsagePresentation.percent(usage.cacheHitRate!)}',
                    ),
                  if (usage.cacheMiss != null)
                    Text('未命中输入：${aiTokenNumber(usage.cacheMiss)} token'),
                  if (usage.cacheWrite != null)
                    Text('缓存写入：${aiTokenNumber(usage.cacheWrite)} token'),
                  if (presentation.kind == 'deepseek') ...[
                    if (!hasCache) const Text('本次接口未返回缓存统计，无法判断是否命中。'),
                    if (usage.cached == 0)
                      const Text(
                        '服务报告本次缓存读取为 0。首次请求、重复前缀尚未写入缓存、资料变化或缓存过期都可能导致未命中；仅凭用量无法确定服务端原因。',
                        style: TextStyle(fontSize: 12),
                      ),
                    if (info['cache_prefix_state'] != null)
                      Text(
                        '前缀检查：${info['cache_prefix_state']}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (info['cache_prefix_chars'] != null)
                      Text(
                        '与上次请求相同的开头：${info['cache_prefix_chars']} 个字符（本地比较，非服务端缓存 token）。',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                  if (!complete) ...[
                    const SizedBox(height: 8),
                    Text(
                      '输入估算：${aiTokenNumber(info['estimated_input'] as int?)} · 输出估算：${aiTokenNumber(estimated)}',
                    ),
                    const Text('估算不代表账单；停止或断流时，服务可能不会返回最终统计。'),
                  ],
                  const SizedBox(height: 12),
                  Text('资料方式：${info['context_mode'] ?? '旧记录未保存'}'),
                  if (info['reused_request_prefix'] == true)
                    const Text('上下文：保留上次实际请求，仅追加新资料。'),
                  if (info['session_reset_reason'] is String)
                    Text(
                      info['session_reset_reason'],
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (info['reserved_output'] != null)
                    Text(
                      '首次生成上限：${aiTokenNumber(info['reserved_output'] as int?)} token',
                    ),
                  if (info['configured_output_limit'] != null &&
                      info['configured_output_limit'] !=
                          info['reserved_output'])
                    Text(
                      '配置上限：${aiTokenNumber(info['configured_output_limit'] as int?)} token · 本次按任务缩减',
                    ),
                  if (info['context_budget'] != null)
                    Text(
                      '本次请求预算：${aiTokenNumber(info['context_budget'] as int?)} token',
                    ),
                  if (info['configured_context_budget'] != null &&
                      info['context_budget'] !=
                          info['configured_context_budget'])
                    Text(
                      '常规配置预算：${aiTokenNumber(info['configured_context_budget'] as int?)} token · 为全文临时扩展',
                    ),
                  if (info['total_segments'] != null)
                    Text(
                      '已处理分段：${info['processed_segments']}/${info['total_segments']} · 复用记录 ${info['reused_segments'] ?? 0}',
                    ),
                  if (hasPrep) ...[
                    const SizedBox(height: 8),
                    Text(
                      '全文预处理：${prep!['calls']} 次请求，${prep['reported_calls']} 次有完整用量',
                    ),
                    Text(
                      '已知预处理消耗：${aiTokenNumber(prep['total_tokens'] as int?)} token',
                    ),
                    if (prep['peak_concurrency'] != null)
                      Text('同时处理最多 ${prep['peak_concurrency']} 段'),
                    if (prep['call_limit'] != null)
                      Text('自动处理请求：${prep['calls']} / ${prep['call_limit']} 次'),
                    if (prep['estimated_input_limit'] != null)
                      Text(
                        '累计输入估算：${aiTokenNumber(prep['estimated_input_spent'] as int?)} / ${aiTokenNumber(prep['estimated_input_limit'] as int?)} token',
                      ),
                    Text(
                      '已知预处理输入：${aiTokenNumber(prep['prompt_tokens'] as int?)} · 输出：${aiTokenNumber(prep['completion_tokens'] as int?)}',
                    ),
                    Text(
                      '含预处理的${complete ? '合计' : '已知合计'}：${aiTokenNumber(knownTotal)} token',
                    ),
                    if (prep['attempts'] is List &&
                        (prep['attempts'] as List).isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          '分段处理记录',
                          style: TextStyle(fontSize: 12),
                        ),
                        children: [
                          for (final attempt in prep['attempts'] as List)
                            if (attempt is Map)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${attempt['segment']} · ${attempt['finish_reason']}\n输入 ${aiTokenNumber(attempt['input_tokens'] as int?)} · 输出 ${aiTokenNumber(attempt['output_tokens'] as int?)} / 上限 ${attempt['output_limit']} token'
                                    '${attempt['duration_ms'] is num ? '\n耗时 ${((attempt['duration_ms'] as num) / 1000).toStringAsFixed(1)} 秒' : ''}'
                                    '${attempt['action'] == 'continue'
                                        ? ' · 续写未完成记录'
                                        : attempt['action'] == 'body_recovery'
                                        ? ' · 恢复正文'
                                        : ''}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ),
                        ],
                      ),
                  ],
                  if (hasTitle) ...[
                    const SizedBox(height: 8),
                    Text('自动标题请求：${aiTokenNumber(title.total)} token'),
                    Text(
                      '含标题的${complete ? '合计' : '已知合计'}：${aiTokenNumber(knownTotal)} token',
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    presentation.cli
                        ? 'CLI 仅显示其实际返回的统计。已复用输入是 CLI 报告的输入复用量，不是 DeepSeek 的缓存指标，也不代表账户剩余额度或实际费用。'
                        : hasCache
                        ? '缓存输入已包含在输入中，不重复相加；占比按实际返回计算。本地分段记录复用与服务端缓存是两回事，复用记录仍可能让本次请求更省。'
                        : '仅显示接口实际返回的统计，未返回的缓存或思考字段不显示。',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Text(
                    '历史数值按当时的接口和模型保存，不随当前设置改变。',
                    style: TextStyle(fontSize: 12),
                  ),
            ],
          ),
          actions: (dialogContext) => [
            DesktopButtonClickRegion(child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            )),
          ],
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.data_usage, size: 13),
        label: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      )),
    );
  }
}

/// Recomputes only this small indicator after typing settles. Message Markdown
/// stays outside these updates and resizing never rebuilds the estimate.
class AiContextMeter extends StatefulWidget {
  const AiContextMeter({
    super.key,
    required this.controller,
    required this.input,
    this.compact = false,
  });
  final AiChatController controller;
  final TextEditingController input;
  final bool compact;
  @override
  State<AiContextMeter> createState() => _AiContextMeterState();
}

class _AiContextMeterState extends State<AiContextMeter> {
  Timer? _timer;
  int _input = 0;
  int _untrimmed = 0;
  int _reserve = 0;
  int _effectiveBudget = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.input.addListener(_schedule);
    widget.controller.addListener(_controllerChanged);
    _refresh();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(_refresh);
    });
  }

  void _controllerChanged() {
    if (widget.controller.busy &&
        widget.controller.lastRequest?.estimatedTokens != _input) {
      _timer?.cancel();
      if (mounted) setState(_refresh);
    } else {
      _schedule();
    }
  }

  void _refresh() {
    try {
      final request = widget.controller.busy
          ? widget.controller.lastRequest
          : widget.controller.preview(
              widget.input.text.trim().isEmpty ? '继续' : widget.input.text,
            );
      _input = request?.estimatedTokens ?? 0;
      _untrimmed = (request?.untrimmedTokens ?? 0) > _input
          ? request!.untrimmedTokens
          : _input;
      _reserve =
          request?.outputReserve ?? widget.controller.settings.maxOutputTokens;
      _effectiveBudget =
          request?.contextLimit ?? widget.controller.settings.contextTokens;
      _error = null;
    } catch (error) {
      _error = error.toString().replaceFirst('Bad state: ', '');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.input.removeListener(_schedule);
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    final lastInfo =
        widget.controller.active?.messages.lastOrNull?.responseInfo;
    final reportedWindow = lastInfo?['model'] == settings.model
        ? (lastInfo?['model_window'] as int?)
        : null;
    final modelWindow =
        settings.selectedModelInfo?.contextWindow ?? reportedWindow;
    final window = modelWindow ?? settings.contextTokens;
    final ratio = ((settings.autoCompact ? _untrimmed : _input) / window).clamp(
      0.0,
      1.0,
    );
    final colors = Theme.of(context).colorScheme;
    final text =
        (_error != null ? '预估不可用' : null) ??
        '${widget.compact
            ? ''
            : modelWindow == null
            ? '预算 '
            : '上下文 '}≈${(ratio * 100).toStringAsFixed(ratio < .1 ? 1 : 0)}%';
    return DesktopButtonClickRegion(child: TextButton(
      key: const ValueKey('ai-context-meter'),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => showAiNearbyNote(
        context: context,
        title: const Text('上下文使用量'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                Text(
                  '所选模型：${settings.model.isEmpty ? 'CLI 默认模型' : settings.model}',
                ),
                const SizedBox(height: 8),
                Text('下次请求输入估算：${aiTokenNumber(_input)} token'),
                if (_untrimmed > _input)
                  Text(
                    '整理前完整活动历史估算：${aiTokenNumber(_untrimmed)} token；发送前会按预算整理',
                  ),
                if (!widget.controller.busy &&
                    widget.controller.contextCheckpoint != null)
                  Text(
                    '已使用对话摘要，覆盖 ${widget.controller.contextCheckpoint!.coveredMessages} 条历史消息',
                  ),
                Text(
                  '模型上下文窗口：${modelWindow == null ? '服务未声明' : '${aiTokenNumber(modelWindow)} token'}',
                ),
                Text('当前配置预算：${aiTokenNumber(settings.contextTokens)} token'),
                if (_effectiveBudget > settings.contextTokens)
                  Text('本次全文临时预算：${aiTokenNumber(_effectiveBudget)} token'),
                Text('本次预留回答空间：${aiTokenNumber(_reserve)} token'),
                if (widget.controller.lastUsage != null)
                  Text(
                    '上次计费输入（可能含重试与续写）：${aiTokenNumber(AiTokenUsage.fromMap(widget.controller.lastUsage).input)} token',
                  ),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: colors.error)),
                const SizedBox(height: 12),
                const Text(
                  '指示器显示预计输入占模型窗口的比例；开启自动压缩时包含整理前的活动历史，模型窗口未知时使用配置预算。还需给回答留出空间。自动总结优先全文直读；省 token 模式只检索片段，超长文稿可分段处理。历史记录不会全部重复发送。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                const Text(
                  '这是本地估算，实际 token 取决于模型分词器。生成时显示正在发送的请求，完成后显示下一次请求的估算。',
                  style: TextStyle(fontSize: 12),
                ),
                if (settings.backend != AiBackend.api)
                  const Text(
                    'CLI 可能另加内部提示词和工具定义，本地估算不包含全部内部开销；实际用量以上次返回的统计为准。',
                    style: TextStyle(fontSize: 12),
                  ),
          ],
        ),
        actions: (dialogContext) => [
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              showAiCompactionDialog(this.context, widget.controller);
            },
            child: const Text('压缩与摘要'),
          )),
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          )),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 2,
              backgroundColor: colors.outlineVariant,
              color: _error != null || ratio > .85
                  ? colors.error
                  : colors.primary,
            ),
          ),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ));
  }
}

/// A short note anchored to the control that opened it.
///
/// [AiAdaptiveDialog] is a full route surface: on a narrow panel it takes the
/// whole screen, and on a wide one it still stretches toward 760×860. These
/// usage notes are a handful of lines, so the window hugs that text and sits
/// beside the button instead.
Future<void> showAiNearbyNote({
  required BuildContext context,
  required Widget title,
  required Widget content,
  List<Widget> Function(BuildContext dialogContext)? actions,
}) {
  final box = context.findRenderObject();
  final anchor = box is RenderBox && box.hasSize && box.attached
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, animation, secondary) {
      return Theme(
        data: aiChatTheme(Theme.of(dialogContext)),
        child: _AiNearbyNote(
          anchor: anchor,
          title: title,
          content: content,
          actions: actions?.call(dialogContext) ?? const <Widget>[],
        ),
      );
    },
    transitionBuilder: (context, animation, secondary, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _AiNearbyNote extends StatelessWidget {
  const _AiNearbyNote({
    required this.anchor,
    required this.title,
    required this.content,
    required this.actions,
  });

  final Rect? anchor;
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final maxHeight = math
        .min(420.0, media.size.height - media.padding.vertical - 16)
        .clamp(0.0, 420.0)
        .toDouble();
    // Title and actions stay outside the scroller. The body uses whatever
    // is left, and only that part scrolls when the note is longer than the window.
    final bodyMax = math.max(48.0, maxHeight - 132);
    return CustomSingleChildLayout(
      delegate: _AiNearbyNoteDelegate(
        anchor: anchor,
        padding: media.padding,
        maxHeight: maxHeight,
      ),
      child: Material(
        color: colors.surfaceContainerLow,
        elevation: 8,
        shadowColor: const Color(0x99000000),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: DefaultTextStyle(
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
                child: title,
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: DefaultTextStyle(
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: colors.onSurface,
                ),
                child: _NoteBody(maxHeight: bodyMax, child: content),
              ),
            ),
            if (actions.isNotEmpty) ...[
              Divider(height: 1, color: colors.outlineVariant),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  runSpacing: 0,
                  children: actions,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hugs [child] until it would exceed [maxHeight], then scrolls inside that limit.
///
/// The first frame measures the text. A shrink-wrapped list reports itself as
/// tall as its text, so the card clips the tail and taps miss it. Switching to
/// a bounded scroller keeps that tail reachable.
class _NoteBody extends StatefulWidget {
  const _NoteBody({required this.maxHeight, required this.child});

  final double maxHeight;
  final Widget child;

  @override
  State<_NoteBody> createState() => _NoteBodyState();
}

class _NoteBodyState extends State<_NoteBody> {
  bool _scroll = false;

  void _overflowed() {
    if (_scroll || !mounted) return;
    setState(() => _scroll = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_scroll) {
      return SizedBox(
        height: widget.maxHeight,
        width: double.infinity,
        child: SingleChildScrollView(primary: false, child: widget.child),
      );
    }
    return _OverflowProbe(
      maxHeight: widget.maxHeight,
      onOverflow: _overflowed,
      child: widget.child,
    );
  }
}

class _OverflowProbe extends SingleChildRenderObjectWidget {
  const _OverflowProbe({
    required this.maxHeight,
    required this.onOverflow,
    required super.child,
  });

  final double maxHeight;
  final VoidCallback onOverflow;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOverflowProbe(maxHeight: maxHeight, onOverflow: onOverflow);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderOverflowProbe renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..onOverflow = onOverflow;
  }
}

class _RenderOverflowProbe extends RenderProxyBox {
  _RenderOverflowProbe({required double maxHeight, required this.onOverflow})
    : _maxHeight = maxHeight;

  double _maxHeight;
  VoidCallback onOverflow;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      BoxConstraints.tightFor(width: constraints.maxWidth),
      parentUsesSize: true,
    );
    final limit = math.min(_maxHeight, constraints.maxHeight);
    if (child.size.height > limit + 0.5) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onOverflow());
    }
    size = constraints.constrain(
      Size(constraints.maxWidth, math.min(child.size.height, limit)),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (child.size.height <= size.height + 0.5) {
      context.paintChild(child, offset);
      return;
    }
    // The measuring frame can be taller than the note. Clip it until the
    // bounded scroller replaces this child on the next frame.
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset),
    );
  }
}

class _AiNearbyNoteDelegate extends SingleChildLayoutDelegate {
  _AiNearbyNoteDelegate({
    required this.anchor,
    required this.padding,
    required this.maxHeight,
  });

  final Rect? anchor;
  final EdgeInsets padding;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math
        .min(380.0, constraints.maxWidth - padding.horizontal - 16)
        .clamp(0.0, 380.0)
        .toDouble();
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.min(maxHeight, constraints.maxHeight).clamp(0.0, maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final leftLimit = 8 + padding.left;
    final topLimit = 8 + padding.top;
    final rightLimit = size.width - 8 - padding.right - childSize.width;
    final bottomLimit = size.height - 8 - padding.bottom - childSize.height;
    double clampX(double value) =>
        value.clamp(leftLimit, math.max(leftLimit, rightLimit)).toDouble();
    double clampY(double value) =>
        value.clamp(topLimit, math.max(topLimit, bottomLimit)).toDouble();
    if (anchor == null) {
      return Offset(
        clampX((size.width - childSize.width) / 2),
        clampY((size.height - childSize.height) / 2),
      );
    }
    // Grow away from the nearer screen edge so the note stays next to the
    // control instead of covering it or jumping to the middle of the page.
    final growLeft = anchor!.center.dx > size.width * .55;
    final left = clampX(
      growLeft ? anchor!.right - childSize.width : anchor!.left,
    );
    final below = anchor!.bottom + 6;
    final above = anchor!.top - 6 - childSize.height;
    final top = below <= math.max(topLimit, bottomLimit)
        ? clampY(below)
        : clampY(above);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_AiNearbyNoteDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      maxHeight != oldDelegate.maxHeight;
}
