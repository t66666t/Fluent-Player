import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/media_artwork_ref.dart';
import '../services/media_artwork_repository.dart';
import 'media_card_preparation.dart';

/// Remembers covers that have already faded in.
///
/// Scrolling away and back, selection changes and a background refresh must not
/// replay the entrance animation for the same bytes.
class ArtworkRevealMemory {
  static final shown = <String>{};
  static const maxShown = 400;

  static void remember(String identity) {
    shown.remove(identity);
    shown.add(identity);
    while (shown.length > maxShown) {
      shown.remove(shown.first);
    }
  }
}

/// Draws a cover from the shared artwork repository.
///
/// The widget does not open a network request itself. Pixel size only chooses
/// a decode bucket; the repository still fetches the original once.
class MediaArtworkView extends StatefulWidget {
  const MediaArtworkView({
    super.key,
    required this.reference,
    required this.size,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.priority = ArtworkPriority.visible,
  });

  final ArtworkRef reference;
  final double size;
  final BoxFit fit;
  final Widget? placeholder;
  final ArtworkPriority priority;

  @override
  State<MediaArtworkView> createState() => _MediaArtworkViewState();
}

class _MediaArtworkViewState extends State<MediaArtworkView> {
  ArtworkSnapshot? _snapshot;
  List<int>? _memorySource;
  Uint8List? _memoryBytes;
  StreamSubscription<ArtworkSnapshot>? _subscription;
  String? _boundKey;
  int _bindSerial = 0;
  MediaCardPreparation? _preparation;
  VoidCallback? _releasePreparation;
  Timer? _deadline;

  @visibleForTesting
  int get debugRetainedEncodedByteCount => _memoryBytes?.lengthInBytes ?? 0;

  void _finishPreparation() {
    _deadline?.cancel();
    _deadline = null;
    _releasePreparation?.call();
    _releasePreparation = null;
  }

  void _prepare() {
    if (_preparation == null || _releasePreparation != null) return;
    _releasePreparation = _preparation!.hold();
    _deadline = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      // Release the card entrance deadline, but keep listening and decoding:
      // a slow shared cover must still appear without recycling the row.
      _finishPreparation();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preparation = MediaCardPreparationHost.maybeOf(context);
    if (!identical(preparation, _preparation)) {
      _finishPreparation();
      _preparation = preparation;
      if (MediaArtworkRepository.active != null) _prepare();
    }
    _listen();
  }

  @override
  void didUpdateWidget(covariant MediaArtworkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen();
  }

  @override
  void dispose() {
    _finishPreparation();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _listen() {
    final repository = MediaArtworkRepository.active;
    final key =
        '${identityHashCode(repository)}|${widget.priority.name}|${widget.reference.chain.map((request) => request.requestKey).join('|')}';
    if (_boundKey == key && _subscription != null) return;
    _boundKey = key;
    _finishPreparation();
    if (repository != null && widget.reference.chain.isNotEmpty) _prepare();
    final serial = ++_bindSerial;
    // A recycled row must not keep the previous episode's picture while the
    // new request is still loading.
    _snapshot = repository?.cachedSnapshot(widget.reference);
    _memorySource = null;
    _memoryBytes = null;
    unawaited(_subscription?.cancel());
    if (repository == null) return;
    _subscription = repository
        .watch(widget.reference, priority: widget.priority)
        .listen((snapshot) {
          if (!mounted || serial != _bindSerial) return;
          final previous = _snapshot;
          if (previous != null &&
              previous.hasImage &&
              snapshot.hasImage &&
              previous.blobHash != null &&
              previous.blobHash == snapshot.blobHash) {
            return;
          }
          // A late channel image must not cover an episode image that already arrived.
          if (previous != null &&
              previous.hasImage &&
              previous.requestKey ==
                  widget.reference.chain.firstOrNull?.requestKey &&
              snapshot.requestKey != previous.requestKey) {
            return;
          }
          if (snapshot.phase == ArtworkPhase.failed) _finishPreparation();
          setState(() => _snapshot = snapshot);
        }, onError: (_, _) {});
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final child =
        _image(snapshot) ?? widget.placeholder ?? const SizedBox.shrink();
    final identity = snapshot?.blobHash ?? snapshot?.requestKey ?? '';
    final seen =
        identity.isNotEmpty && ArtworkRevealMemory.shown.contains(identity);
    if (snapshot != null && snapshot.hasImage && identity.isNotEmpty) {
      ArtworkRevealMemory.remember(identity);
    }
    if (_preparation != null ||
        snapshot?.fromDisk == true ||
        seen ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return AnimatedOpacity(
      opacity: snapshot != null && snapshot.hasImage ? 1 : 0.35,
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }

  Widget? _image(ArtworkSnapshot? snapshot) {
    if (snapshot == null || !snapshot.hasImage || snapshot.localPath != null) {
      // The same binding can promote a memory fallback to a file-backed
      // primary. Its former MemoryImage conversion is no longer in use.
      _memorySource = null;
      _memoryBytes = null;
    }
    if (snapshot == null || !snapshot.hasImage) return null;
    final bucket = artworkSizeBucket(
      widget.size,
      MediaQuery.devicePixelRatioOf(context),
    );
    if (snapshot.localPath != null) {
      return Image.file(
        File(snapshot.localPath!),
        fit: widget.fit,
        cacheWidth: bucket,
        gaplessPlayback: true,
        frameBuilder: _frame,
        filterQuality: FilterQuality.medium,
        errorBuilder: _error,
      );
    }
    final bytes = snapshot.memoryBytes;
    if (bytes == null || bytes.isEmpty) return null;
    if (!identical(bytes, _memorySource)) {
      _memorySource = bytes;
      _memoryBytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    }
    return Image.memory(
      _memoryBytes!,
      fit: widget.fit,
      cacheWidth: bucket,
      gaplessPlayback: true,
      frameBuilder: _frame,
      errorBuilder: _error,
    );
  }

  Widget _frame(
    BuildContext context,
    Widget child,
    int? frame,
    bool synchronous,
  ) {
    if (frame != null || synchronous) _finishPreparation();
    return child;
  }

  Widget _error(BuildContext context, Object error, StackTrace? stack) {
    _finishPreparation();
    return widget.placeholder ?? const SizedBox.shrink();
  }
}
