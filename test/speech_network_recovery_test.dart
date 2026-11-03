import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'network_proxy_bridge_test.dart' show FakeProxyResolver;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

class _MappedNetwork extends NetworkHttp {
  _MappedNetwork({
    required super.settings,
    required super.bridge,
    required this.originPort,
  });
  final int originPort;
  @override
  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) {
    final client = super.createClient(
      scope: scope,
      source: source,
      context: context,
      modeOverride: modeOverride,
      cancelOnChange: cancelOnChange,
      securityContext: securityContext,
    );
    if (context?.scope == NetworkScope.speechRecognition &&
        context?.mode == NetworkMode.direct) {
      client.connectionFactory = (_, _, _) =>
          Socket.startConnect('127.0.0.1', originPort);
    }
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ASR recovery bypasses a unified proxy for one task without affecting translation or saved settings',
    () async {
      HttpOverrides.global = null;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      origin.listen((request) async {
        seen.add('direct');
        request.response.write('direct');
        await request.response.close();
      });
      proxy.listen((request) async {
        seen.add('proxy');
        request.response.write('proxy');
        await request.response.close();
      });
      final store = MemoryNetworkStore()
        ..saved = NetworkConfiguration(unifiedMode: NetworkMode.system);
      final settings = NetworkSettingsService(
        store: store,
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final originalSettings = jsonEncode(settings.configuration.toJson());
      final network = _MappedNetwork(
        settings: settings,
        originPort: origin.port,
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
      final speech = network.createDio(scope: NetworkScope.speechRecognition);
      final translation = network.createDio(scope: NetworkScope.translation);
      addTearDown(() async {
        speech.close(force: true);
        translation.close(force: true);
        await network.dispose();
        await origin.close(force: true);
        await proxy.close(force: true);
      });
      final url = 'http://origin.test:${origin.port}/task/result';
      final recovery = Options(
        extra: {NetworkHttp.speechRecognitionDirectRecoveryKey: true},
      );
      expect((await speech.get<String>(url)).data, 'proxy');
      expect((await speech.get<String>(url, options: recovery)).data, 'direct');
      expect((await speech.get<String>(url)).data, 'proxy');
      expect(
        (await translation.get<String>(url, options: recovery)).data,
        'proxy',
      );
      expect(seen, ['proxy', 'direct', 'proxy', 'proxy']);
      expect(jsonEncode(settings.configuration.toJson()), originalSettings);
      expect(jsonEncode(store.saved!.toJson()), originalSettings);
    },
  );
}
