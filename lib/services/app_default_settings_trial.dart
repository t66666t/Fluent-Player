import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models/recommended_app_defaults.dart';
import '../features/media_cache/media_cache_service.dart';
import '../features/podcasts/podcast_store.dart';
import '../features/youtube_download/models/youtube_download_models.dart';
import '../features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'app_storage_service.dart';
import 'network/network_settings_service.dart';

/// Bind only services that already exist. Applying defaults must never open a
/// downloader, load a model, sign in, start a queue or create a device identity.
class DefaultTrialRuntimeBinding {
  const DefaultTrialRuntimeBinding({
    required this.flush,
    required this.reload,
    this.patchRecord,
  });
  final Future<void> Function() flush;
  final Future<void> Function() reload;
  final Future<bool> Function(Map<String, dynamic> fields, bool restoring)?
  patchRecord;
}

class DefaultTrialRuntime {
  static final bindings = <String, DefaultTrialRuntimeBinding>{};
  static final revision = ValueNotifier<int>(0);
  static Future<void> flush() async {
    for (final binding in List.of(bindings.values)) {
      await binding.flush();
    }
  }

  static Future<void> reload() async {
    for (final binding in List.of(bindings.values)) {
      await binding.reload();
    }
    revision.value++;
  }
}

/// Snapshots only selected JSON fields, including the distinction between an
/// absent field and an explicit null. Credentials and task data stay outside.
abstract final class TrialFieldMask {
  static Map<String, dynamic> capture(
    Map<String, dynamic> record,
    Set<String> keys,
  ) => {
    'present': [
      for (final key in keys)
        if (record.containsKey(key)) key,
    ],
    'values': {
      for (final key in keys)
        if (record.containsKey(key)) key: record[key],
    },
  };
  static Map<String, dynamic> restore(
    Map<String, dynamic> current,
    Map<String, dynamic> snapshot,
    Set<String> keys,
  ) {
    final present = (snapshot['present'] as List).cast<String>().toSet();
    final values = Map<String, dynamic>.from(snapshot['values'] as Map);
    if (!keys.containsAll(present) ||
        !present.containsAll(values.keys) ||
        present.length != values.length) {
      throw const FormatException('设置字段备份不完整，已保留原备份');
    }
    return Map.of(current)
      ..removeWhere((key, _) => keys.contains(key) && !present.contains(key))
      ..addAll(values);
  }

  static Map<String, dynamic> apply(
    Map<String, dynamic> current,
    Map<String, dynamic> changes,
  ) {
    final result = Map<String, dynamic>.of(current);
    for (final entry in changes.entries) {
      if (entry.value == null) {
        result.remove(entry.key);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}

abstract interface class DefaultTrialFeatureStore {
  Future<void> flush();
  Future<Map<String, dynamic>> capture();
  Future<void> apply(DefaultSettingsDevice device);
  Future<void> restore(Map<String, dynamic> snapshot);
  Future<void> reloadRuntime();
}

class FileDefaultTrialFeatureStore implements DefaultTrialFeatureStore {
  FileDefaultTrialFeatureStore({
    Future<Map<String, File>> Function()? files,
    NetworkSettingsService? network,
    Future<DownloadSessionConfig?> Function()? readNativeSession,
    Future<bool> Function(DownloadSessionConfig)? writeNativeSession,
  }) : _files = files ?? _defaultFiles,
       network = network ?? NetworkSettingsService.instance,
       _readNativeSession =
           readNativeSession ?? YtDlpNativeBridge().loadYoutubeSessionConfig,
       _writeNativeSession =
           writeNativeSession ?? YtDlpNativeBridge().saveYoutubeSessionConfig;
  final Future<Map<String, File>> Function() _files;
  final NetworkSettingsService network;
  final Future<DownloadSessionConfig?> Function() _readNativeSession;
  final Future<bool> Function(DownloadSessionConfig) _writeNativeSession;
  static const recordFields = <String, Set<String>>{
    'model': RecommendedAppDefaults.modelFields,
    'cache': {'preferences'},
  };
  static Future<Map<String, File>> _defaultFiles() async => {
    'model': await AppStorageService.instance.dataRecord('model_center.json'),
    'cache':
        MediaCacheService.instance?.journal ??
        await AppStorageService.instance.dataRecord(
          MediaCacheService.journalName,
        ),
    'podcasts': File(
      p.join(
        (await AppStorageService.instance.featureDirectory(
          'podcasts',
          marker: 'podcasts.sqlite',
        )).path,
        'podcasts.sqlite',
      ),
    ),
  };
  @override
  Future<void> flush() async {
    await DefaultTrialRuntime.flush();
    await network.ready;
    await network.flushPreferencePolicyForTrial();
  }

  @override
  Future<void> reloadRuntime() => DefaultTrialRuntime.reload();

  Future<void> _patchRecord(
    String name,
    File file,
    Map<String, dynamic> fields,
    Set<String> keys,
    bool restoring,
  ) async {
    // Loaded owners serialize their own journal and update in-memory fields
    // before new progress snapshots can be queued. This avoids racing an
    // active model/cache download with an external read-modify-write.
    final patch = DefaultTrialRuntime.bindings[name]?.patchRecord;
    if (patch != null && await patch(fields, restoring)) return;
    await compute(_patchTrialRecord, (file.path, fields, keys, restoring));
  }

  static Map<String, dynamic> _podcastRead(File file) {
    if (!file.existsSync()) return {};
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        'SELECT payload FROM records WHERE kind=? AND id=?',
        ['settings', 'global'],
      );
      return rows.isEmpty
          ? {}
          : Map<String, dynamic>.from(
              jsonDecode(rows.first['payload'] as String) as Map,
            );
    } finally {
      db.dispose();
    }
  }

  static void _podcastWrite(File file, Map<String, dynamic> value) {
    final store = PodcastStore.open(file.path);
    try {
      store.write('settings', 'global', value);
      if (jsonEncode(store.read('settings', 'global')) != jsonEncode(value)) {
        throw StateError('播客设置校验失败');
      }
    } finally {
      store.close();
    }
  }

  @override
  Future<Map<String, dynamic>> capture() async {
    await flush();
    await network.ready;
    final files = await _files();
    // Legacy installations may keep the only session configuration in the
    // native backend. Back up its generic fields without copying credentials.
    final native = await _readNativeSession();
    return {
      'version': 1,
      'records': {
        for (final entry in recordFields.entries)
          entry.key: {
            'path': files[entry.key]!.absolute.path,
            'fields': await compute(_captureTrialRecord, (
              files[entry.key]!.path,
              entry.value,
            )),
          },
        'podcasts': {
          'path': files['podcasts']!.absolute.path,
          'fields': TrialFieldMask.capture(
            _podcastRead(files['podcasts']!),
            RecommendedAppDefaults.podcastFields,
          ),
        },
      },
      'network': network.preferencePolicySnapshot(),
      'nativeSession': TrialFieldMask.capture(
        (native ?? DownloadSessionConfig.defaults()).toJson(),
        RecommendedAppDefaults.sessionFields,
      ),
    };
  }

  @override
  Future<void> apply(DefaultSettingsDevice device) async {
    await flush();
    final files = await _files();
    await _patchRecord(
      'model',
      files['model']!,
      RecommendedAppDefaults.modelValues(device),
      RecommendedAppDefaults.modelFields,
      false,
    );
    await _patchRecord(
      'cache',
      files['cache']!,
      <String, dynamic>{
        'preferences': RecommendedAppDefaults.cacheValues(device),
      },
      const <String>{'preferences'},
      false,
    );
    _podcastWrite(
      files['podcasts']!,
      TrialFieldMask.apply(
        _podcastRead(files['podcasts']!),
        RecommendedAppDefaults.podcastValues(device),
      ),
    );
    await network.applyPreferencePolicyForTrial(null);
  }

  @override
  Future<void> restore(Map<String, dynamic> snapshot) async {
    if (snapshot['version'] != 1 ||
        snapshot['records'] is! Map ||
        snapshot['network'] is! Map) {
      throw const FormatException('功能设置备份无法读取，已保留原备份');
    }
    await flush();
    final records = Map<String, dynamic>.from(snapshot['records'] as Map);
    if (records.length != 3 ||
        !records.keys.toSet().containsAll({'model', 'cache', 'podcasts'})) {
      throw const FormatException('功能设置备份不完整，已保留原备份');
    }
    for (final entry in recordFields.entries) {
      final record = records[entry.key] as Map;
      final file = File(record['path'] as String);
      await _patchRecord(
        entry.key,
        file,
        Map<String, dynamic>.from(record['fields'] as Map),
        entry.value,
        true,
      );
    }
    final podcast = records['podcasts'] as Map;
    final file = File(podcast['path'] as String);
    _podcastWrite(
      file,
      TrialFieldMask.restore(
        _podcastRead(file),
        Map<String, dynamic>.from(podcast['fields'] as Map),
        RecommendedAppDefaults.podcastFields,
      ),
    );
    await network.applyPreferencePolicyForTrial(
      Map<String, dynamic>.from(snapshot['network'] as Map),
    );
    if (snapshot['nativeSession'] case final Map original) {
      final current = await _readNativeSession();
      if (current != null) {
        final restored = DownloadSessionConfig.fromJson(
          TrialFieldMask.restore(
            current.toJson(),
            Map<String, dynamic>.from(original),
            RecommendedAppDefaults.sessionFields,
          ),
        );
        if (!await _writeNativeSession(restored)) {
          throw StateError('下载器原设置恢复失败，已保留备份，可再次恢复');
        }
        final saved = await _readNativeSession();
        if (saved == null ||
            jsonEncode(
                  TrialFieldMask.capture(
                    saved.toJson(),
                    RecommendedAppDefaults.sessionFields,
                  ),
                ) !=
                jsonEncode(
                  TrialFieldMask.capture(
                    restored.toJson(),
                    RecommendedAppDefaults.sessionFields,
                  ),
                )) {
          throw StateError('下载器原设置校验失败，已保留备份');
        }
      }
    }
  }
}

Map<String, dynamic> _readTrialRecord(String path) {
  var found = false;
  for (final candidate in [File(path), File('$path.bak')]) {
    if (!candidate.existsSync()) continue;
    found = true;
    try {
      final raw = jsonDecode(candidate.readAsStringSync());
      if (raw is! Map) throw const FormatException('功能配置格式无法识别');
      if (raw['version'] != null && raw['version'] != 1) {
        throw UnsupportedError('功能配置来自更新版本，已保留原文件');
      }
      return Map<String, dynamic>.from(raw);
    } on FormatException {
      /* Try the last complete generation. */
    }
  }
  if (found) throw const FormatException('功能配置与备份无法读取');
  return {};
}

Map<String, dynamic> _captureTrialRecord((String, Set<String>) request) =>
    TrialFieldMask.capture(_readTrialRecord(request.$1), request.$2);

void _patchTrialRecord(
  (String, Map<String, dynamic>, Set<String>, bool) request,
) {
  final (path, fields, keys, restoring) = request;
  final current = _readTrialRecord(path);
  final value = restoring
      ? TrialFieldMask.restore(current, fields, keys)
      : TrialFieldMask.apply(current, fields);
  value.putIfAbsent('version', () => 1);
  final file = File(path);
  file.parent.createSync(recursive: true);
  final temp = File('$path.default-trial.tmp');
  try {
    temp.writeAsStringSync(jsonEncode(value), flush: true);
    temp.renameSync(path);
    final saved = TrialFieldMask.capture(_readTrialRecord(path), keys);
    if (jsonEncode(saved) != jsonEncode(TrialFieldMask.capture(value, keys))) {
      throw StateError('功能配置写入校验失败');
    }
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}
