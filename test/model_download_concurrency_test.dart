import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _GatedDownloads implements HttpClientAdapter {
  final started = <String>[];
  final gates = <String, Completer<void>>{};
  final cancelled = <String>{};
  int active = 0, maximum = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final id = options.uri.pathSegments.last;
    started.add(id);
    active++;
    if (active > maximum) maximum = active;
    final gate = gates.putIfAbsent(id, Completer<void>.new);
    Stream<Uint8List> stream() async* {
      try {
        yield Uint8List(128);
        await Future.any([
          gate.future,
          if (cancel != null)
            cancel.then((_) {
              cancelled.add(id);
            }),
        ]);
        if (!cancelled.contains(id)) yield Uint8List(128);
      } finally {
        active--;
      }
    }

    return ResponseBody(
      stream(),
      200,
      headers: {
        'etag': ['"stable"'],
        'content-length': ['256'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _until(
  bool Function() condition, [
  String Function()? details,
]) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('download did not settle: ${details?.call()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'three models start together, pause independently, and persist on shutdown',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('model-concurrency-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory('${root.path}/support'),
          documents: Directory('${root.path}/documents'),
          defaultData: Directory('${root.path}/data'),
          executable: Directory('${root.path}/executable'),
        ),
      );
      final catalog = [
        for (var i = 0; i < 5; i++)
          ModelArtifact(
            id: 'model$i',
            name: 'Model $i',
            engine: 'hy-mt',
            revision: '0123456789abcdef',
            parameters: '1B',
            quantization: 'Q4',
            languages: const ['en'],
            description: '',
            license: 'MIT',
            homepage: 'https://example.test',
            purpose: ModelPurpose.translation,
            suggestedRamGb: 2,
            memoryNote: '',
            files: [
              ModelFile(
                name: 'model.gguf',
                bytes: 256,
                sha256: 'a' * 64,
                sources: {'official': 'https://example.test/model$i'},
              ),
            ],
          ),
      ];
      final adapter = _GatedDownloads();
      final service = ModelCenterService(
        storage: storage,
        catalogLoader: () async => catalog,
        createDio: () => Dio()..httpClientAdapter = adapter,
      );
      addTearDown(() async {
        for (final gate in adapter.gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await service.shutdown();
        await root.delete(recursive: true);
      });
      await service.enqueue('model0');
      await _until(
        () => adapter.started.length == 1,
        () =>
            '${adapter.started} ${service.downloads.values.map((s) => s.toJson())}',
      );
      for (var i = 1; i < 5; i++) {
        await service.enqueue('model$i');
      }
      await _until(
        () => adapter.started.length == 3,
        () =>
            '${adapter.started} ${service.downloads.values.map((s) => s.toJson())}',
      );
      expect(adapter.started.toSet(), {'model0', 'model1', 'model2'});
      expect(service.downloads['model3']!.phase, ModelDownloadPhase.queued);
      await service.enqueue('model1');
      expect(adapter.started.length, 3);
      await expectLater(service.remove('model1'), throwsStateError);
      await expectLater(service.verify('model2'), throwsStateError);
      await service.pause('model0');
      await _until(
        () => adapter.started.length == 4,
        () =>
            '${adapter.started} ${adapter.cancelled} ${service.downloads.values.map((s) => s.toJson())}',
      );
      expect(adapter.cancelled, {'model0'});
      expect(service.downloads['model0']!.phase, ModelDownloadPhase.paused);
      adapter.gates['model1']!.complete();
      await _until(
        () => adapter.started.length == 5,
        () =>
            '${adapter.started} ${service.downloads.values.map((s) => s.toJson())}',
      );
      expect(service.installed('model1'), isTrue);
      expect(adapter.maximum, 3);
      await _until(
        () => [
          'model2',
          'model3',
          'model4',
        ].every((id) => service.downloads[id]!.received == 128),
      );
      await service.shutdown();
      expect(adapter.active, 0);
      final saved =
          await readStorageJson(await storage.dataRecord('model_center.json'))
              as Map;
      final states = {
        for (final state in saved['downloads'] as List)
          state['artifactId']: state['phase'],
      };
      for (final id in ['model2', 'model3', 'model4']) {
        expect(states[id], 'queued');
      }
      final restoredAdapter = _GatedDownloads();
      final restored = ModelCenterService(
        storage: storage,
        catalogLoader: () async => catalog,
        createDio: () => Dio()..httpClientAdapter = restoredAdapter,
      );
      await restored.initialize();
      await restored.pauseAll();
      expect(restored.downloads['model0']!.phase, ModelDownloadPhase.paused);
      expect(restored.installed('model1'), isTrue);
      for (final id in ['model2', 'model3', 'model4']) {
        expect(restored.downloads[id]!.phase, ModelDownloadPhase.paused);
        final partial = File(
          '${(await restored.modelDirectory(restored.artifact(id)!)).path}/model.gguf.part',
        );
        expect(await partial.length(), 128);
      }
      await restored.pauseAll();
    },
  );
}
