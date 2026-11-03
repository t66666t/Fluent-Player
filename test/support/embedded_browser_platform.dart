import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// A native lifecycle fixture. Each callback deliberately receives a distinct
/// Dart facade around one native controller, matching Android's plugin bridge.
class BrowserTestPlatform extends InAppWebViewPlatform {
  final controllers = <BrowserTestController>[];
  final disposedTokens = <InAppWebViewKeepAlive>[];
  late PlatformInAppWebViewWidgetCreationParams params;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    this.params = params;
    return _Widget(params, this);
  }

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _StaticController(
        const PlatformInAppWebViewControllerCreationParams(id: null),
        this,
      );
  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) => _StaticController(params, this);
}

class _StaticController extends PlatformInAppWebViewController {
  _StaticController(super.params, this.owner) : super.implementation();
  final BrowserTestPlatform owner;
  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive token) async =>
      owner.disposedTokens.add(token);
}

class _Widget extends PlatformInAppWebViewWidget {
  _Widget(super.params, this.owner) : super.implementation();
  final BrowserTestPlatform owner;
  @override
  Widget build(BuildContext context) => _Host(platform: this);
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;
  @override
  void dispose() {}
}

class _Host extends StatefulWidget {
  const _Host({required this.platform});
  final _Widget platform;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    final controller = BrowserTestController(widget.platform.params);
    widget.platform.owner.controllers.add(controller);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.callbacks.onWebViewCreated?.call(controller.api);
    });
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.white);
}

class BrowserTestController extends PlatformInAppWebViewController {
  BrowserTestController(this.callbacks)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(
          id: 'native-fixture',
        ),
      );
  final PlatformInAppWebViewWidgetCreationParams callbacks;
  int pauses = 0;
  int resumes = 0;
  int javascriptCalls = 0;
  InAppWebViewController get api =>
      InAppWebViewController.fromPlatform(platform: this);
  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    javascriptCalls++;
    throw StateError('The website event loop is unresponsive');
  }
}
