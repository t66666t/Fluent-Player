import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';
import 'package:video_player_app/services/network/network_recovery.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    NetworkRecovery.handleLifecycle(AppLifecycleState.resumed);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '${platform.name} focus/background transitions preserve an active transfer',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        final received = Completer<void>();
        origin.listen((request) async {
          try {
            request.response.bufferOutput = false;
            request.response.contentLength = 8192;
            request.response.add(List.filled(4096, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List.filled(4096, 2));
            await request.response.close();
          } catch (_) {}
        });
        final settings = NetworkSettingsService(
          store: MemoryNetworkStore(),
          credentials: MemoryCredentials(),
          migrateLegacy: false,
        );
        final network = NetworkHttp(
          settings: settings,
          bridge: NetworkProxyBridge(
            settings: settings,
            resolver: FakeProxyResolver([null]),
            socketConnector: (_, _, _) =>
                Socket.connect('127.0.0.1', origin.port),
          ),
        );
        final client = network.createClient();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          client.close(force: true);
          await network.dispose();
          await origin.close(force: true);
        });
        final response = await (await client.getUrl(
          Uri.parse('http://media.test/file'),
        )).close();
        final bytes = <int>[];
        final complete = response.forEach((chunk) {
          bytes.addAll(chunk);
          if (!received.isCompleted) received.complete();
        });
        await received.future;
        final generation = settings.deviceGeneration;
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          if (platform == TargetPlatform.android ||
              platform == TargetPlatform.iOS)
            AppLifecycleState.paused,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          network.didChangeAppLifecycleState(state);
        }
        expect(settings.deviceGeneration, generation);
        release.complete();
        await complete.timeout(const Duration(seconds: 3));
        expect(bytes, [...List.filled(4096, 1), ...List.filled(4096, 2)]);
      },
    );
  }

  for (final deviceChange in [false, true]) {
    test(
      '${deviceChange ? 'device network' : 'proxy setting'} change drains the old body and routes the next connection correctly',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        final received = Completer<void>();
        origin.listen((request) async {
          try {
            request.response.bufferOutput = false;
            request.response.contentLength = 8192;
            request.response.add(List.filled(4096, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List.filled(4096, 2));
            await request.response.close();
          } catch (_) {}
        });
        var proxyCalls = 0;
        proxy.listen((request) async {
          proxyCalls++;
          request.response.write('new route');
          await request.response.close();
        });
        final settings = NetworkSettingsService(
          store: MemoryNetworkStore(),
          credentials: MemoryCredentials(),
          migrateLegacy: false,
        );
        final resolver = FakeProxyResolver([null]);
        final bridge = NetworkProxyBridge(
          settings: settings,
          resolver: resolver,
          socketConnector: (host, port, secure) => Socket.connect(
            '127.0.0.1',
            host == '127.0.0.1' ? port : origin.port,
          ),
        );
        final network = NetworkHttp(settings: settings, bridge: bridge);
        final client = network.createClient();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          client.close(force: true);
          await network.dispose();
          await origin.close(force: true);
          await proxy.close(force: true);
        });
        final response = await (await client.getUrl(
          Uri.parse('http://media.test/old'),
        )).close();
        final bytes = <int>[];
        final complete = response.forEach((chunk) {
          bytes.addAll(chunk);
          if (!received.isCompleted) received.complete();
        });
        await received.future;
        final profile = ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: proxy.port,
        );
        if (deviceChange) {
          resolver.routes = [profile];
          settings.deviceNetworkChanged();
        } else {
          await settings.saveProxy(
            profile: profile,
            password: null,
            applyTo: NetworkScope.other,
          );
        }
        release.complete();
        await complete.timeout(const Duration(seconds: 3));
        expect(bytes.length, 8192);
        final next = await (await client.getUrl(
          Uri.parse('http://media.test/next'),
        )).close();
        expect(await next.transform(utf8.decoder).join(), 'new route');
        expect(proxyCalls, 1);
      },
    );
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '${platform.name} retries respect suspension without treating lost focus as suspension',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        NetworkRecovery.handleLifecycle(AppLifecycleState.hidden);
        var done = false;
        final wait = NetworkRecovery.wait(
          const Duration(milliseconds: 10),
          checkCancelled: () {},
        ).then((_) => done = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final mobile =
            platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        expect(done, !mobile);
        NetworkRecovery.handleLifecycle(AppLifecycleState.resumed);
        await wait.timeout(const Duration(seconds: 1));
        NetworkRecovery.handleLifecycle(AppLifecycleState.inactive);
        await NetworkRecovery.wait(
          const Duration(milliseconds: 1),
          checkCancelled: () {},
        ).timeout(const Duration(seconds: 1));
      },
    );
  }

  test(
    'a user pause cancels recovery while a mobile app is backgrounded',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      NetworkRecovery.handleLifecycle(AppLifecycleState.paused);
      var cancelled = false;
      final wait = NetworkRecovery.wait(
        const Duration(seconds: 30),
        checkCancelled: () {
          if (cancelled) throw StateError('user paused');
        },
      );
      final checked = expectLater(wait, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancelled = true;
      await checked.timeout(const Duration(seconds: 1));
    },
  );
}
