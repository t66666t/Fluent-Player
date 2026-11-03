import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/portable_transfer/portable_transfer_navigation.dart';
import '../utils/app_toast.dart';
import '../utils/incoming_share_signatures.dart';
import 'video_action_buttons.dart';

/// App-wide listener for Android/iOS share and "open with" payloads.
///
/// This is the only subscriber to the share Method/Event channels. Screens
/// such as [HomeScreen] must not open a second listener: two in-memory
/// dedupe sets would both accept the same payload.
///
/// Lives above individual screens so a buried home route cannot cancel the
/// event channel, and so archive import dialogs can use the root navigator.
class IncomingShareListener extends StatefulWidget {
  final Widget child;

  const IncomingShareListener({super.key, required this.child});

  @override
  State<IncomingShareListener> createState() => _IncomingShareListenerState();
}

class _IncomingShareListenerState extends State<IncomingShareListener>
    with WidgetsBindingObserver {
  static const MethodChannel _shareIntentChannel = MethodChannel(
    'com.example.video_player_app/share_intent',
  );
  static const EventChannel _shareIntentEventChannel = EventChannel(
    'com.example.video_player_app/share_intent_events',
  );

  StreamSubscription<dynamic>? _shareIntentSubscription;
  final Map<String, DateTime> _recentSignatures = <String, DateTime>{};
  Future<void> _handleQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_setupIncomingMediaHandling());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareIntentSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pullPendingSharedMedia());
    }
  }

  Future<void> _setupIncomingMediaHandling() async {
    if (!(Platform.isAndroid || Platform.isIOS) || !mounted) return;

    _shareIntentSubscription?.cancel();
    _shareIntentSubscription = _shareIntentEventChannel
        .receiveBroadcastStream()
        .listen((dynamic event) {
          _enqueueEvent(event);
        });

    await _pullPendingSharedMedia();
  }

  Future<void> _pullPendingSharedMedia() async {
    if (!(Platform.isAndroid || Platform.isIOS) || !mounted) return;
    try {
      final initial = await _shareIntentChannel.invokeMethod<List<dynamic>>(
        'getInitialSharedMedia',
      );
      _enqueueEvent(initial ?? const []);
    } catch (e) {
      debugPrint('接收系统分享媒体失败: $e');
    }
  }

  void _enqueueEvent(dynamic event) {
    _handleQueue = _handleQueue.then((_) => _importIncomingSharedItems(event));
  }

  Future<void> _importIncomingSharedItems(dynamic event) async {
    if (!mounted || event is! List || event.isEmpty) return;
    final signature = IncomingShareSignatures.fromItems(event);
    if (signature == null) return;
    if (!IncomingShareSignatures.accept(signature, _recentSignatures)) {
      return;
    }

    final overlayContext = await _overlayContext();
    if (overlayContext == null || !overlayContext.mounted) {
      IncomingShareSignatures.release(signature, _recentSignatures);
      return;
    }

    await VideoActionButtons.processIncomingSharedItems(
      overlayContext,
      event,
      null,
      requireCurrentRoute: false,
    );
  }

  Future<BuildContext?> _overlayContext() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final overlayContext =
          AppToast.navigatorKey.currentState?.overlay?.context;
      if (overlayContext != null && overlayContext.mounted) {
        return overlayContext;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return AppToast.navigatorKey.currentState?.overlay?.context;
  }

  @override
  Widget build(BuildContext context) {
    // Root-level drop so a FluentPack dragged onto playback/settings still
    // opens the import page. Library DropTargets also fire; navigation dedupes.
    if (!isDesktopPortableDropHost) return widget.child;
    return DropTarget(
      onDragDone: (details) {
        final paths = details.files
            .map((file) => file.path)
            .where((path) => path.trim().isNotEmpty)
            .toList(growable: false);
        if (paths.isEmpty) return;
        unawaited(_handleDesktopFluentPackDrop(paths));
      },
      child: widget.child,
    );
  }

  Future<void> _handleDesktopFluentPackDrop(List<String> paths) async {
    final overlayContext = AppToast.navigatorKey.currentState?.overlay?.context;
    final target = overlayContext ?? (mounted ? context : null);
    if (target == null || !target.mounted) return;
    await PortableTransferNavigation.handleDroppedPaths(target, paths);
  }
}
