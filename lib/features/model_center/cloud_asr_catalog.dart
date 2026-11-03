import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../services/app_storage_service.dart';
import 'cloud_asr_types.dart';
import 'cloud_asr_parser.dart';
import 'cloud_asr_transport.dart';

class CloudAsrCatalog {
  const CloudAsrCatalog(this.models, {this.fetchedAt, this.remote = false});
  final List<CloudAsrModelInfo> models;
  final DateTime? fetchedAt;
  final bool remote;
  bool get stale =>
      fetchedAt == null ||
      DateTime.now().difference(fetchedAt!) > const Duration(hours: 24);
}

/// No requests at startup or task capture. A settings route explicitly loads
/// its cache and may refresh it without changing the selected model.
class CloudAsrCatalogStore {
  CloudAsrCatalogStore(this.storage, {this.createDio});
  final AppStorageService storage;
  final Dio Function()? createDio;
  Future<File> _file(CloudAsrConnection connection) async {
    final id = sha256
        .convert(
          utf8.encode(
            '${connection.provider.name}:${connection.endpoint}:${connection.apiKey}',
          ),
        )
        .toString();
    return File(
      '${(await storage.featureDirectory('model_jobs')).path}/cloud-models-$id.json',
    );
  }

  Future<CloudAsrCatalog> load(CloudAsrConnection connection) async {
    try {
      final value = await readStorageJson(await _file(connection));
      if (value is Map && value['models'] is List) {
        return CloudAsrCatalog(
          [
            for (final item in value['models'] as List)
              if (item is Map)
                CloudAsrModelInfo.fromJson(Map<String, dynamic>.from(item)),
          ],
          fetchedAt: DateTime.tryParse(value['fetchedAt']?.toString() ?? ''),
          remote: value['remote'] == true,
        );
      }
    } catch (_) {
      /* An invalid metadata cache never disables saved services. */
    }
    return CloudAsrCatalog(builtinCloudAsrModels(connection.provider));
  }

  Future<CloudAsrCatalog> refresh(
    CloudAsrConnection connection,
    CancelToken token,
  ) async {
    final transport = CloudAsrTransport(connection, dio: createDio?.call());
    try {
      final discovered = <String, CloudAsrModelInfo>{};
      void add(String id, List<String> languages) {
        if (id.isEmpty) return;
        final builtin = cloudAsrCapabilities(connection.provider, id);
        final old = discovered[id];
        discovered[id] = CloudAsrModelInfo(
          id: id,
          name: id,
          source: '厂商模型接口',
          capabilities: CloudAsrCapabilities(
            languages: {
              ...?old?.capabilities.languages,
              ...languages
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty && s != 'auto'),
              if (languages.isEmpty) ...builtin.languages,
            }.toList(),
            documented: builtin.documented,
            wordTimestamps: builtin.wordTimestamps,
            automaticLanguage: builtin.automaticLanguage,
            incompatibleOptions: builtin.incompatibleOptions,
            minMilliseconds: builtin.minMilliseconds,
            speakers: builtin.speakers,
            characters: builtin.characters,
            maxHotwords: builtin.maxHotwords,
            maxBytes: builtin.maxBytes,
            maxSeconds: builtin.maxSeconds,
          ),
        );
      }

      List<String> languages(dynamic value) => value is List
          ? [
              for (final item in value)
                if (item is String)
                  item
                else if (item is Map &&
                    (item['code'] ?? item['language_id']) is String)
                  (item['code'] ?? item['language_id']) as String,
            ]
          : [];
      final provider = connection.provider;
      if (provider == CloudAsrProvider.assemblyai) {
        // AssemblyAI does not publish an authenticated STT model enumeration.
        // Never scrape documentation or run a billable probe to invent one.
      } else if (provider == CloudAsrProvider.gemini) {
        String? next;
        final seen = <String>{};
        do {
          final data = cloudObject(
            (await transport.request(
              'GET',
              '/v1beta/models',
              token,
              query: {'pageSize': 200, 'pageToken': ?next},
            )).data,
          );
          if (data['models'] is! List) {
            throw const CloudAsrException('厂商模型列表结构已改变，保留原列表');
          }
          for (final item in data['models'] as List) {
            if (item is! Map) continue;
            final id = (item['name']?.toString() ?? '').replaceFirst(
              RegExp(r'^models/'),
              '',
            );
            if (id.contains('transcribe') &&
                !id.contains('live') &&
                !id.contains('realtime')) {
              add(id, languages(item['languages']));
            }
          }
          next = data['nextPageToken'] as String?;
          if (next != null && (!seen.add(next) || seen.length > 50)) {
            throw const CloudAsrException('模型列表分页异常，保留已有列表');
          }
        } while (next != null && next.isNotEmpty);
      } else {
        final response = (await transport.request(
          'GET',
          '/v1/models',
          token,
        )).data;
        final dynamic entries = switch (provider) {
          CloudAsrProvider.soniox => cloudObject(response)['models'],
          CloudAsrProvider.deepgram => cloudObject(response)['stt'],
          _ => response,
        };
        if (entries is! List) {
          throw const CloudAsrException('厂商模型列表结构已改变，保留原列表');
        }
        for (final item in entries) {
          if (item is! Map) continue;
          final id =
              (item['canonical_name'] ??
                      item['id'] ??
                      item['model_id'] ??
                      item['name'])
                  ?.toString() ??
              '';
          final accepted = switch (provider) {
            CloudAsrProvider.soniox => item['transcription_mode'] == 'async',
            CloudAsrProvider.deepgram => item['batch'] == true,
            CloudAsrProvider.elevenlabs =>
              id.startsWith('scribe_') && !id.contains('realtime'),
            _ => false,
          };
          if (accepted) add(id, languages(item['languages']));
        }
      }
      final previous = await load(connection);
      final merged = <String, CloudAsrModelInfo>{
        for (final m in builtinCloudAsrModels(provider)) m.id: m,
        for (final m in previous.models) m.id: m,
        ...discovered,
      };
      final result = CloudAsrCatalog(
        merged.values.toList(),
        fetchedAt: DateTime.now().toUtc(),
        remote: discovered.isNotEmpty,
      );
      await writeStorageJson(await _file(connection), {
        'version': 1,
        'fetchedAt': result.fetchedAt!.toIso8601String(),
        'remote': result.remote,
        'models': result.models.map((m) => m.toJson()).toList(),
      });
      return result;
    } finally {
      transport.close();
    }
  }
}
