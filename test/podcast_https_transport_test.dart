import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_connection_policy.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'support/temporary_tls_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TemporaryTlsFixture tlsFixture;
  setUpAll(() async => tlsFixture = await TemporaryTlsFixture.create());
  tearDownAll(() async => tlsFixture.dispose());
  late HttpServer secureOrigin;
  late HttpServer plainOrigin;
  late NetworkSettingsService settings;
  late NetworkHttp network;
  late FakeProxyResolver resolver;
  final clients = <HttpClient>[];
  final requests = <String>[];

  setUp(() async {
    HttpOverrides.global = null;
    requests.clear();
    secureOrigin = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(tlsFixture.certificate)
        ..usePrivateKey(tlsFixture.privateKey),
    );
    plainOrigin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    secureOrigin.listen((request) async {
      requests.add('https:${request.uri.path}');
      if (request.uri.path == '/to-http') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${plainOrigin.port}/audio',
        );
      } else {
        request.response.write('encrypted audio');
      }
      await request.response.close();
    }, onError: (_) {});
    plainOrigin.listen((request) async {
      requests.add('http:${request.uri.path}');
      if (request.uri.path == '/to-https') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'https://127.0.0.1:${secureOrigin.port}/audio',
        );
      } else {
        request.response.write('plain audio');
      }
      await request.response.close();
    });
    settings = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await settings.ready;
    resolver = FakeProxyResolver([]);
    network = NetworkHttp(
      settings: settings,
      bridge: NetworkProxyBridge(settings: settings, resolver: resolver),
    );
  });

  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await network.dispose();
    settings.dispose();
    await secureOrigin.close(force: true);
    await plainOrigin.close(force: true);
  });

  SecurityContext trustedTls() =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(tlsFixture.certificate);

  // Trust only the fixture CA. Hostname and TLS verification remain enabled.
  HttpClient podcastClient() {
    final client = network.createPodcastClient(
      routeFor: PodcastConnectionPolicy().modeFor,
      securityContext: trustedTls(),
    );
    clients.add(client);
    return client;
  }

  test('podcast direct HTTPS performs TLS before sending HTTP', () async {
    final client = podcastClient();
    final response = await (await client.getUrl(
      Uri.parse('https://127.0.0.1:${secureOrigin.port}/audio'),
    )).close();
    expect(await response.transform(utf8.decoder).join(), 'encrypted audio');
    expect(requests, ['https:/audio']);
    expect(resolver.calls, 0);
  });

  test(
    'podcast HTTP redirects upgrade to TLS and can return to HTTP',
    () async {
      final client = podcastClient();
      for (final (url, body) in [
        ('http://127.0.0.1:${plainOrigin.port}/to-https', 'encrypted audio'),
        ('https://127.0.0.1:${secureOrigin.port}/to-http', 'plain audio'),
      ]) {
        final response = await (await client.getUrl(Uri.parse(url))).close();
        expect(await response.transform(utf8.decoder).join(), body);
      }
      expect(requests, [
        'http:/to-https',
        'https:/audio',
        'https:/to-http',
        'http:/audio',
      ]);
      expect(resolver.calls, 0);
    },
  );

  test('shared loopback HTTPS clients also perform verified TLS', () async {
    final client = network.createClient(securityContext: trustedTls());
    clients.add(client);
    final response = await (await client.getUrl(
      Uri.parse('https://127.0.0.1:${secureOrigin.port}/audio'),
    )).close();
    expect(await response.transform(utf8.decoder).join(), 'encrypted audio');
  });

  test('podcast direct HTTPS rejects an untrusted certificate', () async {
    final client = network.createPodcastClient(
      routeFor: PodcastConnectionPolicy().modeFor,
    );
    clients.add(client);
    await expectLater(
      () async => (await client.getUrl(
        Uri.parse('https://127.0.0.1:${secureOrigin.port}/audio'),
      )).close(),
      throwsA(isA<HandshakeException>()),
    );
    expect(requests, isEmpty);
    expect(resolver.calls, 0);
  });
}
