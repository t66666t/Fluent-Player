import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';
import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'package:video_player_app/features/podcasts/podcast_connection_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  test(
    'unified proxy governs feature, task and automatic podcast requests',
    () async {
      final system = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final custom = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      system.listen((request) async {
        request.response.write('system');
        await request.response.close();
      });
      custom.listen((request) async {
        request.response.write('custom');
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
          port: custom.port,
        ),
        password: null,
        applyGlobally: true,
      );
      final resolver = FakeProxyResolver([
        ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: system.port,
        ),
      ]);
      final network = NetworkHttp(
        settings: settings,
        bridge: NetworkProxyBridge(settings: settings, resolver: resolver),
      );
      final clients = <HttpClient>[
        for (final scope in NetworkScope.values)
          network.createClient(scope: scope),
        network.createClient(modeOverride: NetworkMode.direct),
        network.createClient(modeOverride: NetworkMode.system),
        network.createPodcastClient(
          routeFor: PodcastConnectionPolicy().modeFor,
        ),
      ];
      try {
        for (final mode in [NetworkMode.custom, NetworkMode.system]) {
          await settings.setUnifiedMode(mode);
          for (final client in clients) {
            for (final host in ['overseas.test', 'domestic.example.cn']) {
              final request = await client.getUrl(Uri.http(host, '/audio'));
              request.persistentConnection = false;
              final response = await request.close();
              expect(await response.transform(utf8.decoder).join(), mode.name);
            }
          }
        }
      } finally {
        for (final client in clients) {
          client.close(force: true);
        }
        await network.dispose();
        settings.dispose();
        await system.close(force: true);
        await custom.close(force: true);
      }
    },
  );

  test(
    'cold podcast client loads unified direct policy before routing',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.write('direct');
        await request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore()
          ..saved = NetworkConfiguration(unifiedMode: NetworkMode.direct),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      final resolver = FakeProxyResolver([]);
      final network = NetworkHttp(
        settings: settings,
        bridge: NetworkProxyBridge(
          settings: settings,
          resolver: resolver,
          socketConnector: (host, port, secure) =>
              Socket.connect('127.0.0.1', origin.port),
        ),
      );
      final client = network.createPodcastClient(
        routeFor: PodcastConnectionPolicy().modeFor,
      );
      try {
        final response = await (await client.getUrl(
          Uri.http('overseas.test', '/audio'),
        )).close();
        expect(await response.transform(utf8.decoder).join(), 'direct');
        expect(settings.isLoaded, isTrue);
        expect(resolver.calls, 0);
      } finally {
        client.close(force: true);
        await network.dispose();
        settings.dispose();
        await origin.close(force: true);
      }
    },
  );
  test(
    'automatic routing distinguishes local proxy connection failure from an origin 502',
    () async {
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      final bridge = NetworkProxyBridge(
        settings: settings,
        resolver: FakeProxyResolver([
          const ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: 1,
          ),
        ]),
      );
      final network = NetworkHttp(settings: settings, bridge: bridge);
      final client = network.createPodcastClient(
        routeFor: PodcastConnectionPolicy().modeFor,
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.statusCode = 502;
        request.response.headers.set(
          'x-app-network-error',
          'selected-route-unavailable',
        );
        await request.response.close();
      });
      try {
        final localFailure = await (await client.getUrl(
          Uri.parse('http://unreachable.overseas.test/audio'),
        )).close();
        expect(network.isPodcastConnectionFailure(localFailure), isTrue);
        await localFailure.drain<void>();
        final originFailure = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${origin.port}/audio'),
        )).close();
        expect(network.isPodcastConnectionFailure(originFailure), isFalse);
        await originFailure.drain<void>();
      } finally {
        client.close(force: true);
        await network.dispose();
        settings.dispose();
        await origin.close(force: true);
      }
    },
  );
  test(
    'automatic podcast routing uses device proxy overseas and reselects direct for loopback redirects despite manual custom modes',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      origin.listen((request) async {
        seen.add('direct');
        request.response.write('audio');
        await request.response.close();
      });
      proxy.listen((request) async {
        seen.add('system:${request.uri.host}');
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${origin.port}/audio',
        );
        await request.response.close();
      });
      final store = MemoryNetworkStore()
        ..saved = NetworkConfiguration(
          proxy: const ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: 1,
          ),
          modes: {
            NetworkScope.podcasts: NetworkMode.custom,
            NetworkScope.podcastsDomestic: NetworkMode.custom,
          },
        );
      final settings = NetworkSettingsService(
        store: store,
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final network = NetworkHttp(
        settings: settings,
        bridge: NetworkProxyBridge(
          settings: settings,
          resolver: FakeProxyResolver([
            ProxyProfile(
              protocol: ProxyProtocol.http,
              host: '127.0.0.1',
              port: proxy.port,
            ),
          ]),
        ),
      );
      final routes = PodcastConnectionPolicy();
      final client = network.createPodcastClient(routeFor: routes.modeFor);
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://overseas.example.test/audio'),
        )).close();
        expect(await response.transform(utf8.decoder).join(), 'audio');
        expect(seen, ['system:overseas.example.test', 'direct']);
        expect(
          routes.modeFor(Uri.https('qncdn.xyzcdn.net')),
          NetworkMode.direct,
        );
      } finally {
        client.close(force: true);
        await network.dispose();
        settings.dispose();
        await proxy.close(force: true);
        await origin.close(force: true);
      }
    },
  );
  test(
    'domestic podcast endpoints default direct while international and legacy choices are preserved',
    () {
      final defaults = NetworkConfiguration();
      expect(defaults.modes[NetworkScope.podcastsDomestic], NetworkMode.direct);
      expect(defaults.modes[NetworkScope.podcasts], NetworkMode.system);
      for (final host in [
        'qncdn.xyzcdn.net',
        'feed.xyzfm.space',
        'www.xiaoyuzhoufm.com',
        'a.xmcdn.com',
        'podcast.example.cn',
        'bucket.oss-cn-shanghai.aliyuncs.com',
      ]) {
        expect(
          NetworkSites.forPodcast(Uri.https(host)),
          NetworkScope.podcastsDomestic,
        );
      }
      for (final host in [
        'rss.amperwave.net',
        'd2ffk1w24woq0d.cloudfront.net',
        'xyzcdn.net.evil.test',
        'xyzfm.space.evil.test',
        'xiaoyuzhoufm.com.evil.test',
        'bucket.oss-us-west-1.aliyuncs.com',
      ]) {
        expect(NetworkSites.forPodcast(Uri.https(host)), NetworkScope.podcasts);
      }
      final previous = NetworkConfiguration(
        modes: {NetworkScope.podcasts: NetworkMode.direct},
      ).toJson();
      (previous['modes'] as Map).remove('podcastsDomestic');
      final migrated = NetworkConfiguration.fromJson(previous);
      expect(migrated.modes[NetworkScope.podcasts], NetworkMode.direct);
      expect(migrated.modes[NetworkScope.podcastsDomestic], NetworkMode.direct);
    },
  );
  test(
    'podcast redirects reselect domestic versus international routes in both directions',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      origin.listen((request) async {
        seen.add('direct:${request.headers.value('host')}${request.uri.path}');
        if (request.uri.path == '/to-overseas') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://media.overseas.test/audio',
          );
        } else {
          request.response.write('direct');
        }
        await request.response.close();
      });
      proxy.listen((request) async {
        seen.add('proxy:${request.uri.host}${request.uri.path}');
        if (request.uri.path == '/to-domestic') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://qncdn.xyzcdn.net/audio',
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
      final network = NetworkHttp(
        settings: settings,
        bridge: NetworkProxyBridge(
          settings: settings,
          resolver: resolver,
          socketConnector: (host, port, secure) => Socket.connect(
            '127.0.0.1',
            host == '127.0.0.1' ? port : origin.port,
          ),
        ),
      );
      final client = network.createClient(scope: NetworkScope.podcasts);
      try {
        final first = await (await client.getUrl(
          Uri.parse('http://feed.example.cn/to-overseas'),
        )).close();
        expect(await first.transform(utf8.decoder).join(), 'proxied');
        final second = await (await client.getUrl(
          Uri.parse('http://feed.overseas.test/to-domestic'),
        )).close();
        expect(await second.transform(utf8.decoder).join(), 'direct');
        expect(seen, [
          'direct:feed.example.cn/to-overseas',
          'proxy:media.overseas.test/audio',
          'proxy:feed.overseas.test/to-domestic',
          'direct:qncdn.xyzcdn.net/audio',
        ]);
      } finally {
        client.close(force: true);
        await network.dispose();
        settings.dispose();
        await origin.close(force: true);
        await proxy.close(force: true);
      }
    },
  );
}
