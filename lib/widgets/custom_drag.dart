import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'button_aware_drag.dart';
import 'desktop_button_click_region.dart';

/// 桌面端拖拽启动阈值（逻辑像素）。
///
/// 鼠标按下后位移超过该距离才视为一次「拖拽」，否则保持为一次点击。
/// 使用固定的逻辑像素值（与卡片尺寸、屏幕分辨率/DPI 无关），在任何显示
/// 环境下都能可靠区分「点击」与「拖拽」，同时数值不会过大而导致真正的
/// 拖拽响应迟钝。
const double kDragStartThreshold = 10.0;

/// 卡片正在被拖着换位置时，把当前指针交给外层做边缘自动滚动。
///
/// [pointer] / [viewId] / [kind] 要和按下时一致，外层才能在列表滚动后
/// 补一次命中测试，而不会被手势系统当成一根新指针。
typedef MediaLibraryCardDragUpdate =
    void Function(
      Offset globalPosition,
      int pointer,
      int viewId,
      PointerDeviceKind kind,
    );

/// DropTarget 的轻量包装。
///
/// 之所以需要这层包装，是为了给所有 DropTarget 提供统一、简洁的 API，同时
/// 仍由 Flutter 原生 [DragTarget] 完成候选高亮与落点接收（原生 [Draggable]
/// 通过私有 _DragAvatar 驱动这些交互，外部无法注入，因此拖拽源必须保留
/// [Draggable]）。
class DropZone<T extends Object> extends StatelessWidget {
  const DropZone({
    super.key,
    required this.data,
    required this.builder,
    this.onWillAccept,
    this.onEnter,
    this.onLeave,
    this.onAcceptWithDetails,
  });

  /// 槽位标识（例如卡片 index），供拖拽数据判断是否可接收。
  final T data;

  /// 构建内容。[candidateData] 在拖拽悬停到本槽位且被接受时非空。
  final Widget Function(BuildContext context, List<T?> candidateData) builder;

  /// 拖拽数据尝试进入本槽位时调用，返回是否接受为候选（决定是否高亮）。
  final bool Function(T draggedData)? onWillAccept;

  final VoidCallback? onEnter;
  final VoidCallback? onLeave;

  /// 拖拽数据被释放到本槽位时调用。
  final void Function(T draggedData, Offset position)? onAcceptWithDetails;

  @override
  Widget build(BuildContext context) {
    return DragTarget<T>(
      onWillAcceptWithDetails: (details) {
        final accepted = onWillAccept?.call(details.data) ?? true;
        if (accepted) onEnter?.call();
        return accepted;
      },
      onLeave: (_) => onLeave?.call(),
      onAcceptWithDetails: (details) {
        onAcceptWithDetails?.call(details.data, details.offset);
      },
      builder: (context, candidateData, _) {
        return builder(context, candidateData);
      },
    );
  }
}

/// 位移/时长门控的桌面端拖拽源，替代默认的 [Draggable]。
///
/// Flutter 的 [Draggable] 对鼠标只使用 1 逻辑像素的启动 slop，导致点击时
/// 轻微移动鼠标就会被识别成拖拽（抢占点击、误入选择模式）。本组件保留原生
/// [Draggable]（用于与滚动手势正确竞争、并驱动 [DropZone] 的高亮与接收），
/// 但满足以下任一条件才真正触发 [onDragStarted]（进入选择模式）：
///  - 位移超过 [threshold]（拖动卡片）；
///  - 按住不松开超过 [longPressDuration]（长按卡片）。
///
/// 其余行为：
///  - 平台拖拽的反馈置为透明、拖拽中保持原样，避免点击时出现拖拽残影；
///  - 拖拽视觉反馈由本组件用 [feedback] 自行绘制，且仅在真正开始移动后出现，
///    避免「长按选中」时闪出拖拽残影；
///  - 位移已经超过内层点击容差、但还没到 [threshold] 时，原生 [Draggable]
///    已把这次操作判成非点击，通过 [onTap] 把点击语义补回来；
///  - 位移仍在点击容差内时不补偿。鼠标容差只有 1 逻辑像素，点击时的轻微
///    抖动经常落在这个区间；若这里也补一次，会和卡片内部 [InkWell] 各
///    触发一次，把同一播放页压进导航栈两次；
///  - 本次按住已经 armed 后，抬起时会在手势竞技场里抢占胜利，避免卡片内部
///    [InkWell] 把同一次松手再当成点击（否则会把刚选中的卡片立刻取消）。
class GatedDraggable<T extends Object> extends StatefulWidget {
  const GatedDraggable({
    super.key,
    required this.data,
    required this.feedback,
    required this.child,
    required this.onDragStarted,
    this.onTap,
    this.onDragPosition,
    this.onDragEnd,
    this.threshold = kDragStartThreshold,
    this.longPressDuration = const Duration(milliseconds: 320),
  });

  final T data;
  final Widget feedback;
  final Widget child;
  final VoidCallback onDragStarted;

  /// 点击补偿回调，见类注释。
  final VoidCallback? onTap;

  /// 拖拽残影已经出现后的指针位置。原地长按选中不回调，避免误滚列表。
  final MediaLibraryCardDragUpdate? onDragPosition;

  /// 本次按住曾经进入拖拽（含只长按、尚未移动）后松手或取消。
  final VoidCallback? onDragEnd;

  final double threshold;

  /// 按住超过该时长（且位移未达阈值）也进入选择模式，兼容「长按选中」习惯。
  final Duration longPressDuration;

  @override
  State<GatedDraggable<T>> createState() => _GatedDraggableState<T>();
}

class _GatedDraggableState<T extends Object> extends State<GatedDraggable<T>> {
  Offset? _downPosition;
  int? _activePointer;
  int? _activeViewId;
  PointerDeviceKind? _activeKind;
  bool _armed = false;
  Offset _feedbackPosition = Offset.zero;
  OverlayEntry? _feedbackEntry;
  Timer? _longPressTimer;
  _ArmedTapSuppressor? _tapSuppressor;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _disposeTapSuppressor();
    _removeFeedback();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    // 右键/中键不参与拖拽门控：否则轻微位移会被补偿成左键点击。
    if (event.buttons != kPrimaryButton ||
        DesktopButtonClickRegion.ownsPointer(event.pointer)) {
      return;
    }
    _longPressTimer?.cancel();
    _disposeTapSuppressor();
    _activePointer = event.pointer;
    _activeViewId = event.viewId;
    _activeKind = event.kind;
    _downPosition = event.position;
    _armed = false;

    // 从 pointer-down 就加入竞技场，才能在抬起时抢在 sweep 之前吞掉 InkWell 点击。
    // 不能在长按到期时就 accept：那会把原生 Draggable 挤掉，后续拖去排序/移入文件夹会失效。
    _tapSuppressor = _ArmedTapSuppressor();
    _tapSuppressor!.addPointer(event);

    // 长按选中：按住不动超过 longPressDuration 也进入选择模式。
    _longPressTimer = Timer(widget.longPressDuration, () {
      if (!_armed && _downPosition != null && mounted) {
        _arm(event.position, showFeedback: false);
      }
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    // 边缘自动滚动会把拖拽源滚出缓存，State 已卸载，但按下时的命中路径
    // 仍会把后续移动送过来。这时只更新滚速，不能再碰 context / Overlay。
    if (!mounted) {
      if (_armed) _reportDragPosition(event.position);
      return;
    }
    final down = _downPosition;
    if (down == null) return;
    if (!_armed) {
      final distance = (event.position - down).distance;
      if (distance < widget.threshold) return;
      _longPressTimer?.cancel();
      _arm(event.position, showFeedback: true);
    } else if (_feedbackEntry == null) {
      // 先长按选中、再开始移动：这时才出现拖拽残影。
      _showFeedback(event.position);
    } else {
      _updateFeedback(event.position);
    }
  }

  void _arm(Offset position, {required bool showFeedback}) {
    if (_armed) return;
    _armed = true;
    widget.onDragStarted();
    if (showFeedback) {
      _showFeedback(position);
    }
    if (mounted) setState(() {});
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    if (!mounted) {
      final armed = _armed;
      _clearPointer();
      if (armed) widget.onDragEnd?.call();
      return;
    }
    _longPressTimer?.cancel();
    final down = _downPosition;
    final armed = _armed;
    if (armed) {
      // Listener.onPointerUp 早于 GestureBinding 的 arena sweep。
      // 此时 accept 会立刻 reject 掉 InkWell 的 TapGestureRecognizer。
      _tapSuppressor?.stealTap();
    }
    if (down != null && !armed) {
      final distance = (event.position - down).distance;
      // 只在内层点击确定已被取消时补偿。鼠标的 Draggable 命中容差是 1
      // 逻辑像素，0 < 位移 <= 容差时 InkWell 仍会自己触发；再补一次就会
      // 把播放页 push 两层。触控容差大于拖拽阈值时，未达阈值的移动也仍由
      // InkWell 处理，这里同样不能补。
      if (distance > _innerTapCancelSlop(event.kind) &&
          distance < widget.threshold) {
        widget.onTap?.call();
      }
    }
    _disposeTapSuppressor();
    _removeFeedback();
    _clearPointer();
    if (armed) widget.onDragEnd?.call();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    if (!mounted) {
      final armed = _armed;
      _clearPointer();
      if (armed) widget.onDragEnd?.call();
      return;
    }
    _longPressTimer?.cancel();
    final armed = _armed;
    _disposeTapSuppressor();
    _removeFeedback();
    _clearPointer();
    if (armed) widget.onDragEnd?.call();
  }

  void _clearPointer() {
    _downPosition = null;
    _activePointer = null;
    _activeViewId = null;
    _activeKind = null;
    _armed = false;
  }

  void _disposeTapSuppressor() {
    _tapSuppressor?.dispose();
    _tapSuppressor = null;
  }

  /// 内层 [InkWell] / [GestureDetector] 不再把这次按下当成点击的最小位移。
  ///
  /// 取点击手势自身容差和竞争中的 [Draggable] 命中容差里更小的那个：谁先
  /// 越界，谁就会把另一次点击从竞技场里淘汰掉。
  double _innerTapCancelSlop(PointerDeviceKind kind) {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    final tapSlop = settings?.touchSlop ?? kTouchSlop;
    final dragSlop = computeHitSlop(kind, settings);
    return tapSlop < dragSlop ? tapSlop : dragSlop;
  }

  void _showFeedback(Offset position) {
    _reportDragPosition(position);
    if (!mounted) return;
    _feedbackPosition = position;
    _removeFeedback();
    _feedbackEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: _feedbackPosition.dx,
        top: _feedbackPosition.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: IgnorePointer(child: widget.feedback),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_feedbackEntry!);
  }

  void _updateFeedback(Offset position) {
    _feedbackPosition = position;
    _reportDragPosition(position);
    _feedbackEntry?.markNeedsBuild();
  }

  void _reportDragPosition(Offset position) {
    final pointer = _activePointer;
    final viewId = _activeViewId;
    final kind = _activeKind;
    if (pointer == null || viewId == null || kind == null) return;
    widget.onDragPosition?.call(position, pointer, viewId, kind);
  }

  void _removeFeedback() {
    final entry = _feedbackEntry;
    _feedbackEntry = null;
    // 未插入成功的 entry 不能 remove，否则会断言 _overlay != null。
    if (entry == null || !entry.mounted) return;
    entry.remove();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: ButtonAwareDraggable<T>(
        data: widget.data,
        // 平台拖拽反馈置空：位移门控与视觉反馈由本组件负责，避免点击时
        // 1px 启动的 Draggable 显示残影。
        feedback: const SizedBox.shrink(),
        // 拖拽中保持原样，避免轻微移动点击时卡片闪烁。
        childWhenDragging: widget.child,
        child: widget.child,
      ),
    );
  }
}

/// 只在「本次按住已经 armed」的抬起瞬间抢占竞技场，用来吞掉子级点击。
///
/// 不在长按到期或位移过阈值时 accept，以免原生 [Draggable] 被挤出竞技场。
class _ArmedTapSuppressor extends OneSequenceGestureRecognizer {
  void stealTap() {
    resolve(GestureDisposition.accepted);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'gated-drag tap suppressor';
}
