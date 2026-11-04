import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';
import '../utils/app_toast.dart';

/// Presents one lightweight, dismissible notice for each media-library save
/// failure period. Repeated background retry failures stay silent.
class LibraryPersistenceNotificationBridge extends StatefulWidget {
  final Widget child;

  const LibraryPersistenceNotificationBridge({super.key, required this.child});

  @override
  State<LibraryPersistenceNotificationBridge> createState() =>
      _LibraryPersistenceNotificationBridgeState();
}

class _LibraryPersistenceNotificationBridgeState
    extends State<LibraryPersistenceNotificationBridge> {
  LibraryService? _library;
  int _lastPresentedFailureEpisode = 0;
  bool _checkScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = context.read<LibraryService>();
    if (identical(library, _library)) return;
    _library?.removeListener(_scheduleCheck);
    _library = library;
    library.addListener(_scheduleCheck);
    _scheduleCheck();
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      _presentFailureIfNeeded();
    });
  }

  void _presentFailureIfNeeded() {
    final library = _library;
    if (library == null || !library.hasPersistenceFailure) return;
    final episode = library.persistenceFailureEpisode;
    if (episode <= _lastPresentedFailureEpisode) return;
    _lastPresentedFailureEpisode = episode;

    AppToast.show(
      '媒体库的最新更改暂未写入磁盘，应用会在后台自动重试',
      type: AppToastType.error,
      duration: const Duration(seconds: 8),
      action: AppToastAction(
        label: '立即重试',
        onPressed: () {
          unawaited(library.retryLibraryPersistence());
        },
      ),
    );
  }

  @override
  void dispose() {
    _library?.removeListener(_scheduleCheck);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
