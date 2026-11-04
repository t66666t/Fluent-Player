import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'bilibili_adaptive_list.dart';
import 'visibility_input_gate.dart';

enum BilibiliSkeletonKind { video, user, article, collection }

/// Keeps the loading layout underneath incoming content. Only the current
/// content is mounted: a quick new search must never attach two result lists
/// to the same scroll controller or leave an old retry button interactive.
class BilibiliLoadTransition extends StatefulWidget {
  const BilibiliLoadTransition({
    super.key,
    required this.loading,
    required this.placeholder,
    required this.child,
    this.stateKey,
    this.fill = true,
  });

  final bool loading;
  final Widget placeholder;
  final Widget child;
  final Object? stateKey;
  final bool fill;

  @override
  State<BilibiliLoadTransition> createState() => _BilibiliLoadTransitionState();
}

class _BilibiliLoadTransitionState extends State<BilibiliLoadTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.loading ? 0 : 1,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) _controller.value = widget.loading ? 0 : 1;
  }

  @override
  void didUpdateWidget(BilibiliLoadTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading) {
      _controller.value = 0;
    } else if (oldWidget.loading || oldWidget.stateKey != widget.stateKey) {
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: widget.fill ? StackFit.expand : StackFit.loose,
    alignment: Alignment.centerLeft,
    children: [
      AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (!widget.loading && _controller.isCompleted) {
            return const SizedBox.shrink();
          }
          return IgnorePointer(
            child: ExcludeSemantics(
              excluding: !widget.loading,
              child: FadeTransition(
                opacity: ReverseAnimation(_fade),
                child: widget.placeholder,
              ),
            ),
          );
        },
      ),
      FadeTransition(
        opacity: _fade,
        child: FadeInputGate(
          opacity: _fade,
          enabled: !widget.loading,
          child: widget.loading
              ? const SizedBox.shrink()
              : KeyedSubtree(
                  key: ValueKey(widget.stateKey),
                  child: widget.child,
                ),
        ),
      ),
    ],
  );
}

/// One subtle pulse for the whole loading region, instead of a ticker for
/// every bone or cover. Hidden tabs and reduced-motion layouts stay static.
class BilibiliSkeletonPulse extends StatefulWidget {
  const BilibiliSkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  State<BilibiliSkeletonPulse> createState() => _BilibiliSkeletonPulseState();
}

class _BilibiliSkeletonPulseState extends State<BilibiliSkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: .48,
    end: .86,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
      _controller.value = .5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: FadeTransition(
      opacity: _opacity,
      child: RepaintBoundary(child: widget.child),
    ),
  );
}

class BilibiliSkeletonBlock extends StatelessWidget {
  const BilibiliSkeletonBlock({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 4,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AppTokens.text4,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// Uses the same responsive columns and thumbnail widths as the real lists.
class BilibiliListSkeleton extends StatelessWidget {
  const BilibiliListSkeleton({
    super.key,
    this.kind = BilibiliSkeletonKind.video,
    this.label = '正在加载…',
    this.padding = EdgeInsets.zero,
    this.showLabel = false,
  });

  final BilibiliSkeletonKind kind;
  final String label;
  final EdgeInsets padding;
  final bool showLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLabel)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: ExcludeSemantics(
              child: Text(
                label,
                style: const TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
            ),
          ),
        Expanded(
          child: BilibiliSkeletonPulse(
            child: LayoutBuilder(
              builder: (context, constraints) => BilibiliAdaptiveList(
                // The loading layout must not inherit a NestedScrollView's
                // controller while it overlaps the incoming real list.
                padding: padding,
                itemCount: bilibiliListColumns(constraints.maxWidth) * 10,
                itemBuilder: (context, index) =>
                    _SkeletonTile(kind: kind, short: index.isOdd),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class BilibiliProfileSkeleton extends StatelessWidget {
  const BilibiliProfileSkeleton({super.key, this.name = ''});

  final String name;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在加载 UP 主资料',
    child: Row(
      children: [
        const BilibiliSkeletonPulse(
          child: BilibiliSkeletonBlock(width: 64, height: 64, radius: 32),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTokens.text1, fontSize: 17),
                ),
              BilibiliSkeletonPulse(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (name.isEmpty) ...[
                      const BilibiliSkeletonBlock(width: 112, height: 18),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 6),
                    const FractionallySizedBox(
                      widthFactor: .54,
                      child: BilibiliSkeletonBlock(height: 10),
                    ),
                    const SizedBox(height: 9),
                    const FractionallySizedBox(
                      widthFactor: .82,
                      child: BilibiliSkeletonBlock(height: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({required this.kind, required this.short});

  final BilibiliSkeletonKind kind;
  final bool short;

  Widget _line(double fraction, double height) => FractionallySizedBox(
    widthFactor: fraction,
    alignment: Alignment.centerLeft,
    child: BilibiliSkeletonBlock(height: height),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final user = kind == BilibiliSkeletonKind.user;
        final article = kind == BilibiliSkeletonKind.article;
        final width = switch (kind) {
          BilibiliSkeletonKind.user => 48.0,
          BilibiliSkeletonKind.article => 96.0,
          BilibiliSkeletonKind.collection => 128.0,
          BilibiliSkeletonKind.video => (constraints.maxWidth * .38).clamp(
            104.0,
            144.0,
          ),
        };
        final height = user ? 48.0 : width * .625;
        final cover = BilibiliSkeletonBlock(
          width: width,
          height: height,
          radius: user ? 24 : 6,
        );
        final text = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line(short ? .65 : .93, 14 * scale),
              const SizedBox(height: 8),
              if (!user) ...[
                _line(short ? .46 : .7, 12 * scale),
                const SizedBox(height: 10),
              ],
              _line(.48, 9 * scale),
              const SizedBox(height: 7),
              _line(.7, 9 * scale),
            ],
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!article) ...[cover, const SizedBox(width: 10)],
            text,
            if (article) ...[const SizedBox(width: 10), cover],
          ],
        );
      },
    ),
  );
}
