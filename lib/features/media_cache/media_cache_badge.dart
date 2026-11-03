import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../widgets/media_card_preparation.dart';
import '../../widgets/media_library_tooltip.dart';

import 'media_cache_models.dart';
import 'media_cache_service.dart';
import 'media_cache_card_state.dart';

/// A local-file indicator, independent of task history and transfer progress.
/// The short side drives all visual dimensions, like the podcast cover badge.
class CacheCardBadge extends StatefulWidget {
  const CacheCardBadge({
    super.key,
    required this.source,
    this.onOpen,
    this.alignment = Alignment.topRight,
    this.compactExtent,
  });

  final CacheSource? source;
  final VoidCallback? onOpen;
  final Alignment alignment;
  final double? compactExtent;

  @override
  State<CacheCardBadge> createState() => _CacheCardBadgeState();
}

class _CacheCardBadgeState extends State<CacheCardBadge>
    with WidgetsBindingObserver {
  MediaCacheService? _service;
  ValueListenable<MediaCacheCardState>? _state;
  MediaCardPreparation? _preparation;
  VoidCallback? _releasePreparation;
  String? _key;
  VoidCallback? _release;
  bool _validated = false, _current = false;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preparation = MediaCardPreparationHost.maybeOf(context);
    if (!identical(_preparation, preparation)) {
      _releasePreparation?.call();
      _releasePreparation = null;
      _preparation = preparation;
    }
    _bind();
    _updatePreparation();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && !_current) _check();
    _current = current;
  }

  @override
  void didUpdateWidget(CacheCardBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  void _bind() {
    final service = MediaCacheService.instance;
    final key = widget.source?.key;
    if (identical(service, _service) && key == _key) return;
    _release?.call();
    _state?.removeListener(_changed);
    _service = service;
    _key = key;
    _validated = false;
    _release = null;
    _checkGeneration++;
    if (service != null && key != null) {
      _state = service.cardStateFor(widget.source!);
      _state!.addListener(_changed);
      _release = service.observeMediaAvailability(key);
      _validated = _state!.value.ready;
      _updatePreparation();
      _check();
    } else {
      _state = null;
      _releasePreparation?.call();
      _releasePreparation = null;
    }
  }

  void _updatePreparation() {
    if (_state != null && !_state!.value.ready && _releasePreparation == null) {
      _releasePreparation = _preparation?.hold();
    } else if (_state?.value.ready ?? true) {
      _releasePreparation?.call();
      _releasePreparation = null;
    }
  }

  void _check() {
    final service = _service;
    final key = _key;
    if (service == null || key == null) return;
    final generation = ++_checkGeneration;
    unawaited(() async {
      try {
        final source = widget.source;
        if (source != null) await service.prepareCardStates([source]);
        if (mounted && generation == _checkGeneration && !_validated) {
          setState(() => _validated = true);
        }
      } catch (_) {
        // An unreadable or unverified file never earns a completed badge.
        if (mounted && generation == _checkGeneration && _validated) {
          setState(() => _validated = false);
        }
      }
    }());
  }

  void _changed() {
    if (mounted) {
      _validated = _state?.value.ready ?? false;
      _updatePreparation();
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkGeneration++;
    _release?.call();
    _state?.removeListener(_changed);
    _releasePreparation?.call();
    super.dispose();
  }

  Widget _badge(double extent) {
    final side = (extent * .25).clamp(14.0, 64.0);
    final hit = math.max(side, math.min(48.0, math.max(24.0, side * 1.25)));
    return MediaLibraryTooltip(
      message: '已缓存',
      child: Semantics(
        label: '已缓存',
        button: widget.onOpen != null,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: widget.onOpen,
            radius: hit / 2,
            child: SizedBox.square(
              dimension: hit,
              child: Center(
                child: Container(
                  key: const ValueKey('cache-card-badge'),
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    color: const Color(0xE6252525),
                    borderRadius: BorderRadius.circular(side * .32),
                    border: Border.all(
                      color: const Color(0x47FFFFFF),
                      width: (side * .024).clamp(.65, 1.3),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x33000000),
                        blurRadius: side * .12,
                        offset: Offset(0, side * .04),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.download_done_rounded,
                    color: const Color(0xFFE6E6E6),
                    size: side * .65,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_validated || _key == null || _state?.value.hasCache != true) {
      return const SizedBox.shrink();
    }
    if (widget.compactExtent != null) return _badge(widget.compactExtent!);
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = constraints.biggest.shortestSide;
        if (!extent.isFinite || extent <= 0) return const SizedBox.shrink();
        return Align(
          alignment: widget.alignment,
          child: Padding(
            padding: EdgeInsets.all(extent * .055),
            child: _badge(extent),
          ),
        );
      },
    );
  }
}
