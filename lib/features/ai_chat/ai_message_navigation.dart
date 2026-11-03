import 'dart:async';
import '../../services/app_haptics.dart';
import '../../services/settings_service.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'ai_chat_models.dart';
import 'ai_chat_reading_state.dart';
import 'ai_chat_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import '../../widgets/visibility_input_gate.dart';
export 'ai_chat_reading_state.dart' show AiMessageBookmark;

class AiMessageViewportController extends ChangeNotifier {
  _AiMessageViewportState? _view;
  bool get hasClients => _view?._items.isAttached ?? false;
  bool get awayFromBottom => _view?._awayFromBottom ?? false;
  bool get isUserScrolling => _view?._userScrolling ?? false;
  AiMessageBookmark? get bookmark => _view?._bookmark;

  void scrollToEnd() => _view?._end();
  void restore(AiMessageBookmark bookmark) => _view?._restore(bookmark);
  void _changed() => notifyListeners();
}

/// Indexed lazy rendering makes even an unmounted question an exact jump
/// target. Pixel estimates affect only the overview, never the jump target.
class AiMessageViewport extends StatefulWidget {
  const AiMessageViewport({
    super.key,
    required this.messages,
    required this.controller,
    required this.itemBuilder,
    required this.onNavigate,
    required this.onUserScroll,
    this.onUserScrollStart,
    this.onReachedEnd,
    this.initialBookmark,
    this.followOutput = false,
    this.initialAtEnd = false,
    this.presentationKey,
    this.isFollowingOutput,
  });

  final List<AiChatMessage> messages;
  final AiMessageViewportController controller;
  final Widget Function(BuildContext, AiChatMessage) itemBuilder;
  final VoidCallback onNavigate;
  final bool Function(UserScrollNotification) onUserScroll;
  final VoidCallback? onUserScrollStart;
  final VoidCallback? onReachedEnd;
  final AiMessageBookmark? initialBookmark;
  final bool followOutput;
  // Read live intent even between a gesture and the next streamed rebuild.
  final ValueGetter<bool>? isFollowingOutput;
  final bool initialAtEnd;

  /// Non-message state that changes card actions or reasoning presentation.
  final Object? presentationKey;

  @override
  State<AiMessageViewport> createState() => _AiMessageViewportState();
}

class _NodeGroup {
  _NodeGroup(this.y, this.messages);
  final double y;
  final List<AiChatMessage> messages;
}

class _AiMessageViewportState extends State<AiMessageViewport> {
  // Share one visual axis even when the thumb widens on hover or drag.
  static const _railInset = 12.0;
  final _items = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _heights = <String, double>{};
  final _heightSources = <String, AiChatMessage>{};
  final _estimates = <String, (AiChatMessage, double)>{};
  final _rendered = <String, RenderBox>{};
  final _builtMessages = <String, Widget>{};
  final _builtSources = <String, AiChatMessage>{};
  ThemeData? _messageTheme;
  Widget? _cachedList;
  late List<AiChatMessage> _messages;
  bool _userScrolling = false;
  bool _streamUpdatePending = false;
  Timer? _scrollIdleTimer;

  final _railFocus = FocusNode(debugLabel: 'AiMessageNavigation');
  ScrollPosition? _position;
  AiMessageBookmark? _bookmark;
  List<double> _offsets = [0];
  List<_NodeGroup> _groups = [];
  List<AiChatMessage> _questions = [];
  Size _size = Size.zero;
  double _textScale = 1;
  bool _awayFromBottom = false;
  bool _geometryScheduled = false;
  bool _dragging = false;
  bool _pinned = false;
  bool _hovering = false;
  double _dragGrab = 0;
  double? _dragFraction;
  _NodeGroup? _preview;
  Timer? _hideTimer;
  int _request = 0;
  bool _entrySettled = true;

  bool get _followsOutput =>
      widget.isFollowingOutput?.call() ?? widget.followOutput;

  double get _viewportAnchor {
    for (final render in _rendered.values) {
      if (!render.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(render);
      if (viewport is RenderViewport) return viewport.anchor;
    }
    return 0;
  }

  double _messageTop(RenderBox render, RenderViewportBase viewport) =>
      viewport.getOffsetToReveal(render, 0).offset -
      viewport.offset.pixels +
      (viewport is RenderViewport ? viewport.anchor * viewport.size.height : 0);

  bool get _pinTailDuringLayout {
    if (!_entrySettled ||
        !_followsOutput ||
        _userScrolling ||
        _dragging ||
        _messages.isEmpty) {
      return false;
    }
    return _rendered[_messages.last.id]?.attached ?? false;
  }

  @override
  void initState() {
    super.initState();
    _messages = widget.messages;
    widget.controller._view = this;
    _positions.itemPositions.addListener(_positionsChanged);
    _questions = _messages.where((m) => m.role == 'user').toList();
    _bookmark = widget.initialBookmark;
    _entrySettled = _bookmark == null && !widget.initialAtEnd;
    if (!_entrySettled) {
      final request = _request;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (request == _request) {
          if (widget.initialBookmark != null) {
            _restore(widget.initialBookmark!);
          } else {
            _end();
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (widget.initialAtEnd) _end();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _entrySettled = true);
          });
          WidgetsBinding.instance.ensureVisualUpdate();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedList = null;
    final theme = Theme.of(context);
    if (_messageTheme != theme) {
      _messageTheme = theme;
      _builtMessages.clear();
      _builtSources.clear();
    }
  }

  @override
  void didUpdateWidget(AiMessageViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final presentationChanged =
        oldWidget.presentationKey != widget.presentationKey ||
        oldWidget.itemBuilder != widget.itemBuilder;
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._view = null;
      widget.controller._view = this;
    }
    // Parsing a growing Markdown answer can consume an entire scroll frame.
    // Keep the displayed snapshot stable through dragging and inertia; the
    // controller continues receiving and saving every delta in the meantime.
    // Structural, presentation and completion changes still apply immediately.
    if (!presentationChanged &&
        _userScrolling &&
        _isStreamingUpdate(widget.messages)) {
      _streamUpdatePending = true;
      return;
    }
    _applyMessages(clearPresentation: presentationChanged);
  }

  bool _isStreamingUpdate(List<AiChatMessage> messages) {
    if (_messages.isEmpty || messages.length != _messages.length) return false;
    final before = _messages.last;
    final after = messages.last;
    if (before.id != after.id ||
        before.role != 'assistant' ||
        after.role != 'assistant' ||
        before.status != 'streaming' ||
        after.status != 'streaming') {
      return false;
    }
    for (var i = 0; i < messages.length - 1; i++) {
      if (!identical(_messages[i], messages[i])) return false;
    }
    return true;
  }

  void _applyMessages({bool clearPresentation = false}) {
    _cachedList = null;
    final oldMessages = _messages;
    _messages = widget.messages;
    _streamUpdatePending = false;
    if (clearPresentation) {
      _builtMessages.clear();
      _builtSources.clear();
    } else {
      for (final message in _messages) {
        final source = _builtSources[message.id];
        if (source != null && !identical(source, message)) {
          _builtMessages.remove(message.id);
          _builtSources.remove(message.id);
        }
      }
    }
    final oldIds = oldMessages.map((m) => m.id).toList();
    final ids = _messages.map((m) => m.id).toSet();
    final structureChanged =
        oldIds.length != _messages.length ||
        oldIds.asMap().entries.any(
          (e) => e.key >= _messages.length || _messages[e.key].id != e.value,
        );
    _questions = _messages.where((m) => m.role == 'user').toList();
    _heights.removeWhere((id, _) => !ids.contains(id));
    _heightSources.removeWhere((id, _) => !ids.contains(id));
    _estimates.removeWhere((id, _) => !ids.contains(id));
    _builtMessages.removeWhere((id, _) => !ids.contains(id));
    _builtSources.removeWhere((id, _) => !ids.contains(id));
    if (structureChanged) {
      ++_request;
      _dragging = false;
      _dragFraction = null;
      _preview = null;
      _pinned = false;
      var anchor = _bookmark;
      if (anchor != null && !ids.contains(anchor.messageId)) {
        final before = oldIds.indexOf(anchor.messageId);
        final survivors = oldIds.take(math.max(0, before)).where(ids.contains);
        anchor = survivors.isEmpty
            ? null
            : AiMessageBookmark(survivors.last, 0, 0);
      }
      if (anchor != null && !_followsOutput) {
        final restore = anchor;
        final request = _request;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && request == _request) _restore(restore);
        });
      }
    } else if (_preview != null) {
      // Refresh text/time without retaining obsolete message instances.
      final previewIds = _preview!.messages.map((m) => m.id).toSet();
      _preview = _NodeGroup(
        _preview!.y,
        _questions.where((m) => previewIds.contains(m.id)).toList(),
      );
    }
    _geometry();
  }

  void _startUserScroll() {
    _scrollIdleTimer?.cancel();
    if (!_userScrolling) ++_request;
    _userScrolling = true;
  }

  void _finishUserScroll() {
    // Rail seeks use jumpTo, whose ScrollEndNotification does not mean the
    // pointer has released the thumb.
    if (!_userScrolling || _dragging) return;
    _scrollIdleTimer?.cancel();
    // Wheel events each emit their own start/end pair. A short quiet period
    // keeps a continuous wheel/trackpad gesture in one batch as well.
    _scrollIdleTimer = Timer(const Duration(milliseconds: 100), () {
      _userScrolling = false;
      if (!mounted || !_streamUpdatePending) return;
      setState(_applyMessages);
    });
  }

  void _positionsChanged() {
    if (!mounted) return;
    final visible =
        _positions.itemPositions.value
            .where(
              (p) => p.itemTrailingEdge > .0001 && p.itemLeadingEdge < .9999,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isNotEmpty) {
      final first = visible.first;
      if (first.index < _messages.length) {
        final message = _messages[first.index];
        final span = first.itemTrailingEdge - first.itemLeadingEdge;
        var alignment = first.itemLeadingEdge;
        var fraction = span <= 0
            ? 0.0
            : (-first.itemLeadingEdge / span).clamp(0.0, 1.0);
        final render = _rendered[message.id];
        final viewport = render != null && render.attached && render.hasSize
            ? RenderAbstractViewport.maybeOf(render)
            : null;
        if (viewport is RenderViewportBase &&
            viewport.hasSize &&
            viewport.size.height > 0) {
          // ItemPositions rounds to whole pixels. Preserve the real geometry so
          // repeated popup/fullscreen/resize round trips cannot accumulate it.
          final top = _messageTop(render!, viewport);
          alignment = top / viewport.size.height;
          fraction = render.size.height <= 0
              ? 0
              : (-top / render.size.height).clamp(0.0, 1.0);
        }
        _bookmark = AiMessageBookmark(message.id, alignment, fraction);
      }
      _awayFromBottom = !visible.any(
        (p) => p.index == _messages.length && p.itemTrailingEdge <= 1.01,
      );
    }
    widget.controller._changed();
  }

  bool _notification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.context != null) {
      _position = Scrollable.maybeOf(notification.context!)?.position;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _startUserScroll();
      widget.onUserScrollStart?.call();
    } else if (notification is ScrollEndNotification) {
      _finishUserScroll();
    }
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        _finishUserScroll();
      } else {
        _startUserScroll();
      }
      widget.onUserScroll(notification);
      if (notification.direction != ScrollDirection.idle) _dismiss();
    }
    return false;
  }

  void _end() {
    _scrollIdleTimer?.cancel();
    _userScrolling = _dragging;
    if (_streamUpdatePending && !_dragging) setState(_applyMessages);
    if (!_items.isAttached || _messages.isEmpty) return;
    ++_request;
    // Reaching the end of a short document means showing the entire document
    // at the top, not leaving blank space above its first exchange.
    var height = 22.0; // top padding and the trailing sentinel
    var fullyMeasured = true;
    for (final message in _messages) {
      if (!identical(_heightSources[message.id], message)) {
        fullyMeasured = false;
        break;
      }
      height += _heights[message.id]!;
    }
    if (fullyMeasured && height <= _size.height + .5) {
      final first = _positions.itemPositions.value.where((p) => p.index == 0);
      if (first.isEmpty ||
          (first.first.itemLeadingEdge * _size.height - 10).abs() > .5) {
        _items.jumpTo(index: 0);
      }
      return;
    }
    final last = _rendered[_messages.last.id];
    if (last == null || !last.attached) {
      // Center on the answer, not the sentinel: expanding its reasoning must
      // grow downward while reading, rather than pinning the bottom in place.
      _items.jumpTo(index: _messages.length - 1);
    }
    final p = _position;
    if (last != null &&
        last.attached &&
        identical(_heightSources[_messages.last.id], _messages.last) &&
        p != null &&
        p.hasContentDimensions) {
      _jumpToEndIfNeeded(p);
      return;
    }
    final request = _request;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _request) return;
      final p = _position;
      if (p != null && p.hasContentDimensions) _jumpToEndIfNeeded(p);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _jumpToEndIfNeeded(ScrollPosition position) {
    if ((position.pixels - position.maxScrollExtent).abs() > .5) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  void _restore(AiMessageBookmark bookmark) {
    final index = _messages.indexWhere((m) => m.id == bookmark.messageId);
    if (index < 0 || !_items.isAttached) return;
    _jump(
      index,
      bookmark.alignment.clamp(0.0, 1.0),
      fraction: bookmark.fraction,
      forceIndex: bookmark.messageId != _bookmark?.messageId,
    );
  }

  void _jump(
    int index,
    double alignment, {
    double fraction = 0,
    bool forceIndex = false,
  }) {
    if (!_items.isAttached) return;
    final request = ++_request;
    if (fraction <= 0 && forceIndex) {
      // Index anchoring also excludes the previous card's trailing padding
      // from the reading bookmark, even when starting from a tail anchor.
      _items.jumpTo(index: index, alignment: alignment);
      return;
    }
    final render = _rendered[_messages[index].id];
    final position = _position;
    if (render != null &&
        render.attached &&
        position != null &&
        position.hasContentDimensions) {
      final viewport = RenderAbstractViewport.maybeOf(render);
      if (viewport is RenderViewportBase) {
        // Positioned lists can keep their origin at a nonzero viewport anchor.
        // Restore the physical point within the message, not an offset relative
        // to that origin. This also keeps positive bookmark alignments stable.
        final top = _messageTop(render, viewport);
        final offset =
            position.pixels +
            top +
            render.size.height * fraction -
            position.viewportDimension * alignment;
        // A cached message may lie outside the current center list's legal
        // pixel range (especially after opening at the tail). Re-anchor by
        // index instead of clamping to a different message's visible edge.
        if (offset >= position.minScrollExtent - .5 &&
            offset <= position.maxScrollExtent + .5) {
          position.jumpTo(
            offset.clamp(position.minScrollExtent, position.maxScrollExtent),
          );
          return;
        }
      }
    }
    _items.jumpTo(index: index, alignment: alignment);
    if (fraction <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _request || index >= _messages.length) {
        return;
      }
      final render = _rendered[_messages[index].id];
      final p = _position;
      if (render != null &&
          render.attached &&
          render.hasSize &&
          p != null &&
          p.hasContentDimensions) {
        final viewport = RenderAbstractViewport.maybeOf(render);
        if (viewport is RenderViewportBase) {
          // The freshly mounted first item can include leading list padding.
          // Use the same physical reading point as the already-mounted path.
          final offset =
              p.pixels +
              _messageTop(render, viewport) +
              render.size.height * fraction -
              p.viewportDimension * alignment;
          p.jumpTo(offset.clamp(p.minScrollExtent, p.maxScrollExtent));
        }
      }
    });
  }

  void _go(AiChatMessage message) {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index < 0) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    widget.onNavigate();
    _dismiss();
    _jump(index, 0, forceIndex: true);
  }

  void _measure(AiChatMessage message, double height) {
    if (_heights[message.id] == height &&
        identical(_heightSources[message.id], message)) {
      return;
    }
    _heights[message.id] = height;
    _heightSources[message.id] = message;
    if (_geometryScheduled) return;
    _geometryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryScheduled = false;
      if (!mounted || _dragging) return;
      setState(_geometry);
    });
  }

  double _estimate(AiChatMessage message) {
    final cached = _estimates[message.id];
    if (cached != null && identical(cached.$1, message)) return cached.$2;
    final columns = math.max(
      8.0,
      math.min(840, _size.width - 56) / (7 * _textScale),
    );
    final text = message.content;
    final lines = text
        .split('\n')
        .fold<double>(
          0,
          (sum, line) => sum + math.max(1, (line.length / columns).ceil()),
        );
    final height =
        64 + lines * 21 * _textScale + (message.reasoning.isEmpty ? 0 : 48);
    _estimates[message.id] = (message, height);
    return height;
  }

  void _geometry() {
    if (_dragging || _size.isEmpty) return;
    _offsets = [0];
    for (final message in _messages) {
      final measured = _heights[message.id];
      // A mounted card will report its new height during layout. Until then,
      // keep the last measurement paired with the current item positions;
      // substituting a text estimate makes the thumb jump on every delta.
      final useMeasured =
          measured != null &&
          (identical(_heightSources[message.id], message) ||
              (_rendered[message.id]?.attached ?? false));
      _offsets.add(
        _offsets.last + (useMeasured ? measured : _estimate(message)),
      );
    }
    final marks = <(AiChatMessage, double)>[];
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].role == 'user') {
        final y =
            22 +
            (_offsets[i] / math.max(1, _offsets.last)) *
                math.max(0, _size.height - 44);
        marks.add((_messages[i], y));
      }
    }
    final capacity = math.max(1, (_size.height / 44).floor());
    if (marks.length <= capacity) {
      final ys = <double>[];
      for (final mark in marks) {
        ys.add(math.max(mark.$2, ys.isEmpty ? 22 : ys.last + 44));
      }
      for (var i = ys.length - 1; i >= 0; i--) {
        ys[i] = math.min(
          ys[i],
          i == ys.length - 1 ? _size.height - 22 : ys[i + 1] - 44,
        );
      }
      _groups = [
        for (var i = 0; i < marks.length; i++) _NodeGroup(ys[i], [marks[i].$1]),
      ];
    } else {
      final bins = <int, List<AiChatMessage>>{};
      for (final mark in marks) {
        final slot = capacity == 1
            ? 0
            : ((mark.$2 - 22) / math.max(1, _size.height - 44) * (capacity - 1))
                  .round();
        bins.putIfAbsent(slot, () => []).add(mark.$1);
      }
      _groups = [
        for (final bin in bins.entries)
          _NodeGroup(
            capacity == 1
                ? _size.height / 2
                : 22 + bin.key * (_size.height - 44) / (capacity - 1),
            bin.value,
          ),
      ];
    }
  }

  (double, double) get _window {
    double? start;
    double? end;
    for (final p in _positions.itemPositions.value) {
      if (p.index >= _messages.length ||
          p.itemTrailingEdge <= 0 ||
          p.itemLeadingEdge >= 1 ||
          p.index + 1 >= _offsets.length) {
        continue;
      }
      final height = _offsets[p.index + 1] - _offsets[p.index];
      final span = p.itemTrailingEdge - p.itemLeadingEdge;
      if (span <= 0) continue;
      final a =
          _offsets[p.index] + height * (-p.itemLeadingEdge / span).clamp(0, 1);
      final b =
          _offsets[p.index] +
          height * ((1 - p.itemLeadingEdge) / span).clamp(0, 1);
      start = start == null ? a : math.min(start, a);
      end = end == null ? b : math.max(end, b);
    }
    final total = math.max(1.0, _offsets.last);
    return ((start ?? 0) / total, (end ?? total) / total);
  }

  (double, double) get _thumb {
    final (start, end) = _window;
    final track = math.max(0.0, _size.height - 16);
    // A streaming answer changes the content ratio continuously. Keep the
    // grab target stable; only a very short viewport needs a smaller thumb
    // so at least half of the track remains available for dragging.
    final height = math.min(48.0, track / 2);
    final fraction =
        _dragFraction ??
        (start / math.max(.0001, 1 - (end - start))).clamp(0.0, 1.0);
    return (8 + (track - height) * fraction, height);
  }

  void _seek(double y) {
    if (_messages.isEmpty) return;
    final (_, height) = _thumb;
    final fraction =
        ((y - 8 - _dragGrab) / math.max(1, _size.height - 16 - height)).clamp(
          0.0,
          1.0,
        );
    _dragFraction = fraction;
    widget.onNavigate();
    if (fraction >= .999) {
      widget.onReachedEnd?.call();
      _end();
      return;
    }
    final target = fraction * math.max(0.0, _offsets.last - _size.height);
    var low = 0;
    var high = _messages.length;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (_offsets[mid] <= target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final span = _offsets[low + 1] - _offsets[low];
    _jump(low, 0, fraction: (target - _offsets[low]) / math.max(1, span));
  }

  _NodeGroup? _nearest(double y) {
    _NodeGroup? nearest;
    for (final group in _groups) {
      if ((group.y - y).abs() <= 22 &&
          (nearest == null || (group.y - y).abs() < (nearest.y - y).abs())) {
        nearest = group;
      }
    }
    return nearest;
  }

  void _show(_NodeGroup group, {bool pinned = false}) {
    _hideTimer?.cancel();
    if (_dragging) return;
    if (identical(_preview, group) && _pinned == pinned) return;
    setState(() {
      _preview = group;
      _pinned = pinned;
    });
  }

  void _dismiss() {
    _hideTimer?.cancel();
    if (_preview != null && mounted) {
      setState(() {
        _preview = null;
        _pinned = false;
      });
    }
  }

  void _hideLater() {
    if (_pinned) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 180), _dismiss);
  }

  String _date(AiChatMessage message) {
    final date = message.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  String _question(AiChatMessage message) => message.content.trim().isEmpty
      ? '（空提问）'
      : message.content.replaceAll(RegExp(r'\s+'), ' ').trim();

  Widget _previewCard(ColorScheme colors) {
    final preview = _preview!;
    final multiple = preview.messages.length > 1;
    final maxHeight = math.min(multiple ? 328.0 : 148.0, _size.height - 12);
    final short = _size.height < 172;
    const right = _railInset + 4 + 6;
    final width = math.min(312.0, _size.width - right - 8);
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _NodePreviewLayout(
          nodeY: preview.y,
          right: right,
          width: width,
          maxHeight: maxHeight,
        ),
        child: MouseRegion(
          onEnter: (_) => _hideTimer?.cancel(),
          onExit: (_) => _hideLater(),
          child: TapRegion(
            onTapOutside: (_) {
              if (_pinned) _dismiss();
            },
            child: Material(
              key: const ValueKey('ai-node-preview'),
              color: colors.surfaceContainerHigh,
              elevation: 6,
              shadowColor: Colors.black54,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: math.max(0, maxHeight)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (multiple && !short)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${preview.messages.length} 个提问',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: DesktopButtonClickRegion(
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  tooltip: '关闭预览',
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: _dismiss,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Flexible(
                      child: ListView.builder(
                        key: const ValueKey('ai-node-preview-list'),
                        primary: false,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: preview.messages.length,
                        itemBuilder: (context, index) {
                          final message = preview.messages[index];
                          return InkWell(
                            key: ValueKey('ai-node-preview-${message.id}'),
                            onTap: () => _go(message),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: short ? 4 : 10,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _question(message),
                                    maxLines: short
                                        ? 1
                                        : multiple
                                        ? 2
                                        : 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _date(message),
                                    style: TextStyle(
                                      fontSize: 11,
                                      height: 1.2,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (_questions.isEmpty) return KeyEventResult.ignored;
    var index = _questions.indexWhere((m) => m.id == _activeQuestion);
    if (key == LogicalKeyboardKey.arrowUp) {
      index = math.max(0, index - 1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      index = math.min(_questions.length - 1, index + 1);
    } else if (key == LogicalKeyboardKey.home) {
      index = 0;
    } else if (key == LogicalKeyboardKey.end) {
      widget.onNavigate();
      widget.onReachedEnd?.call();
      _end();
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }
    _go(_questions[index]);
    return KeyEventResult.handled;
  }

  String? get _activeQuestion {
    final anchor = _bookmark;
    if (anchor == null) return null;
    final index = _messages.indexWhere((m) => m.id == anchor.messageId);
    for (var i = index; i >= 0; i--) {
      if (_messages[i].role == 'user') return _messages[i].id;
    }
    return null;
  }

  Widget _rail(ColorScheme colors) {
    final (top, height) = _thumb;
    final active = _activeQuestion;
    final thumbWidth = _dragging || _hovering ? 9.0 : 7.0;
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: 44,
      child: Focus(
        focusNode: _railFocus,
        onKeyEvent: _key,
        child: MouseRegion(
          cursor: _dragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) {
            setState(() => _hovering = false);
            _hideLater();
          },
          onHover: (event) {
            final group = _nearest(event.localPosition.dy);
            if (group != null) {
              _show(group);
            } else {
              _hideLater();
            }
          },
          child: GestureDetector(
            key: const ValueKey('ai-message-navigation'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              _railFocus.requestFocus();
              final group = _nearest(details.localPosition.dy);
              if (group == null) {
                _dragGrab = height / 2;
                _seek(details.localPosition.dy);
                _dragFraction = null;
              } else if (group.messages.length == 1) {
                _go(group.messages.single);
              } else {
                _show(group, pinned: true);
              }
            },
            onLongPressStart: (details) {
              final group = _nearest(details.localPosition.dy);
              if (group != null) _show(group, pinned: true);
            },
            onLongPressMoveUpdate: (details) {
              final group = _nearest(details.localPosition.dy);
              if (group != null) _show(group, pinned: true);
            },
            onVerticalDragStart: (details) {
              _startUserScroll();
              _dismiss();
              _railFocus.requestFocus();
              final y = details.localPosition.dy;
              _dragGrab = y >= top - 12 && y <= top + height + 12
                  ? (y - top).clamp(0, height)
                  : height / 2;
              setState(() => _dragging = true);
              _seek(y);
            },
            onVerticalDragUpdate: (details) {
              _seek(details.localPosition.dy);
              setState(() {});
            },
            onVerticalDragEnd: (_) => setState(() {
              _dragging = false;
              _finishUserScroll();
              _dragFraction = null;
              _geometry();
            }),
            onVerticalDragCancel: () => setState(() {
              _dragging = false;
              _finishUserScroll();
              _dragFraction = null;
              _geometry();
            }),
            child: Stack(
              children: [
                Positioned(
                  top: 8,
                  bottom: 8,
                  right: _railInset - 1,
                  width: 2,
                  child: ColoredBox(
                    color: colors.onSurface.withValues(alpha: .10),
                  ),
                ),
                if (_awayFromBottom ||
                    _window.$1 > .001 ||
                    _window.$2 - _window.$1 < .995)
                  Positioned(
                    top: top,
                    right: _railInset - thumbWidth / 2,
                    width: thumbWidth,
                    height: height,
                    child: Container(
                      key: const ValueKey('ai-navigation-thumb'),
                      decoration: BoxDecoration(
                        color: colors.onSurface.withValues(
                          alpha: _dragging || _hovering ? .36 : .26,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                for (final group in _groups)
                  Positioned(
                    top: group.y - 22,
                    right: 0,
                    width: 44,
                    height: 44,
                    child: Semantics(
                      button: true,
                      label: group.messages.length == 1
                          ? '${_question(group.messages.single)}，${_date(group.messages.single)}'
                          : '${group.messages.length} 个提问，展开选择',
                      onTap: () => group.messages.length == 1
                          ? _go(group.messages.single)
                          : _show(group, pinned: true),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: _railInset - 4),
                          child: Container(
                            key: ValueKey('ai-node-${group.messages.first.id}'),
                            width: 8,
                            height: group.messages.length > 1 ? 15 : 8,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: colors.onSurface.withValues(
                                alpha: group.messages.any((m) => m.id == active)
                                    ? 1.0
                                    : .52,
                              ),
                              border: group.messages.length > 1
                                  ? Border.all(
                                      color: colors.onSurface.withValues(
                                        alpha: .28,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final typography = AiChatTypography.of(context);
      final scale =
          MediaQuery.textScalerOf(context).scale(typography.fontSize) / 14;
      if (_size != size || _textScale != scale) {
        final anchor = _bookmark;
        final reflow = _size.width != size.width || _textScale != scale;
        if (reflow) {
          _cachedList = null;
          _heights.clear();
          _heightSources.clear();
          _estimates.clear();
        }
        _size = size;
        _textScale = scale;
        _preview = null;
        _pinned = false;
        _geometry();
        // Height-only changes (including each keyboard animation frame) are
        // corrected by scroll physics before paint, not a delayed jump back to
        // a stale fractional bookmark that fights streamed tail following.
        if (reflow && anchor != null && !_followsOutput) {
          final request = _request;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && request == _request) _restore(anchor);
          });
        }
      }
      final colors = Theme.of(context).colorScheme;
      return VisibilityInputGate(
        enabled: _entrySettled,
        child: Opacity(
          opacity: _entrySettled ? 1 : 0,
          child: AnimatedBuilder(
            animation: widget.controller,
            child: _cachedList ??= NotificationListener<ScrollMetricsNotification>(
              onNotification: (notification) {
                if (notification.depth == 0) {
                  _position = Scrollable.maybeOf(
                    notification.context,
                  )?.position;
                }
                return false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _notification,
                child: ScrollConfiguration(
                  key: const PageStorageKey('ai-message-positioned-scroll'),
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: ScrollablePositionedList.builder(
                    key: const ValueKey('ai-chat-messages'),
                    itemScrollController: _items,
                    itemPositionsListener: _positions,
                    itemCount: _messages.length + 1,
                    physics: _ReadingLayoutPhysics(
                      pinTail: () => _pinTailDuringLayout,
                      viewportAnchor: () => _viewportAnchor,
                    ),
                    // Lay out the tail first instead of mounting the beginning
                    // and scrolling through it. No animation, even for huge logs.
                    initialScrollIndex: widget.initialAtEnd
                        ? math.max(0, _messages.length - 1)
                        : math.max(
                            0,
                            _messages.indexWhere(
                              (m) => m.id == widget.initialBookmark?.messageId,
                            ),
                          ),
                    initialAlignment: widget.initialAtEnd
                        ? 1
                        : (widget.initialBookmark?.alignment ?? 0).clamp(
                            0.0,
                            1.0,
                          ),
                    // Reserve the rail's entire hit target so it cannot intercept
                    // text selection or taps on a reasoning card's right padding.
                    padding: typography.dense
                        ? const EdgeInsets.fromLTRB(8, 6, 44, 0)
                        : const EdgeInsets.fromLTRB(12, 10, 44, 0),
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return const SizedBox(height: 12);
                      }
                      final message = _messages[index];
                      return _MeasuredMessage(
                        key: PageStorageKey(message.id),
                        onHeight: (height) => _measure(message, height),
                        onAttach: (render) => _rendered[message.id] = render,
                        onDetach: (render) {
                          if (_rendered[message.id] == render) {
                            _rendered.remove(message.id);
                            // Re-anchoring/resizing can detach and attach the same
                            // lazy card across two frames. Retain its parsed body
                            // through that handoff, then evict truly hidden cards.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted &&
                                    !_rendered.containsKey(message.id)) {
                                  _builtMessages.remove(message.id);
                                  _builtSources.remove(message.id);
                                }
                              });
                              if (mounted) {
                                WidgetsBinding.instance.ensureVisualUpdate();
                              }
                            });
                          }
                        },
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 840),
                            child: RepaintBoundary(
                              child: _builtMessages.putIfAbsent(message.id, () {
                                _builtSources[message.id] = message;
                                return widget.itemBuilder(context, message);
                              }),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            builder: (context, child) => Stack(
              clipBehavior: Clip.hardEdge,
              fit: StackFit.expand,
              children: [
                child!,
                if (_questions.isNotEmpty &&
                    _size.height >= 44 &&
                    _size.width >= 160)
                  _rail(colors),
                if (_preview != null &&
                    _size.height >= 64 &&
                    _size.width >= 160)
                  _previewCard(colors),
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    ++_request;
    _scrollIdleTimer?.cancel();
    _hideTimer?.cancel();
    _railFocus.dispose();
    _positions.itemPositions.removeListener(_positionsChanged);
    if (widget.controller._view == this) widget.controller._view = null;
    super.dispose();
  }
}

/// Position from the actual card height so short previews point at the node
/// just as clearly as the taller grouped question list.
class _NodePreviewLayout extends SingleChildLayoutDelegate {
  const _NodePreviewLayout({
    required this.nodeY,
    required this.right,
    required this.width,
    required this.maxHeight,
  });

  final double nodeY;
  final double right;
  final double width;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: maxHeight);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    size.width - right - childSize.width,
    (nodeY - childSize.height / 2).clamp(
      6.0,
      math.max(6.0, size.height - childSize.height - 6),
    ),
  );

  @override
  bool shouldRelayout(_NodePreviewLayout oldDelegate) =>
      nodeY != oldDelegate.nodeY ||
      right != oldDelegate.right ||
      width != oldDelegate.width ||
      maxHeight != oldDelegate.maxHeight;
}

/// Correct growing content and keyboard resizes inside viewport layout. No
/// scroll activity/animation or after-paint catch-up frame is needed.
class _ReadingLayoutPhysics extends ScrollPhysics {
  const _ReadingLayoutPhysics({
    required this.pinTail,
    required this.viewportAnchor,
    super.parent,
  });

  final ValueGetter<bool> pinTail;
  final ValueGetter<double> viewportAnchor;

  @override
  _ReadingLayoutPhysics applyTo(ScrollPhysics? ancestor) =>
      _ReadingLayoutPhysics(
        pinTail: pinTail,
        viewportAnchor: viewportAnchor,
        parent: buildParent(ancestor),
      );

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (!isScrolling && velocity == 0) {
      if (pinTail()) return newPosition.maxScrollExtent;
      final delta =
          newPosition.viewportDimension - oldPosition.viewportDimension;
      if (delta != 0) {
        // An indexed list can have a nonzero viewport anchor. Keep its visible
        // content at the same physical offset as the reading region resizes.
        return (oldPosition.pixels + delta * viewportAnchor()).clamp(
          newPosition.minScrollExtent,
          newPosition.maxScrollExtent,
        );
      }
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

class _MeasuredMessage extends SingleChildRenderObjectWidget {
  const _MeasuredMessage({
    super.key,
    required this.onHeight,
    required this.onAttach,
    required this.onDetach,
    required super.child,
  });
  final ValueChanged<double> onHeight;
  final ValueChanged<RenderBox> onAttach;
  final ValueChanged<RenderBox> onDetach;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MessageExtent(onHeight, onAttach, onDetach);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _MessageExtent renderObject,
  ) {
    renderObject.onHeight = onHeight;
    renderObject.onAttach = onAttach;
    renderObject.onDetach = onDetach;
  }
}

class _MessageExtent extends RenderProxyBox {
  _MessageExtent(this.onHeight, this.onAttach, this.onDetach);
  ValueChanged<double> onHeight;
  ValueChanged<RenderBox> onAttach;
  ValueChanged<RenderBox> onDetach;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    onAttach(this);
  }

  @override
  void detach() {
    onDetach(this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
