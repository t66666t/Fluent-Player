import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_webdav.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;
import 'network_transport_security_test.dart' show serverTls, trustedTls;

class _TrustedNetwork extends NetworkHttp {
  _TrustedNetwork({required super.settings});
  @override
  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) => super.createClient(
    scope: scope,
    source: source,
    context: context,
    modeOverride: modeOverride,
    cancelOnChange: cancelOnChange,
    securityContext: trustedTls(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final local in [false, true]) {
    test(
      '${local ? 'home NAS bypasses' : 'public WebDAV follows'} the unified proxy',
      () async {
        HttpOverrides.global = null;
        final origin = local
            ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
            : await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4,
                0,
                serverTls(),
              );
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        var proxyCalls = 0, writes = 0;
        origin.listen((request) async {
          await request.drain<void>();
          expect(
            request.headers.value('authorization'),
            'Basic ${base64Encode(utf8.encode('user:password'))}',
          );
          if (request.method == 'MKCOL') {
            request.response.statusCode = 201;
          } else if (request.method == 'PUT') {
            writes++;
            expect(request.headers.value('if-none-match'), '*');
            request.response.statusCode = 201;
          } else {
            request.response.statusCode = 207;
            request.response.write('''
<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>${request.uri.path}</d:href><d:propstat><d:prop>
<d:resourcetype><d:collection/></d:resourcetype>
</d:prop><d:status>HTTP/1.1 200 OK</d:status>
</d:propstat></d:response></d:multistatus>''');
          }
          await request.response.close();
        }, onError: (_) {});
        proxy.listen((request) async {
          proxyCalls++;
          expect(request.method, 'CONNECT');
          final upstream = await Socket.connect('127.0.0.1', origin.port);
          final downstream = await request.response.detachSocket(
            writeHeaders: false,
          );
          sockets.addAll([upstream, downstream]);
          downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
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
          ),
          password: null,
          applyGlobally: true,
        );
        final network = _TrustedNetwork(settings: settings);
        final sync = ProgressSyncWebDav(
          config: ProgressSyncWebDavConfig(
            url:
                '${local ? 'http://127.0.0.1' : 'https://origin.test'}:${origin.port}/dav/',
            username: 'user',
            password: 'password',
          ),
          network: network,
        );
        try {
          await sync.writeChanges([
            {'eventId': 'one', 'cipherText': 'encrypted'},
          ]);
          expect(await sync.readChanges(), isEmpty);
          expect(writes, 1);
          expect(proxyCalls, local ? 0 : greaterThan(0));
        } finally {
          sync.close();
          await network.dispose();
          settings.dispose();
          for (final socket in sockets) {
            socket.destroy();
          }
          await proxy.close(force: true);
          await origin.close(force: true);
        }
      },
    );
  }
  test('IPv6 loopback remains a valid local WebDAV address', () {
    HttpOverrides.global = null;
    final sync = ProgressSyncWebDav(
      config: const ProgressSyncWebDavConfig(url: 'http://[::1]/dav/'),
    );
    sync.close();
  });
}
