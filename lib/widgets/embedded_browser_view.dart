import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/browser/embedded_browser_diagnostics.dart';
import 'embedded_browser_gestures.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// All embedded pages use the same Android composition and recovery policy.
/// Feature settings still own navigation, cookies, content mode and interception.
InAppWebViewSettings embeddedBrowserSettings(InAppWebViewSettings settings) {
  return settings.copy()
    // Texture composition rebuilds Android's ActionMode and finishes the
    // original one, which loses the native selection handles/magnifier.
    ..useHybridComposition = true
    ..disableContextMenu = false
    ..isTextInteractionEnabled = true
    ..useOnRenderProcessGone = true
    ..supportZoom = true
    ..builtInZoomControls = true
    ..displayZoomControls = false
    ..ignoresViewportScaleLimits = true;
}

/// Keep the site's layout width while allowing native pinch zoom on login pages
/// that declare user-scalable=no. Watch only viewport metadata, never page DOM.
const embeddedBrowserZoomScript = r'''
(() => {
  if (window.__fluentBrowserZoom) return;
  window.__fluentBrowserZoom = true;
  const apply = () => {
    if (!document.head) return;
    let meta = document.head.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'viewport';
      meta.content = 'width=device-width, initial-scale=1';
      document.head.appendChild(meta);
    }
    const parts = meta.content.split(',').map(s => s.trim()).filter(s =>
      s && !/^(user-scalable|minimum-scale|maximum-scale)\s*=/i.test(s));
    parts.push('user-scalable=yes', 'minimum-scale=0.25', 'maximum-scale=5');
    const content = parts.join(', ');
    if (meta.content !== content) meta.content = content;
  };
  const install = () => {
    if (!document.head) return;
    apply();
    new MutationObserver(apply).observe(document.head, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['content', 'name']
    });
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, {once: true});
    apply();
  } else install();
})();
''';

/// Shared native host. It never waits for website JavaScript before suspending
/// or detaching, and never reloads a renderer that the OS has already destroyed.
class EmbeddedBrowserView extends StatefulWidget {
  const EmbeddedBrowserView({
    super.key,
    required this.browserId,
    required this.initialUrlRequest,
    required this.initialSettings,
    this.keepAlive,
    this.webViewEnvironment,
    this.initialUserScripts,
    this.active = true,
    this.allowPageZoom = false,
    this.focusNode,
    this.onWebViewCreated,
    this.onControllerUnavailable,
    this.onDiscardNativeView,
    this.onRenderProcessGone,
    this.onWebContentProcessDidTerminate,
    this.onLoadStart,
    this.onLoadStop,
    this.onUpdateVisitedHistory,
    this.onProgressChanged,
    this.onTitleChanged,
    this.onScrollChanged,
    this.onReceivedError,
    this.onReceivedHttpError,
    this.onLoadResource,
    this.onDownloadStartRequest,
    this.shouldOverrideUrlLoading,
    this.shouldInterceptRequest,
  });

  final String browserId;
  final URLRequest initialUrlRequest;
  final InAppWebViewSettings initialSettings;
  final InAppWebViewKeepAlive? Function()? keepAlive;
  final WebViewEnvironment? webViewEnvironment;
  final UnmodifiableListView<UserScript>? initialUserScripts;
  final bool active;
  final bool allowPageZoom;

  /// Tracks native keyboard focus without taking it from the platform view.
  final FocusNode? focusNode;
  final void Function(InAppWebViewController)? onWebViewCreated;
  final VoidCallback? onControllerUnavailable;
  final Future<void> Function()? onDiscardNativeView;
  // Features with retained documents may provide their own recovery UI.
  final void Function(InAppWebViewController, RenderProcessGoneDetail)?
  onRenderProcessGone;
  final void Function(InAppWebViewController)? onWebContentProcessDidTerminate;
  final void Function(InAppWebViewController, WebUri?)? onLoadStart;
  final void Function(InAppWebViewController, WebUri?)? onLoadStop;
  final void Function(InAppWebViewController, WebUri?, bool?)?
  onUpdateVisitedHistory;
  final void Function(InAppWebViewController, int)? onProgressChanged;
  final void Function(InAppWebViewController, String?)? onTitleChanged;
  final void Function(InAppWebViewController, int, int)? onScrollChanged;
  final void Function(
    InAppWebViewController,
    WebResourceRequest,
    WebResourceError,
  )?
  onReceivedError;
  final void Function(
    InAppWebViewController,
    WebResourceRequest,
    WebResourceResponse,
  )?
  onReceivedHttpError;
  final void Function(InAppWebViewController, LoadedResource)? onLoadResource;
  final void Function(InAppWebViewController, DownloadStartRequest)?
  onDownloadStartRequest;
  final Future<NavigationActionPolicy?> Function(
    InAppWebViewController,
    NavigationAction,
  )?
  shouldOverrideUrlLoading;
  final Future<WebResourceResponse?> Function(
    InAppWebViewController,
    WebResourceRequest,
  )?
  shouldInterceptRequest;

  @override
  State<EmbeddedBrowserView> createState() => _EmbeddedBrowserViewState();
}

class _EmbeddedBrowserViewState extends State<EmbeddedBrowserView>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  PlatformInAppWebViewController? _lastNativeController;
  Animation<double>? _routeAnimation;
  bool _appVisible = true;
  bool _routeVisible = true;
  bool? _nativeActive;
  bool _leaving = false;
  bool _failed = false;
  bool _recovering = false;
  int _generation = 0;
  WebUri? _lastUrl;
  Future<void>? _cleanup;
  late final _lease = '${widget.browserId}:${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appVisible =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    unawaited(EmbeddedBrowserDiagnostics.start(_lease));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A popup takes route/input focus without covering the document. On
    // Windows pause() sets WebView2 IsVisible=false, clearing its texture.
    // Overlay disables TickerMode for routes covered by an opaque route.
    _routeVisible = TickerMode.valuesOf(context).enabled;
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeChanged);
    }
    _syncActivity();
  }

  void _routeChanged(AnimationStatus status) {
    if (status != AnimationStatus.reverse) {
      if (_leaving) {
        _leaving = false;
        _syncActivity();
      }
      return;
    }
    _leaving = true;
    unawaited(EmbeddedBrowserDiagnostics.closing(_lease));
    _syncActivity();
  }

  @override
  void didUpdateWidget(covariant EmbeddedBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive still has visible views (including focus in a native WebView).
    // Suspend only when the app is actually hidden, paused or detached.
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncActivity();
  }

  void _syncActivity() {
    final controller = _controller;
    if (controller == null) return;
    final active = widget.active && _appVisible && _routeVisible && !_leaving;
    // pauseTimers affects ALL WebViews in the process; use per-view onPause.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows) {
      if (_nativeActive == active) return;
      _nativeActive = active;
      unawaited(_setNativeActivity(controller, active));
    }
  }

  Future<void> _setNativeActivity(
    InAppWebViewController controller,
    bool active,
  ) async {
    try {
      if (active) {
        await controller.resume();
      } else {
        await controller.pause();
      }
    } catch (_) {
      if (identical(controller.platform, _controller?.platform) &&
          _nativeActive == active) {
        _nativeActive = null;
      }
      // A disposed view or an unsupported platform must not hold navigation.
    }
  }

  bool _accept(InAppWebViewController controller, int generation) =>
      mounted &&
      !_failed &&
      !_leaving &&
      generation == _generation &&
      identical(controller.platform, _controller?.platform);

  void _rendererExited(InAppWebViewController controller, String event) {
    if (!mounted ||
        _failed ||
        !identical(controller.platform, _controller?.platform)) {
      return;
    }
    unawaited(EmbeddedBrowserDiagnostics.record(_lease, event));
    _controller = null;
    _nativeActive = null;
    widget.onControllerUnavailable?.call();
    setState(() => _failed = true);
    _cleanup = () async {
      // Destroy the old widget before disposing its retained native token.
      await WidgetsBinding.instance.endOfFrame;
      await widget.onDiscardNativeView?.call();
    }();
    // Keep cleanup errors local; retry can still create a fresh ordinary view.
    unawaited(_cleanup!.catchError((Object _) {}));
  }

  Future<void> _retry() async {
    if (_recovering) return;
    setState(() => _recovering = true);
    try {
      await _cleanup;
      if (!mounted || _leaving) return;
      setState(() {
        _generation++;
        _failed = false;
      });
    } catch (_) {
      // Do not reattach an old retained view when disposal failed.
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeChanged);
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_setNativeActivity(controller, false));
    }
    unawaited(EmbeddedBrowserDiagnostics.stop(_lease));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('网页进程已停止，已保留当前功能的数据。', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              DesktopButtonClickRegion(
                child: FilledButton.icon(
                  onPressed: _recovering ? null : _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新打开网页'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final generation = _generation;
    return EmbeddedBrowserRouteExit(
      child: EmbeddedBrowserGestureBoundary(
        child: Focus(
          focusNode: widget.focusNode,
          canRequestFocus: false,
          child: InAppWebView(
            key: ValueKey(generation),
            keepAlive: widget.keepAlive?.call(),
            gestureRecognizers: embeddedBrowserGestureRecognizers,
            preventGestureDelay: true,
            webViewEnvironment: widget.webViewEnvironment,
            initialUrlRequest: _lastUrl == null
                ? widget.initialUrlRequest
                : URLRequest(url: _lastUrl),
            initialSettings: embeddedBrowserSettings(widget.initialSettings),
            initialUserScripts: UnmodifiableListView([
              ...?widget.initialUserScripts,
              if (widget.allowPageZoom)
                UserScript(
                  groupName: 'fluent-browser-zoom',
                  source: embeddedBrowserZoomScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
            ]),
            onWebViewCreated: (controller) {
              if (!mounted || _leaving || generation != _generation) return;
              _controller = controller;
              _nativeActive = null;
              _lastNativeController = controller.platform;
              _syncActivity();
              widget.onWebViewCreated?.call(controller);
            },
            onRenderProcessGone: (controller, detail) {
              if (widget.onRenderProcessGone != null) {
                // A retained document can exit after its Flutter surface was
                // detached. Its session owner must still invalidate that token.
                if (!identical(controller.platform, _lastNativeController)) {
                  return;
                }
                unawaited(
                  EmbeddedBrowserDiagnostics.record(
                    _lease,
                    'renderer_exit didCrash=${detail.didCrash} priority=${detail.rendererPriorityAtExit}',
                  ),
                );
                widget.onRenderProcessGone!(controller, detail);
              } else {
                if (!_accept(controller, generation)) return;
                _rendererExited(
                  controller,
                  'renderer_exit didCrash=${detail.didCrash} priority=${detail.rendererPriorityAtExit}',
                );
              }
            },
            onWebContentProcessDidTerminate: (controller) {
              if (widget.onWebContentProcessDidTerminate != null) {
                if (!identical(controller.platform, _lastNativeController)) {
                  return;
                }
                widget.onWebContentProcessDidTerminate!(controller);
              } else {
                if (!_accept(controller, generation)) return;
                _rendererExited(controller, 'web_content_process_terminated');
              }
            },
            onLoadStart: (c, url) {
              if (!_accept(c, generation)) return;
              _lastUrl = url ?? _lastUrl;
              widget.onLoadStart?.call(c, url);
            },
            onLoadStop: (c, url) {
              if (!_accept(c, generation)) return;
              _lastUrl = url ?? _lastUrl;
              widget.onLoadStop?.call(c, url);
            },
            onUpdateVisitedHistory: (c, url, reload) {
              if (!_accept(c, generation)) return;
              _lastUrl = url ?? _lastUrl;
              widget.onUpdateVisitedHistory?.call(c, url, reload);
            },
            onProgressChanged: (c, value) {
              if (_accept(c, generation)) {
                widget.onProgressChanged?.call(c, value);
              }
            },
            onTitleChanged: (c, title) {
              if (_accept(c, generation)) widget.onTitleChanged?.call(c, title);
            },
            onScrollChanged: (c, x, y) {
              if (_accept(c, generation)) widget.onScrollChanged?.call(c, x, y);
            },
            onReceivedError: (c, request, error) {
              if (_accept(c, generation)) {
                widget.onReceivedError?.call(c, request, error);
              }
            },
            onReceivedHttpError: (c, request, response) {
              if (_accept(c, generation)) {
                widget.onReceivedHttpError?.call(c, request, response);
              }
            },
            onLoadResource: widget.onLoadResource == null
                ? null
                : (c, resource) {
                    if (_accept(c, generation)) {
                      widget.onLoadResource?.call(c, resource);
                    }
                  },
            onDownloadStartRequest: widget.onDownloadStartRequest == null
                ? null
                : (c, request) {
                    if (_accept(c, generation)) {
                      widget.onDownloadStartRequest?.call(c, request);
                    }
                  },
            shouldOverrideUrlLoading: (c, navigation) async {
              if (!_accept(c, generation)) return NavigationActionPolicy.CANCEL;
              return widget.shouldOverrideUrlLoading == null
                  ? NavigationActionPolicy.ALLOW
                  : widget.shouldOverrideUrlLoading!(c, navigation);
            },
            shouldInterceptRequest: widget.shouldInterceptRequest == null
                ? null
                : (c, request) async => _accept(c, generation)
                      ? widget.shouldInterceptRequest?.call(c, request)
                      : null,
          ),
        ),
      ),
    );
  }
}
