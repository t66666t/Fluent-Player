import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/offline_model_directory_import.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/widgets/ocr_models_pane.dart';

const _channel = MethodChannel(
  'com.example.video_player_app/model_directory_import',
);

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

ModelArtifact _artifact(
  String id,
  List<String> names, {
  ModelPurpose purpose = ModelPurpose.transcription,
}) => ModelArtifact(
  id: id,
  name: id,
  engine: purpose == ModelPurpose.ocr ? 'ppocr' : 'sensevoice',
  revision: 'a' * 40,
  parameters: 'audit',
  quantization: 'audit',
  languages: const ['zh'],
  description: 'audit',
  license: 'audit',
  homepage: 'https://example.invalid',
  purpose: purpose,
  files: [
    for (final name in names)
      ModelFile(
        name: name,
        bytes: 3,
        sha256: sha256.convert([1, 2, 3]).toString(),
        sources: const {},
      ),
  ],
  suggestedRamGb: 1,
  memoryNote: 'audit',
);

class _Ocr extends OcrModelManager {
  _Ocr({required super.center, required super.rootOverride});
  static const model = OcrModelPreset(
    id: 'audit-ocr',
    name: 'Audit OCR',
    tier: 'small',
    detection: 'audit-det',
    recognition: 'audit-rec',
    groups: ['chinese'],
    languages: ['zh-Hans'],
    parameters: 'audit',
    description: 'audit',
    suggestedRamGb: 1,
    license: 'audit',
  );
  @override
  Future<List<OcrModelPreset>> presets() async => [model];
}

class _Center extends ModelCenterService {
  _Center({required super.storage, required super.catalogLoader})
    : super(secrets: _Secrets());
  bool widgetOnlyImport = false;

  @override
  Future<void> save() => widgetOnlyImport ? Future.value() : super.save();

  @override
  Future<void> importFiles(String id, Directory source) async {
    if (!widgetOnlyImport) {
      return super.importFiles(id, source);
    }
    downloads[id] = ModelDownload(
      artifactId: id,
      phase: ModelDownloadPhase.installed,
    );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory stage;
  late _Center center;
  late SubtitleTranslateSettings translation;
  late List<MethodCall> calls;
  late OfflineModelDirectoryImporter importer;
  final asr = _artifact('audit-asr', ['model.int8.onnx', 'tokens.txt']);
  final det = _artifact('audit-det', [
    'inference.onnx',
    'inference.yml',
  ], purpose: ModelPurpose.ocr);
  final rec = _artifact('audit-rec', [
    'inference.onnx',
    'inference.yml',
  ], purpose: ModelPurpose.ocr);

  Future<void> writeStage(Iterable<OfflineModelImportFile> files) async {
    for (final file in files) {
      final target = File('${stage.path}/${file.targetPath}');
      await target.parent.create(recursive: true);
      await target.writeAsBytes([1, 2, 3]);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('offline-model-import-');
    stage = await Directory('${root.path}/native-cache').create();
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory('${root.path}/support'),
        documents: Directory('${root.path}/documents'),
        defaultData: Directory('${root.path}/data'),
        executable: Directory('${root.path}/bin'),
      ),
    );
    await storage.initialize();
    center = _Center(
      storage: storage,
      catalogLoader: () async => [asr, det, rec],
    );
    await center.initialize();
    translation = SubtitleTranslateSettings(modelCenter: center);
    await translation.ensureLoaded();
    calls = [];
    importer = OfflineModelDirectoryImporter(
      isAndroid: true,
      pickLocalDirectory: (_) async =>
          throw StateError('Android must not use a raw directory'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'selectAndStage')
            return {'directoryPath': stage.path, 'token': 'audit-owned-token'};
          if (call.method == 'cleanup') {
            expect(call.arguments, {'token': 'audit-owned-token'});
            if (await stage.exists()) {
              await stage.delete(recursive: true);
            }
          }
          return null;
        });
  });
  tearDown(() async {
    translation.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await center.shutdown();
    center.dispose();
    await root.delete(recursive: true);
  });

  test(
    'Android tree staging installs through real ModelCenter and releases only the token cache',
    () async {
      final files = OfflineModelImportFile.forArtifact(asr);
      await writeStage(files);
      final original = await File(
        '${root.path}/source-original.onnx',
      ).writeAsBytes([9, 8, 7]);
      expect(
        await importer.importFiles(
          dialogTitle: 'audit',
          files: files,
          install: (dir) => center.importFiles(asr.id, dir),
        ),
        isTrue,
      );
      expect(calls.map((call) => call.method), ['selectAndStage', 'cleanup']);
      final message = calls.first.arguments as Map;
      expect(message['files'], [
        {
          'targetPath': 'model.int8.onnx',
          'relativePaths': ['model.int8.onnx'],
          'expectedBytes': 3,
        },
        {
          'targetPath': 'tokens.txt',
          'relativePaths': ['tokens.txt'],
          'expectedBytes': 3,
        },
      ]);
      expect(center.installed(asr.id), isTrue);
      expect(
        await File(
          '${(await center.modelDirectory(asr)).path}/model.int8.onnx',
        ).readAsBytes(),
        [1, 2, 3],
      );
      expect(await stage.exists(), isFalse);
      expect(await original.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'OCR nested staging keeps root aliases and delegates both components to real manager',
    () async {
      final manager = _Ocr(center: center, rootOverride: root);
      final files = [
        for (final model in [det, rec])
          ...OfflineModelImportFile.forArtifact(
            model,
            componentDirectory: model.id,
          ),
      ];
      await writeStage(files);
      await importer.importFiles(
        dialogTitle: 'OCR',
        files: files,
        install: (dir) => manager.importFiles(_Ocr.model, dir),
      );
      expect(center.installed(det.id), isTrue);
      expect(center.installed(rec.id), isTrue);
      expect(
        (calls.first.arguments as Map)['files'],
        contains(
          equals({
            'targetPath': 'audit-rec/inference.yml',
            'relativePaths': ['audit-rec/inference.yml', 'inference.yml'],
            'expectedBytes': 3,
          }),
        ),
      );
      expect(await stage.exists(), isFalse);
    },
  );

  test(
    'every real legacy OCR filename and both source layouts survive manifest construction',
    () async {
      final catalog = await loadModelCatalog(includeRetired: true);
      final legacy = catalog
          .where((model) => model.engine == 'ppocr-legacy')
          .toList();
      expect(legacy, isNotEmpty);
      for (final model in legacy) {
        final files = OfflineModelImportFile.forArtifact(
          model,
          componentDirectory: model.id,
        );
        for (var i = 0; i < model.files.length; i++) {
          expect(files[i].relativePaths, [
            '${model.id}/${model.files[i].name}',
            model.files[i].name,
          ]);
          expect(files[i].expectedBytes, model.files[i].bytes);
        }
      }
    },
  );

  test('cancel does not install or attempt unknown-token cleanup', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null;
        });
    var installed = false;
    expect(
      await importer.importFiles(
        dialogTitle: 'audit',
        files: OfflineModelImportFile.forArtifact(asr),
        install: (_) async {
          installed = true;
        },
      ),
      isFalse,
    );
    expect(installed, isFalse);
    expect(calls.map((call) => call.method), ['selectAndStage']);
  });

  test(
    'native copy refusal is surfaced without raw path fallback or installation',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            throw PlatformException(
              code: 'MODEL_IMPORT',
              message: 'provider stream failed',
            );
          });
      await expectLater(
        importer.importFiles(
          dialogTitle: 'audit',
          files: OfflineModelImportFile.forArtifact(asr),
          install: (_) async => fail('must not install'),
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            'provider stream failed',
          ),
        ),
      );
      expect(calls, hasLength(1));
    },
  );

  test(
    'install rejection still cleans staged files and leaves previous installed bytes',
    () async {
      final files = OfflineModelImportFile.forArtifact(asr);
      await writeStage(files);
      await center.importFiles(asr.id, stage);
      await File('${stage.path}/tokens.txt').writeAsBytes([1]);
      await expectLater(
        importer.importFiles(
          dialogTitle: 'audit',
          files: files,
          install: (dir) => center.importFiles(asr.id, dir),
        ),
        throwsStateError,
      );
      expect(calls.last.method, 'cleanup');
      expect(await stage.exists(), isFalse);
      expect(
        await File(
          '${(await center.modelDirectory(asr)).path}/tokens.txt',
        ).readAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test(
    'bad host directory response with valid token is also cleaned',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return call.method == 'selectAndStage'
                ? {
                    'directoryPath': 'content://not-a-raw-directory',
                    'token': 'audit-owned-token',
                  }
                : null;
          });
      await expectLater(
        importer.importFiles(
          dialogTitle: 'audit',
          files: OfflineModelImportFile.forArtifact(asr),
          install: (_) async => fail('invalid path'),
        ),
        throwsFormatException,
      );
      expect(calls.last.method, 'cleanup');
    },
  );

  test(
    'non-Android original directory and cancellation keep the existing picker behavior',
    () async {
      var title = '';
      final local = OfflineModelDirectoryImporter(
        isAndroid: false,
        pickLocalDirectory: (value) async {
          title = value;
          return stage.path;
        },
      );
      await writeStage(OfflineModelImportFile.forArtifact(asr));
      await local.importFiles(
        dialogTitle: 'existing local picker',
        files: OfflineModelImportFile.forArtifact(asr),
        install: (dir) => center.importFiles(asr.id, dir),
      );
      expect(title, 'existing local picker');
      expect(await stage.exists(), isTrue);
      expect(calls, isEmpty);
      final canceled = OfflineModelDirectoryImporter(
        isAndroid: false,
        pickLocalDirectory: (_) async => null,
      );
      expect(
        await canceled.importFiles(
          dialogTitle: 'cancel',
          files: OfflineModelImportFile.forArtifact(asr),
          install: (_) async => fail('canceled'),
        ),
        isFalse,
      );
    },
  );

  for (final unsafe in [
    '/absolute',
    '../escape',
    'a/../b',
    r'C:\outside',
    r'a\b',
    'a//b',
    'content://provider/path',
  ]) {
    test(
      'reject unsafe requested relative path before native picker: $unsafe',
      () async {
        await expectLater(
          importer.importFiles(
            dialogTitle: 'unsafe',
            files: [
              OfflineModelImportFile(
                targetPath: 'ok',
                relativePaths: [unsafe],
                expectedBytes: 3,
              ),
            ],
            install: (_) async => fail('unsafe'),
          ),
          throwsFormatException,
        );
        expect(calls, isEmpty);
      },
    );
  }
  test('reject unbounded manifests before opening picker', () async {
    final tooMany = [
      for (var i = 0; i < 129; i++)
        OfflineModelImportFile(
          targetPath: 'file$i',
          relativePaths: ['file$i'],
          expectedBytes: 3,
        ),
    ];
    await expectLater(
      importer.importFiles(
        dialogTitle: 'too many',
        files: tooMany,
        install: (_) async => fail('unbounded'),
      ),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });

  Future<void> waitForCleanup(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (calls.any((c) => c.method == 'cleanup')) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(calls.last.method, 'cleanup');
  }

  void useWidgetImportBoundary() {
    // Real disk installation/cleanup is covered above. These two tests isolate
    // the actual buttons and channel handoff from FakeAsync filesystem waits.
    center.widgetOnlyImport = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'selectAndStage'
              ? {'directoryPath': stage.path, 'token': 'audit-owned-token'}
              : null;
        });
  }

  testWidgets(
    'formal model detail offline-import button uses staged Android directory',
    (tester) async {
      useWidgetImportBoundary();
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => writeStage(OfflineModelImportFile.forArtifact(asr)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ModelCenterScreen(
            service: center,
            translateSettings: translation,
            initialTab: 1,
            deviceInfo: const ModelDeviceInfo(processors: 4),
            directoryImporter: importer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('model-library-${asr.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('模型工具'));
      await tester.tap(find.text('模型工具'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('离线导入'));
      await tester.tap(find.text('离线导入'));
      await waitForCleanup(tester);
      expect(center.installed(asr.id), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'formal OCR offline-import button stages component/root candidates then installs',
    (tester) async {
      useWidgetImportBoundary();
      final manager = _Ocr(center: center, rootOverride: root);
      await tester.runAsync(manager.initialize);
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => writeStage([
          for (final model in [det, rec])
            ...OfflineModelImportFile.forArtifact(
              model,
              componentDirectory: model.id,
            ),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OcrModelsPane(
              manager: manager,
              language: OcrSubtitleLanguage.chinese,
              canChoose: true,
              onChoose: (_) {},
              directoryImporter: importer,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('离线导入'));
      await tester.tap(find.text('离线导入'));
      await waitForCleanup(tester);
      expect(center.installed(det.id), isTrue);
      expect(center.installed(rec.id), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
