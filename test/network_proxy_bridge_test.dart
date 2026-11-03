import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';

import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

class FakeProxyResolver implements SystemProxyResolver {
  int calls = 0;
  List<ProxyProfile?> routes;
  FakeProxyResolver(this.routes);
  @override
  Future<List<ProxyProfile?>> resolve(Uri uri) async {
    calls++;
    return routes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  test(
    'direct and system routes reach separate interfaces, redirects and CDN stay in the task scope',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      origin.listen((request) async {
        seen.add('direct:${request.uri.path}');
        expect(request.headers.value('proxy-authorization'), isNull);
        request.response.write('direct');
        await request.response.close();
      });
      proxy.listen((request) async {
        seen.add('proxy:${request.uri.host}');
        if (request.uri.host == 'share.test') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://foreign-cdn.test/media',
          );
        } else {
          request.response.write('proxied');
        }
        await request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      final resolver = FakeProxyResolver([
        ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: proxy.port,
        ),
      ]);
      final bridge = NetworkProxyBridge(
        settings: settings,
        resolver: resolver,
        socketConnector: (host, port, secure) => Socket.connect(
          '127.0.0.1',
          host == '127.0.0.1' ? port : origin.port,
        ),
      );
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final bili = network.createClient(scope: NetworkScope.bilibili);
      final foreign = network.createClient(
        scope: NetworkScope.ytDlpOther,
        source: Uri.parse('http://share.test/'),
      );
      addTearDown(() async {
        bili.close(force: true);
        foreign.close(force: true);
        await network.dispose();
        await origin.close(force: true);
        await proxy.close(force: true);
      });
      final directResponse = await (await bili.getUrl(
        Uri.parse('http://foreign-cdn.test/media'),
      )).close();
      expect(await directResponse.transform(utf8.decoder).join(), 'direct');
      expect(resolver.calls, 0);
      final foreignResponse = await (await foreign.getUrl(
        Uri.parse('http://share.test/'),
      )).close();
      expect(await foreignResponse.transform(utf8.decoder).join(), 'proxied');
      expect(seen, [
        'direct:/media',
        'proxy:share.test',
        'proxy:foreign-cdn.test',
      ]);
    },
  );

  test(
    'custom proxy authentication is sent only upstream; failure never becomes direct',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? authorization;
      proxy.listen((request) async {
        authorization = request.headers.value('proxy-authorization');
        request.response.write('ok');
        await request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      await settings.saveProxy(
        profile: ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: proxy.port,
          username: '用户',
        ),
        password: 'secret',
        applyTo: NetworkScope.ytDlpOther,
      );
      final resolver = FakeProxyResolver([null]);
      final bridge = NetworkProxyBridge(settings: settings, resolver: resolver);
      final timings = <NetworkConnectionTiming>[];
      final timingSubscription = bridge.connectionTimings.listen(timings.add);
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final client = network.createClient(scope: NetworkScope.ytDlpOther);
      addTearDown(() async {
        await timingSubscription.cancel();
        client.close(force: true);
        await network.dispose();
        await proxy.close(force: true);
      });
      final response = await (await client.getUrl(
        Uri.parse('http://example.invalid/media'),
      )).close();
      expect(await response.transform(utf8.decoder).join(), 'ok');
      expect(authorization, 'Basic ${base64Encode(utf8.encode('用户:secret'))}');
      expect(timings, isNotEmpty);
      expect(
        timings.every((event) => event.scope == NetworkScope.ytDlpOther),
        isTrue,
      );
      expect(
        timings.map((event) => event.phase),
        contains('http connection ready'),
      );
      expect(timings.every((event) => event.elapsedMilliseconds >= 0), isTrue);
      expect(
        timings.map((event) => '${event.host}:${event.phase}').join(),
        isNot(anyOf(contains('secret'), contains('media'), contains('用户'))),
      );
      expect(resolver.calls, 0);
      await proxy.close(force: true);
      final failed = await (await client.getUrl(
        Uri.parse('http://other.invalid/file'),
      )).close();
      expect(failed.statusCode, 502);
      await failed.drain<void>();
      expect(
        settings.configuration.modes[NetworkScope.ytDlpOther],
        NetworkMode.custom,
      );
      expect(resolver.calls, 0);
    },
  );

  test(
    'loopback is direct even with a custom proxy; children inherit no ambient proxy',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.write('gateway');
        await request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      await settings.saveProxy(
        profile: const ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: 1,
        ),
        password: null,
        applyTo: NetworkScope.bilibili,
      );
      final network = NetworkHttp(settings: settings);
      final client = network.createClient(scope: NetworkScope.bilibili);
      addTearDown(() async {
        client.close(force: true);
        await network.dispose();
        await origin.close(force: true);
      });
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${origin.port}/video'),
      )).close();
      expect(await response.transform(utf8.decoder).join(), 'gateway');
      final environment = NetworkHttp.childEnvironment(
        environment: {
          'HTTP_PROXY': 'secret',
          'https_proxy': 'secret',
          'ALL_PROXY': 'secret',
          'PATH': 'retained',
        },
      );
      expect(environment.values, isNot(contains('secret')));
      expect(environment['PATH'], 'retained');
    },
  );
}
