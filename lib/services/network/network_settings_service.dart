import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'network_models.dart';

abstract interface class NetworkConfigStore {
  Future<NetworkConfiguration?> read();
  Future<void> write(NetworkConfiguration configuration);
}

abstract interface class NetworkCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureNetworkCredentialStore implements NetworkCredentialStore {
  final FlutterSecureStorage storage;
  const SecureNetworkCredentialStore([
    this.storage = const FlutterSecureStorage(),
  ]);
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// A checksummed primary file and the previous committed version. Temporary
/// files are never considered committed, including after a power interruption.
class FileNetworkConfigStore implements NetworkConfigStore {
  final Future<Directory> Function() directory;
  FileNetworkConfigStore({Future<Directory> Function()? directory})
    : directory = directory ?? getApplicationSupportDirectory;

  Future<File> _file() async =>
      File(p.join((await directory()).path, 'network_settings_v1.json'));

  Future<NetworkConfiguration> _decode(File file) async {
    final envelope = jsonDecode(await file.readAsString()) as Map;
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
      throw const FormatException('网络配置校验失败');
    }
    return NetworkConfiguration.fromJson(
      Map<String, dynamic>.from(jsonDecode(payload) as Map),
    );
  }

  @override
  Future<NetworkConfiguration?> read() async {
    final file = await _file();
    final backup = File('${file.path}.bak');
    if (!await file.exists() && !await backup.exists()) return null;
    try {
      return await _decode(file);
    } catch (_) {
      try {
        return await _decode(backup);
      } catch (_) {
        throw const NetworkSettingsException(
          '网络设置文件无法读取。为避免使用错误的网络方式，联网已暂停。请重试加载。',
        );
      }
    }
  }

  @override
  Future<void> write(NetworkConfiguration configuration) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final payload = jsonEncode(configuration.toJson());
    final bytes = jsonEncode({
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(bytes, flush: true);
    // Only back up validated data; a corrupt primary must not destroy recovery.
    if (await file.exists()) {
      try {
        await _decode(file);
        final backupTemp = File('${file.path}.bak.tmp');
        await backupTemp.writeAsBytes(await file.readAsBytes(), flush: true);
        await backupTemp.rename('${file.path}.bak');
      } on FormatException {
        /* Keep the last valid backup. */
      } on TypeError {
        /* Malformed JSON must not prevent backup recovery. */
      }
    }
    await temp.rename(file.path);
  }
}

enum NetworkSaveState { loading, applied, saving, failed }

class NetworkSettingsChange {
  final NetworkConfiguration previous;
  final NetworkConfiguration current;
  final Set<NetworkScope> scopes;
  final bool deviceChanged;
  const NetworkSettingsChange(
    this.previous,
    this.current,
    this.scopes, {
    this.deviceChanged = false,
  });
}

class NetworkSettingsService extends ChangeNotifier {
  static final instance = NetworkSettingsService();
  final NetworkConfigStore store;
  final NetworkCredentialStore credentials;
  final bool migrateLegacy;
  final StreamController<NetworkSettingsChange> _changes =
      StreamController.broadcast(sync: true);
  NetworkConfiguration _configuration = NetworkConfiguration();
  Future<void>? _initialization;
  Future<void> _queue = Future.value();
  NetworkSaveState state = NetworkSaveState.loading;
  String? error;
  int deviceGeneration = 0;
  final Map<NetworkScope, int> _scopeGenerations = {};
  int _pending = 0;
  bool isLoaded = false;
  bool _credentialReadFailed = false;
  bool get canReplaceCredentials => !isLoaded && _credentialReadFailed;
  NetworkConfiguration get configuration => _configuration;
  Stream<NetworkSettingsChange> get changes => _changes.stream;

  NetworkSettingsService({
    NetworkConfigStore? store,
    NetworkCredentialStore? credentials,
    this.migrateLegacy = true,
  }) : store = store ?? FileNetworkConfigStore(),
       credentials = credentials ?? const SecureNetworkCredentialStore();

  Future<void> get ready => init();
  Future<void> init() => _initialization ??= _load();

  Future<void> _load() async {
    _credentialReadFailed = false;
    try {
      final saved = await store.read();
      _configuration = saved ?? NetworkConfiguration();
      if (migrateLegacy) await _migrateLegacyProxy(saved == null);
      // Reading a configured password is mandatory. A locked keychain must not
      // turn a custom authenticated proxy into an unauthenticated/direct route.
      try {
        await passwordFor(_configuration.proxy);
      } catch (_) {
        _credentialReadFailed = true;
        rethrow;
      }
      if (migrateLegacy) await _scrubLegacyTaskRecords();
      isLoaded = true;
      state = NetworkSaveState.applied;
      error = null;
      notifyListeners();
    } catch (_) {
      state = NetworkSaveState.failed;
      error = _credentialReadFailed
          ? '代理密码无法读取，联网已暂停。请解锁设备后重试，或重新保存代理密码。'
          : '网络设置无法读取，联网已暂停。请重试加载。';
      notifyListeners();
      throw NetworkSettingsException(error!);
    }
  }

  Future<void> retryLoad() {
    _initialization = null;
    state = NetworkSaveState.loading;
    notifyListeners();
    return init();
  }

  Future<String?> passwordFor(ProxyProfile? profile) async {
    final key = profile?.credentialKey;
    if (key == null) return null;
    try {
      final password = await credentials.read(key);
      if (password == null) throw const NetworkSettingsException('代理密码无法读取');
      return password;
    } catch (_) {
      throw const NetworkSettingsException('代理密码无法从安全存储读取，请解锁设备或重新保存代理配置。');
    }
  }

  Future<void> _migrateLegacyProxy(bool firstConfiguration) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('yt_dlp_session_config_v1');
    Map<String, dynamic>? nativeLegacy;
    const legacyChannel = MethodChannel('com.example.video_player_app/yt_dlp');
    if (!Platform.isLinux) {
      try {
        nativeLegacy = await legacyChannel.invokeMapMethod<String, dynamic>(
          'loadYoutubeSessionConfig',
        );
      } on MissingPluginException {
        /* A fresh install has no legacy runtime. */
      }
    }
    if (raw == null && nativeLegacy == null) return;
    final legacy = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : nativeLegacy!;
    final address =
        (legacy['proxy'] ?? nativeLegacy?['proxy'])?.toString().trim() ?? '';
    if (address.isNotEmpty && firstConfiguration) {
      final uri = Uri.parse(address);
      final key = uri.userInfo.contains(':')
          ? 'network_proxy_${const Uuid().v4()}'
          : null;
      if (key != null) {
        final password = Uri.decodeComponent(
          uri.userInfo.substring(uri.userInfo.indexOf(':') + 1),
        );
        await credentials.write(key, password);
        if (await credentials.read(key) != password) {
          throw const NetworkSettingsException('旧代理密码迁移验证失败');
        }
      }
      final proxy = ProxyProfile.fromUri(address, credentialKey: key);
      final modes = Map<NetworkScope, NetworkMode>.from(_configuration.modes);
      if ((legacy['useProxy'] ?? nativeLegacy?['useProxy']) == true) {
        modes[NetworkScope.ytDlpOther] = NetworkMode.custom;
      }
      final migrated = _configuration.copyWith(proxy: proxy, modes: modes);
      await store.write(migrated);
      final verified = await store.read();
      if (jsonEncode(verified?.toJson()) != jsonEncode(migrated.toJson())) {
        throw const NetworkSettingsException('旧代理迁移验证失败');
      }
      _configuration = migrated;
    }
    // Leave every unrelated preference and task record intact. Task snapshots
    // are scrubbed after the service has loaded them (including native copies).
    if (legacy.containsKey('proxy') ||
        legacy.containsKey('useProxy') ||
        nativeLegacy?.containsKey('proxy') == true ||
        nativeLegacy?.containsKey('useProxy') == true) {
      legacy.remove('proxy');
      legacy.remove('useProxy');
      if (!await prefs.setString(
        'yt_dlp_session_config_v1',
        jsonEncode(legacy),
      )) {
        throw const NetworkSettingsException('旧代理配置清理失败');
      }
      if (!Platform.isLinux) {
        try {
          await legacyChannel.invokeMethod('saveYoutubeSessionConfig', {
            'config': legacy,
          });
        } on MissingPluginException {
          /* No native copy exists on this install. */
        }
      }
    }
  }

  Future<void> _scrubLegacyTaskRecords() async {
    final prefs = await SharedPreferences.getInstance();
    Object? scrub(Object? value) {
      if (value is Map) {
        return {
          for (final entry in value.entries)
            if (!const {
              'proxy',
              'useProxy',
              'proxyPassword',
              'proxyUsername',
            }.contains(entry.key))
              entry.key: scrub(entry.value),
        };
      }
      if (value is List) {
        final result = <Object?>[];
        for (var i = 0; i < value.length; i++) {
          if (value[i] == '--proxy') {
            i++;
            continue;
          }
          if (value[i] is String &&
              (value[i] as String).startsWith('--proxy=')) {
            continue;
          }
          result.add(scrub(value[i]));
        }
        return result;
      }
      if (value is String) {
        return value.replaceAllMapped(
          RegExp(r'((?:https?|socks5h?)://)[^/\s@]+@'),
          (match) => '${match[1]}[redacted]@',
        );
      }
      return value;
    }

    for (final key in ['yt_dlp_tasks_v1', 'yt_dlp_state_v2']) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        continue;
      }
      final clean = jsonEncode(scrub(decoded));
      if (jsonEncode(decoded) == clean) continue;
      if (!await prefs.setString(key, clean) || prefs.getString(key) != clean) {
        throw const NetworkSettingsException('旧任务中的代理信息清理失败');
      }
    }
  }

  Future<void> _submit(
    Future<NetworkConfiguration> Function() build, {
    bool replaceCredentials = false,
  }) {
    final result = Completer<void>();
    _pending++;
    state = NetworkSaveState.saving;
    error = null;
    notifyListeners();
    _queue = _queue.then((_) async {
      try {
        final recoveringCredentials =
            replaceCredentials && canReplaceCredentials;
        if (!recoveringCredentials) await ready;
        state = NetworkSaveState.saving;
        notifyListeners();
        final next = await build();
        await passwordFor(next.proxy);
        if (recoveringCredentials && migrateLegacy) {
          await _scrubLegacyTaskRecords();
        }
        await store.write(next);
        final previous = _configuration;
        _configuration = next;
        if (recoveringCredentials) {
          _credentialReadFailed = false;
          isLoaded = true;
          _initialization = Future.value();
        }
        final scopes = NetworkScope.values
            .where(
              (scope) =>
                  previous.modes[scope] != next.modes[scope] ||
                  previous.unifiedMode != next.unifiedMode ||
                  next.modes[scope] == NetworkMode.custom &&
                      jsonEncode(previous.proxy?.toJson()) !=
                          jsonEncode(next.proxy?.toJson()),
            )
            .toSet();
        for (final scope in scopes) {
          _scopeGenerations[scope] = (_scopeGenerations[scope] ?? 0) + 1;
        }
        _changes.add(NetworkSettingsChange(previous, next, scopes));
        state = NetworkSaveState.applied;
        error = null;
        result.complete();
      } catch (_) {
        state = NetworkSaveState.failed;
        error = '保存失败，仍使用此前已应用的网络设置。请重试。';
        result.completeError(NetworkSettingsException(error!));
      } finally {
        _pending--;
        if (_pending > 0) state = NetworkSaveState.saving;
        notifyListeners();
      }
    });
    return result.future;
  }

  Future<void> setMode(NetworkScope scope, NetworkMode mode) =>
      _submit(() async {
        if (mode == NetworkMode.custom && _configuration.proxy == null) {
          throw const NetworkSettingsException('请先保存自定义代理');
        }
        return _configuration.copyWith(
          modes: {..._configuration.featureModes, scope: mode},
        );
      });

  Future<void> setUnifiedMode(NetworkMode? mode) => _submit(() async {
    if (mode == NetworkMode.custom && _configuration.proxy == null) {
      throw const NetworkSettingsException('请先保存自定义代理');
    }
    return _configuration.copyWith(
      unifiedMode: mode,
      clearUnifiedMode: mode == null,
    );
  });

  Map<String, dynamic> preferencePolicySnapshot() => {
    'unifiedMode': _configuration.unifiedMode?.name,
    'featureModes': {
      for (final entry in _configuration.featureModes.entries)
        entry.key.name: entry.value.name,
    },
  };
  Future<void> flushPreferencePolicyForTrial() => _queue;

  /// Keep proxy addresses, authentication and credentials outside the trial.
  Future<void> applyPreferencePolicyForTrial(Map<String, dynamic>? policy) =>
      _submit(() async {
        final defaults = NetworkConfiguration();
        final modes = policy == null
            ? defaults.featureModes
            : {
                for (final scope in NetworkScope.values)
                  scope: NetworkMode.values.byName(
                    (policy['featureModes'] as Map)[scope.name] as String? ?? scope.defaultMode.name,
                  ),
              };
        final unified = policy?['unifiedMode'] as String?;
        return _configuration.copyWith(
          modes: modes,
          unifiedMode: unified == null
              ? null
              : NetworkMode.values.byName(unified),
          clearUnifiedMode: unified == null,
        );
      });

  Future<void> saveProxy({
    required ProxyProfile profile,
    required String? password,
    NetworkScope? applyTo,
    bool applyGlobally = false,
    bool keepExistingPassword = false,
  }) => _submit(() async {
    profile.validate();
    String? key;
    if (keepExistingPassword) {
      key = _configuration.proxy?.credentialKey;
    } else if (password != null && password.isNotEmpty) {
      key = 'network_proxy_${const Uuid().v4()}';
      await credentials.write(key, password);
      if (await credentials.read(key) != password) {
        throw const NetworkSettingsException('代理密码无法安全保存');
      }
    }
    final nextProfile = ProxyProfile(
      protocol: profile.protocol,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      credentialKey: key,
    );
    return _configuration.copyWith(
      proxy: nextProfile,
      modes: {..._configuration.featureModes, ?applyTo: NetworkMode.custom},
      unifiedMode: applyGlobally ? NetworkMode.custom : null,
    );
  }, replaceCredentials: true);

  Future<RequestNetworkContext> context(
    NetworkScope scope, {
    Uri? source,
    bool cancelOnChange = true,
    NetworkMode? modeOverride,
  }) async {
    await ready;
    if (_configuration.unifiedMode == null &&
        modeOverride == NetworkMode.custom &&
        _configuration.proxy == null) {
      throw const NetworkSettingsException('请先在软件的网络设置中配置自定义代理');
    }
    return RequestNetworkContext(
      scope: scope,
      source: source,
      configuration: _configuration,
      deviceGeneration: deviceGeneration,
      scopeGeneration: _scopeGenerations[scope] ?? 0,
      cancelOnChange: cancelOnChange,
      modeOverride: modeOverride,
    );
  }

  String imageGeneration(NetworkScope scope) =>
      '${scope.name}:${_scopeGenerations[scope] ?? 0}:${_configuration.modes[scope] == NetworkMode.system ? deviceGeneration : 0}:true';

  bool isCurrent(RequestNetworkContext context) =>
      context.scopeGeneration == (_scopeGenerations[context.scope] ?? 0) &&
      (context.mode != NetworkMode.system ||
          context.deviceGeneration == deviceGeneration);

  void deviceNetworkChanged() {
    deviceGeneration++;
    final scopes = NetworkScope.values
        .where((s) => _configuration.modes[s] == NetworkMode.system)
        .toSet();
    _changes.add(
      NetworkSettingsChange(
        _configuration,
        _configuration,
        scopes,
        deviceChanged: true,
      ),
    );
  }
}
