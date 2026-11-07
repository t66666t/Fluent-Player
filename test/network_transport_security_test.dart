import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'support/temporary_tls_fixture.dart';

class Bytes {
  final StreamIterator<Uint8List> iterator;
  List<int> buffered = [];
  Bytes(Socket socket) : iterator = StreamIterator(socket);
  Future<List<int>> take(int count) async {
    while (buffered.length < count) {
      if (!await iterator.moveNext()) {
        throw StateError('Unexpected socket close');
      }
      buffered.addAll(iterator.current);
    }
    final value = buffered.sublist(0, count);
    buffered = buffered.sublist(count);
    return value;
  }

  Future<String> header() async {
    var text = '';
    while (!text.endsWith('\r\n\r\n')) {
      text += String.fromCharCode((await take(1)).single);
    }
    return text;
  }
}

NetworkSettingsService settings() => NetworkSettingsService(
  store: MemoryNetworkStore(),
  credentials: MemoryCredentials(),
  migrateLegacy: false,
);

late TemporaryTlsFixture tlsFixture;

SecurityContext serverTls() => SecurityContext()
  ..useCertificateChain(tlsFixture.certificate)
  ..usePrivateKey(tlsFixture.privateKey);
SecurityContext trustedTls() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(tlsFixture.certificate);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => tlsFixture = await TemporaryTlsFixture.create());
  tearDownAll(() async => tlsFixture.dispose());
  setUp(() => HttpOverrides.global = null);

  for (final secureProxy in [false, true]) {
    test(
      'TLS stays verified through ${secureProxy ? 'HTTPS' : 'HTTP'} CONNECT with authentication',
      () async {
        final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverTls(),
        );
        final proxy = secureProxy
            ? await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4,
                0,
                serverTls(),
              )
            : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var originCalls = 0;
        String? authorization;
        origin.listen((request) async {
          originCalls++;
          expect(request.headers.value('proxy-authorization'), isNull);
          request.response.write('verified TLS');
          await request.response.close();
        }, onError: (_) {});
        proxy.listen((request) async {
          expect(request.method, 'CONNECT');
          expect(request.uri.toString(), 'origin.test:${origin.port}');
          authorization = request.headers.value('proxy-authorization');
          final upstream = await Socket.connect('127.0.0.1', origin.port);
          final downstream = await request.response.detachSocket(
            writeHeaders: false,
          );
          downstream.add(
            ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
          );
          await downstream.flush();
          unawaited(
            upstream
                .addStream(downstream)
                .catchError((_) {})
                .whenComplete(upstream.destroy),
          );
          unawaited(
            downstream
                .addStream(upstream)
                .catchError((_) {})
                .whenComplete(downstream.destroy),
          );
        }, onError: (_) {});
        final config = settings();
        await config.ready;
        await config.saveProxy(
          profile: ProxyProfile(
            protocol: secureProxy ? ProxyProtocol.https : ProxyProtocol.http,
            host: secureProxy ? 'proxy.test' : '127.0.0.1',
            port: proxy.port,
            username: 'account',
          ),
          password: 'secret',
          applyTo: NetworkScope.bilibili,
        );
        final bridge = NetworkProxyBridge(
          settings: config,
          socketConnector: (host, port, secure) async {
            final socket = await Socket.connect('127.0.0.1', port);
            return secure
                ? SecureSocket.secure(socket, host: host, context: trustedTls())
                : socket;
          },
        );
        final network = NetworkHttp(settings: config, bridge: bridge);
        final trusted = network.createClient(
          scope: NetworkScope.bilibili,
          securityContext: trustedTls(),
        );
        final untrusted = network.createClient(scope: NetworkScope.bilibili);
        addTearDown(() async {
          trusted.close(force: true);
          untrusted.close(force: true);
          await network.dispose();
          await origin.close(force: true);
          await proxy.close(force: true);
        });
        final url = Uri.parse('https://origin.test:${origin.port}/media');
        final response = await (await trusted.getUrl(url)).close();
        expect(await response.transform(utf8.decoder).join(), 'verified TLS');
        expect(
          authorization,
          'Basic ${base64Encode(utf8.encode('account:secret'))}',
        );
        await expectLater(
          () async => (await untrusted.getUrl(url)).close(),
          throwsA(isA<HandshakeException>()),
        );
        expect(
          originCalls,
          1,
          reason: 'An untrusted origin must fail before receiving HTTP',
        );
      },
    );
  }

  test(
    'SOCKS5 uses authenticated remote DNS and binary IPv6 destinations',
    () async {
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final destinations = <Object>[];
      final sockets = <Socket>[];
      proxy.listen((socket) async {
        sockets.add(socket);
        final input = Bytes(socket);
        expect(await input.take(3), [5, 1, 2]);
        socket.add([5, 2]);
        await socket.flush();
        expect(await input.take(1), [1]);
        final user = utf8.decode(
          await input.take((await input.take(1)).single),
        );
        final password = utf8.decode(
          await input.take((await input.take(1)).single),
        );
        expect(user, '用户');
        expect(password, 'secret');
        socket.add([1, 0]);
        await socket.flush();
        final command = await input.take(4);
        expect(command.sublist(0, 3), [5, 1, 0]);
        if (command[3] == 3) {
          destinations.add(
            utf8.decode(await input.take((await input.take(1)).single)),
          );
        } else {
          expect(command[3], 4);
          destinations.add(
            InternetAddress.fromRawAddress(
              Uint8List.fromList(await input.take(16)),
            ).address,
          );
        }
        expect(await input.take(2), [0, 80]);
        socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
        await socket.flush();
        final header = await input.header();
        expect(header, isNot(contains('secret')));
        expect(header, startsWith('GET /media HTTP/1.1'));
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nsocks',
          ),
        );
        await socket.flush();
        await socket.close();
      });
      final config = settings();
      await config.ready;
      await config.saveProxy(
        profile: ProxyProfile(
          protocol: ProxyProtocol.socks5,
          host: '127.0.0.1',
          port: proxy.port,
          username: '用户',
        ),
        password: 'secret',
        applyTo: NetworkScope.ytDlpOther,
      );
      final network = NetworkHttp(settings: config);
      final client = network.createClient(scope: NetworkScope.ytDlpOther);
      addTearDown(() async {
        client.close(force: true);
        await network.dispose();
        for (final socket in sockets) {
          socket.destroy();
        }
        await proxy.close();
      });
      for (final host in ['origin.test', '[2001:db8::5]']) {
        final response = await (await client.getUrl(
          Uri.parse('http://$host/media'),
        )).close();
        expect(await response.transform(utf8.decoder).join(), 'socks');
      }
      expect(destinations, ['origin.test', '2001:db8::5']);
      expect(NetworkSites.isLoopback('[::1]'), isTrue);
    },
  );

  test(
    'switch drains active reads and submits an account action exactly once; new reads use the new route',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final submitted = Completer<void>(),
          readStarted = Completer<void>(),
          finish = Completer<void>();
      var posts = 0;
      origin.listen((request) async {
        if (request.method == 'POST') {
          posts++;
          submitted.complete();
        } else {
          readStarted.complete();
        }
        await finish.future;
        try {
          request.response.write('old submitted action');
          await request.response.close();
        } catch (_) {}
      });
      proxy.listen((request) async {
        request.response.write('new route');
        await request.response.close();
      });
      final config = settings();
      await config.ready;
      final network = NetworkHttp(
        settings: config,
        bridge: NetworkProxyBridge(
          settings: config,
          resolver: FakeProxyResolver([
            ProxyProfile(
              protocol: ProxyProtocol.http,
              host: '127.0.0.1',
              port: proxy.port,
            ),
          ]),
          socketConnector: (host, port, secure) => Socket.connect(
            '127.0.0.1',
            host == '127.0.0.1' ? port : origin.port,
          ),
        ),
      );
      final dio = network.createDio(scope: NetworkScope.bilibili);
      addTearDown(() async {
        if (!finish.isCompleted) finish.complete();
        dio.close(force: true);
        await network.dispose();
        await origin.close(force: true);
        await proxy.close(force: true);
      });
      final post = dio.post<String>(
        'http://origin.test/account',
        data: 'one action',
      );
      await submitted.future;
      final oldRead = dio.get<String>('http://origin.test/video');
      await readStarted.future;
      await config.setMode(NetworkScope.bilibili, NetworkMode.system);
      finish.complete();
      expect((await oldRead).data, 'old submitted action');
      expect((await post).data, 'old submitted action');
      expect(posts, 1);
      expect(
        (await dio.get<String>('http://origin.test/video')).data,
        'new route',
      );
    },
  );

  test(
    'native browser keeps its loopback port and adopts the latest committed policy',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((request) async {
        request.response.write('custom');
        await request.response.close();
      });
      final config = settings();
      await config.ready;
      final network = NetworkHttp(settings: config);
      final first = await network.bridge.browserEndpoint(NetworkScope.bilibili);
      await config.saveProxy(
        profile: ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: proxy.port,
        ),
        password: null,
        applyTo: NetworkScope.bilibili,
      );
      expect(
        await network.bridge.browserEndpoint(NetworkScope.bilibili),
        first,
      );
      final nativeClient = HttpClient()
        ..findProxy = (_) => 'PROXY ${first.host}:${first.port}';
      addTearDown(() async {
        nativeClient.close(force: true);
        await network.dispose();
        await proxy.close(force: true);
      });
      final response = await (await nativeClient.getUrl(
        Uri.parse('http://origin.invalid/video'),
      )).close();
      expect(await response.transform(utf8.decoder).join(), 'custom');
    },
  );
}
