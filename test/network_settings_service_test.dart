import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/network/network_models.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';

class MemoryNetworkStore implements NetworkConfigStore {
  NetworkConfiguration? saved;
  bool failWrite = false;
  Completer<void>? gate;
  @override
  Future<NetworkConfiguration?> read() async => saved;
  @override
  Future<void> write(NetworkConfiguration value) async {
    await gate?.future;
    if (failWrite) throw const FileSystemException('disk full');
    saved = value;
  }
}

class MemoryCredentials implements NetworkCredentialStore {
  final values = <String, String>{};
  bool locked = false;
  @override
  Future<String?> read(String key) async {
    if (locked) throw StateError('keychain locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unified policy persists and restores individual selections', () async {
    final store = MemoryNetworkStore();
    final service = NetworkSettingsService(
      store: store,
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await service.ready;
    await service.setMode(NetworkScope.translation, NetworkMode.direct);
    final individual = service.configuration.featureModes;
    final change = service.changes.first;
    await service.setUnifiedMode(NetworkMode.system);
    expect((await change).scopes, NetworkScope.values.toSet());
    expect(service.configuration.modes.values.toSet(), {NetworkMode.system});
    final saved = NetworkConfiguration.fromJson(store.saved!.toJson());
    expect(saved.unifiedMode, NetworkMode.system);
    expect(saved.featureModes, individual);
    final restarted = NetworkSettingsService(
      store: MemoryNetworkStore()..saved = saved,
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await restarted.ready;
    expect(
      (await restarted.context(
        NetworkScope.bilibili,
        modeOverride: NetworkMode.direct,
      )).mode,
      NetworkMode.system,
    );
    await restarted.setUnifiedMode(null);
    expect(restarted.configuration.modes, individual);
  });

  test('unified save failure retains the applied policy', () async {
    final store = MemoryNetworkStore();
    final service = NetworkSettingsService(
      store: store,
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await service.ready;
    await service.setUnifiedMode(NetworkMode.direct);
    store.failWrite = true;
    await expectLater(
      service.setUnifiedMode(NetworkMode.system),
      throwsA(isA<NetworkSettingsException>()),
    );
    expect(service.configuration.unifiedMode, NetworkMode.direct);
    expect(service.configuration.modes.values.toSet(), {NetworkMode.direct});
  });

  test(
    'custom unified mode is applied atomically with a valid proxy',
    () async {
      final store = MemoryNetworkStore();
      final service = NetworkSettingsService(
        store: store,
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await service.ready;
      await expectLater(
        service.setUnifiedMode(NetworkMode.custom),
        throwsA(isA<NetworkSettingsException>()),
      );
      expect(service.configuration.unifiedMode, isNull);
      await service.saveProxy(
        profile: const ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: 7890,
        ),
        password: null,
        applyGlobally: true,
      );
      expect(service.configuration.modes.values.toSet(), {NetworkMode.custom});
      expect(
        NetworkConfiguration.fromJson(store.saved!.toJson()).unifiedMode,
        NetworkMode.custom,
      );
      await service.setUnifiedMode(null);
      expect(
        service.configuration.modes[NetworkScope.bilibili],
        NetworkMode.direct,
      );
    },
  );

  test(
    'legacy configuration without a unified field preserves feature modes',
    () {
      final json = NetworkConfiguration().toJson()..remove('unifiedMode');
      final restored = NetworkConfiguration.fromJson(json);
      expect(restored.unifiedMode, isNull);
      expect(restored.modes[NetworkScope.bilibili], NetworkMode.direct);
      expect(restored.modes[NetworkScope.ytDlpOther], NetworkMode.system);
    },
  );
  test('legacy system policy leaves cloud playback independently direct', () {
    final legacy = NetworkConfiguration().toJson();
    (legacy['modes'] as Map).remove('cloudDrive');
    final restored = NetworkConfiguration.fromJson(legacy);
    expect(restored.modes[NetworkScope.cloudDrive], NetworkMode.direct);
    expect(restored.modes[NetworkScope.other], NetworkMode.system);
    expect(
      NetworkConfiguration.fromJson(restored.toJson()).modes,
      restored.modes,
    );
  });

  test('legacy explicit custom proxy remains selected for cloud requests', () {
    final legacy = NetworkConfiguration(
      modes: {NetworkScope.other: NetworkMode.custom},
      proxy: const ProxyProfile(
        protocol: ProxyProtocol.http,
        host: '127.0.0.1',
        port: 7890,
      ),
    ).toJson();
    (legacy['modes'] as Map).remove('cloudDrive');
    final restored = NetworkConfiguration.fromJson(legacy);
    expect(restored.modes[NetworkScope.cloudDrive], NetworkMode.custom);
    expect(restored.modes[NetworkScope.other], NetworkMode.custom);
  });

  test(
    'changing cloud policy keeps other features and publishes its scope',
    () async {
      final service = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await service.ready;
      final changed = service.changes.first;
      await service.setMode(NetworkScope.cloudDrive, NetworkMode.system);
      final event = await changed;
      expect(event.scopes, contains(NetworkScope.cloudDrive));
      expect(event.scopes, isNot(contains(NetworkScope.other)));
      expect(
        service.configuration.modes[NetworkScope.other],
        NetworkMode.system,
      );
      expect(
        service.configuration.modes[NetworkScope.bilibili],
        NetworkMode.direct,
      );
      service.dispose();
    },
  );
  test(
    'missing credential stays fail-closed until an explicit replacement is safely saved',
    () async {
      final store = MemoryNetworkStore()
        ..saved = NetworkConfiguration(
          proxy: const ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: 7890,
            username: 'account',
            credentialKey: 'missing',
          ),
          modes: {NetworkScope.ytDlpOther: NetworkMode.custom},
        );
      final credentials = MemoryCredentials();
      final service = NetworkSettingsService(
        store: store,
        credentials: credentials,
        migrateLegacy: false,
      );
      await expectLater(
        service.ready,
        throwsA(isA<NetworkSettingsException>()),
      );
      expect(service.canReplaceCredentials, isTrue);
      await expectLater(
        service.setMode(NetworkScope.ytDlpOther, NetworkMode.direct),
        throwsA(isA<NetworkSettingsException>()),
      );
      expect(
        service.configuration.modes[NetworkScope.ytDlpOther],
        NetworkMode.custom,
      );
      await service.saveProxy(
        profile: service.configuration.proxy!,
        password: 'replacement',
      );
      final context = await service.context(NetworkScope.ytDlpOther);
      expect(context.mode, NetworkMode.custom);
      expect(
        await service.passwordFor(context.configuration.proxy),
        'replacement',
      );
      expect(service.isLoaded, isTrue);
      expect(service.state, NetworkSaveState.applied);
    },
  );
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          null,
        );
  });
  test(
    'source boundaries and defaults do not depend on a CDN or .cn suffix',
    () {
      for (final source in ['bilibili.com', 'api.bilibili.com', 'b23.tv']) {
        expect(
          NetworkSites.forYtDlp(Uri.https(source, '/')),
          NetworkScope.bilibili,
        );
      }
      for (final source in [
        'v.douyin.com',
        'xhslink.cn',
        'v.qq.com',
        'www.acfun.cn',
      ]) {
        expect(
          NetworkSites.forYtDlp(Uri.https(source, '/')),
          NetworkScope.ytDlpDomestic,
        );
      }
      for (final source in [
        'evilbilibili.com',
        'bilibili.com.evil.test',
        'unknown.cn',
        'youtube.com',
        'wetv.vip',
      ]) {
        expect(
          NetworkSites.forYtDlp(Uri.https(source, '/')),
          NetworkScope.ytDlpOther,
        );
      }
      expect(NetworkScope.bilibili.defaultMode, NetworkMode.direct);
      expect(NetworkScope.speechRecognition.defaultMode, NetworkMode.direct);
      expect(NetworkScope.ytDlpOther.defaultMode, NetworkMode.system);
    },
  );

  test('rapid selections commit in order, last valid choice wins', () async {
    final store = MemoryNetworkStore()..gate = Completer();
    final service = NetworkSettingsService(
      store: store,
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await service.ready;
    final first = service.setMode(NetworkScope.translation, NetworkMode.direct);
    final second = service.setMode(
      NetworkScope.translation,
      NetworkMode.system,
    );
    expect(service.state, NetworkSaveState.saving);
    expect(
      service.configuration.modes[NetworkScope.translation],
      NetworkMode.system,
    );
    store.gate!.complete();
    await Future.wait([first, second]);
    expect(service.configuration.revision, 2);
    expect(store.saved!.modes[NetworkScope.translation], NetworkMode.system);
    expect(service.state, NetworkSaveState.applied);
  });

  test('failed write preserves applied settings and emits no change', () async {
    final store = MemoryNetworkStore();
    final service = NetworkSettingsService(
      store: store,
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await service.ready;
    await service.setMode(NetworkScope.translation, NetworkMode.direct);
    final changes = <NetworkSettingsChange>[];
    final subscription = service.changes.listen(changes.add);
    store.failWrite = true;
    await expectLater(
      service.setMode(NetworkScope.translation, NetworkMode.system),
      throwsA(isA<NetworkSettingsException>()),
    );
    expect(
      service.configuration.modes[NetworkScope.translation],
      NetworkMode.direct,
    );
    expect(service.configuration.revision, 1);
    expect(changes, isEmpty);
    expect(service.state, NetworkSaveState.failed);
    await subscription.cancel();
  });

  test(
    'password save is separate, failed edit cannot overwrite the active secret',
    () async {
      final store = MemoryNetworkStore();
      final credentials = MemoryCredentials();
      final service = NetworkSettingsService(
        store: store,
        credentials: credentials,
        migrateLegacy: false,
      );
      await service.ready;
      const proxy = ProxyProfile(
        protocol: ProxyProtocol.socks5,
        host: '::1',
        port: 1080,
        username: 'account',
      );
      await service.saveProxy(
        profile: proxy,
        password: 'old-secret',
        applyTo: NetworkScope.ytDlpOther,
      );
      final previous = service.configuration;
      expect(jsonEncode(store.saved!.toJson()), isNot(contains('old-secret')));
      store.failWrite = true;
      await expectLater(
        service.saveProxy(profile: proxy, password: 'new-secret'),
        throwsA(isA<NetworkSettingsException>()),
      );
      expect(service.configuration, same(previous));
      expect(
        await service.passwordFor(service.configuration.proxy),
        'old-secret',
      );
      credentials.locked = true;
      final restarted = NetworkSettingsService(
        store: store,
        credentials: credentials,
        migrateLegacy: false,
      );
      await expectLater(
        restarted.ready,
        throwsA(isA<NetworkSettingsException>()),
      );
      expect(
        restarted.configuration.modes[NetworkScope.ytDlpOther],
        NetworkMode.custom,
      );
      expect(
        restarted.configuration.proxy!.credentialKey,
        previous.proxy!.credentialKey,
      );
    },
  );

  test(
    'scope generation ignores unrelated changes but rejects switch-back callbacks',
    () async {
      final service = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      final bili = await service.context(NetworkScope.bilibili);
      await service.setMode(NetworkScope.translation, NetworkMode.direct);
      expect(service.isCurrent(bili), isTrue);
      await service.setMode(NetworkScope.bilibili, NetworkMode.system);
      await service.setMode(NetworkScope.bilibili, NetworkMode.direct);
      expect(service.isCurrent(bili), isFalse);
      final newBili = await service.context(NetworkScope.bilibili);
      service.deviceNetworkChanged();
      expect(service.isCurrent(newBili), isTrue);
      final system = await service.context(NetworkScope.ytDlpOther);
      service.deviceNetworkChanged();
      expect(service.isCurrent(system), isFalse);
    },
  );

  test(
    'checksummed atomic file restores previous valid configuration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network_store_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileNetworkConfigStore(directory: () async => directory);
      final first = NetworkConfiguration(revision: 1);
      final second = first.copyWith(
        modes: {...first.modes, NetworkScope.translation: NetworkMode.direct},
      );
      await store.write(first);
      await store.write(second);
      expect((await store.read())!.revision, 2);
      await File(
        '${directory.path}/network_settings_v1.json',
      ).writeAsString('truncated');
      expect((await store.read())!.revision, 1);
      await File(
        '${directory.path}/network_settings_v1.json',
      ).writeAsString('[1, 2]');
      await store.write(second);
      expect((await store.read())!.revision, 2);
      expect(
        jsonDecode(
          await File(
            '${directory.path}/network_settings_v1.json.bak',
          ).readAsString(),
        ),
        isA<Map>(),
      );
      await File(
        '${directory.path}/network_settings_v1.json',
      ).writeAsString('truncated');
      await File(
        '${directory.path}/network_settings_v1.json.bak',
      ).writeAsString('corrupt');
      await expectLater(store.read(), throwsA(isA<NetworkSettingsException>()));
    },
  );

  test('legacy credentials migrate before legacy address is removed', () async {
    SharedPreferences.setMockInitialValues({
      'yt_dlp_session_config_v1': jsonEncode({
        'useProxy': true,
        'proxy': 'http://user:p%40ss@127.0.0.1:7890',
        'retries': 2,
      }),
      'yt_dlp_tasks_v1': 'retained task records',
    });
    final store = MemoryNetworkStore();
    final credentials = MemoryCredentials();
    final service = NetworkSettingsService(
      store: store,
      credentials: credentials,
    );
    await service.ready;
    expect(
      service.configuration.modes[NetworkScope.ytDlpOther],
      NetworkMode.custom,
    );
    expect(
      service.configuration.modes[NetworkScope.bilibili],
      NetworkMode.direct,
    );
    expect(await service.passwordFor(service.configuration.proxy), 'p@ss');
    final prefs = await SharedPreferences.getInstance();
    final migrated =
        jsonDecode(prefs.getString('yt_dlp_session_config_v1')!) as Map;
    expect(migrated, {'retries': 2});
    expect(prefs.getString('yt_dlp_tasks_v1'), 'retained task records');
    expect(jsonEncode(store.saved!.toJson()), isNot(contains('p@ss')));
  });

  test(
    'native-only legacy configuration and saved task secrets migrate before requests',
    () async {
      final task = {
        'taskId': 'retained',
        'progress': 0.42,
        'executionSessionConfig': {
          'retries': 3,
          'proxy': 'http://u:secret@host:8080',
          'useProxy': true,
        },
        'request': {
          'args': [
            '--continue',
            '--proxy',
            'http://u:secret@host:8080',
            'https://example.com/video',
          ],
          'debugContext': {
            'nested': {'proxy': 'http://u:secret@host:8080'},
          },
        },
      };
      SharedPreferences.setMockInitialValues({
        'yt_dlp_state_v2': jsonEncode({
          'revision': 9,
          'tasks': [task],
        }),
      });
      Map? savedNative;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.example.video_player_app/yt_dlp'),
            (call) async {
              if (call.method == 'loadYoutubeSessionConfig') {
                return {
                  'useProxy': true,
                  'proxy': 'socks5://u:secret@127.0.0.1:1080',
                  'retries': 3,
                };
              }
              if (call.method == 'saveYoutubeSessionConfig') {
                savedNative = (call.arguments as Map)['config'] as Map;
              }
              return null;
            },
          );
      final service = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
      );
      await service.ready;
      expect(
        service.configuration.modes[NetworkScope.ytDlpOther],
        NetworkMode.custom,
      );
      expect(await service.passwordFor(service.configuration.proxy), 'secret');
      expect(savedNative, {'retries': 3});
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('yt_dlp_state_v2')!;
      expect(raw, isNot(contains('secret')));
      expect(raw, isNot(contains('--proxy')));
      final retained = (jsonDecode(raw) as Map)['tasks'][0] as Map;
      expect(retained['progress'], 0.42);
      expect(retained['executionSessionConfig'], {'retries': 3});
    },
  );

  test(
    'Linux proxy environment handles domain boundary, port and IPv6/CIDR',
    () {
      final environment = {
        'https_proxy': 'http://proxy.test:8080',
        'no_proxy': '.example.com:443,[::1],10.0.0.0/8',
      };
      expect(
        PlatformProxyResolver.environmentProxy(
          Uri.parse('https://a.example.com/'),
          environment,
        ),
        [null],
      );
      expect(
        PlatformProxyResolver.environmentProxy(
          Uri.parse('https://evil-example.com/'),
          environment,
        )!.single!.host,
        'proxy.test',
      );
      expect(
        PlatformProxyResolver.environmentProxy(
          Uri.parse('https://example.com:444/'),
          environment,
        )!.single,
        isNotNull,
      );
      expect(
        PlatformProxyResolver.environmentProxy(
          Uri.parse('https://[::1]/'),
          environment,
        ),
        [null],
      );
      expect(
        PlatformProxyResolver.environmentProxy(
          Uri.parse('https://10.12.0.1/'),
          environment,
        ),
        [null],
      );
    },
  );
}
