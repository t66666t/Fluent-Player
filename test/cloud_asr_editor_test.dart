import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/cloud_asr_catalog.dart';
import 'package:video_player_app/features/model_center/cloud_asr_editor.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

import 'cloud_asr_test_support.dart';

class _Catalog extends CloudAsrCatalogStore {
  _Catalog(super.storage, this.provider);
  final CloudAsrProvider provider;
  int queries = 0;
  bool fail = false;
  @override
  Future<CloudAsrCatalog> load(CloudAsrConnection connection) async =>
      CloudAsrCatalog(
        builtinCloudAsrModels(provider),
        fetchedAt: DateTime.now(),
      );
  @override
  Future<CloudAsrCatalog> refresh(
    CloudAsrConnection connection,
    CancelToken token,
  ) async {
    queries++;
    if (fail) throw const CloudAsrException('metadata request failed');
    return CloudAsrCatalog(
      [
        ...builtinCloudAsrModels(provider),
        const CloudAsrModelInfo(
          id: 'future-model',
          capabilities: CloudAsrCapabilities(),
        ),
      ],
      fetchedAt: DateTime.now(),
      remote: true,
    );
  }
}

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
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
  late Directory root;
  late AppStorageService storage;
  late ModelCenterService center;
  late _Secrets secrets;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('cloud-asr-editor-');
    storage = await cloudTestStorage(root);
    secrets = _Secrets();
    center = ModelCenterService(storage: storage, secrets: secrets)
      ..loaded = true;
  });
  tearDown(() async {
    center.dispose();
    await root.delete(recursive: true);
  });
  Finder field(String label) => find.widgetWithText(TextFormField, label);

  for (final width in [360.0, 960.0]) {
    testWidgets(
      'cloud setup at $width keeps API key private, model stable, and save visible above keyboard',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final catalog = _Catalog(storage, CloudAsrProvider.elevenlabs);
        (ModelServiceProfile, String)? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    saved = await Navigator.of(context)
                        .push<(ModelServiceProfile, String)>(
                          MaterialPageRoute(
                            builder: (_) => CloudAsrEditor(
                              center: center,
                              provider: CloudAsrProvider.elevenlabs,
                              catalog: catalog,
                            ),
                          ),
                        );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(catalog.queries, 0);
        expect(find.text('scribe_v2'), findsOneWidget);
        expect(find.text('字符级时间轴'), findsNothing);
        await tester.ensureVisible(find.text('高级设置'));
        await tester.tap(find.text('高级设置'));
        await tester.pumpAndSettle();
        expect(find.text('字符级时间轴'), findsOneWidget);
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, '区分说话人'),
              )
              .value,
          false,
        );
        await tester.tap(find.text('高级设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(field('API Key'));
        await tester.enterText(field('API Key'), 'private-secret');
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final keyField = tester.widget<TextFormField>(field('API Key'));
        // TextFormField builds an obscured input; normal configuration contains no key.
        expect(
          find.descendant(
            of: field('API Key'),
            matching: find.byType(EditableText),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: field('API Key'),
                  matching: find.byType(EditableText),
                ),
              )
              .obscureText,
          true,
        );
        expect(keyField.controller!.text, 'private-secret');
        expect(
          catalog.queries,
          0,
          reason: 'Fresh metadata cache avoids a new request',
        );
        await tester.ensureVisible(find.text('刷新模型列表'));
        await tester.tap(find.text('刷新模型列表'));
        await tester.pumpAndSettle();
        expect(catalog.queries, 1);
        expect(find.text('scribe_v2'), findsOneWidget);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        final save = find.byKey(const ValueKey('cloud-asr-save'));
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(460));
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        expect(saved!.$1.model, 'scribe_v2');
        expect(saved!.$1.language, 'auto');
        expect(saved!.$1.cloudOptions!.hotwords, isEmpty);
        expect(saved!.$1.cloudOptions!.diarize, false);
        expect(saved!.$2, 'private-secret');
        final previous = center.asrProfileId;
        await tester.runAsync(
          () => center.saveProfile(saved!.$1, secret: saved!.$2),
        );
        expect(
          center.asrProfileId,
          previous,
          reason: 'Saving a service never silently changes the default',
        );
        expect(secrets.values.values, contains('private-secret'));
        final config = await tester.runAsync(
          () async =>
              (await storage.dataRecord('model_center.json')).readAsString(),
        );
        expect(config, isNot(contains('private-secret')));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'advanced manual model IDs remain usable; unknown features are hidden; list failure keeps selection',
    (tester) async {
      final catalog = _Catalog(storage, CloudAsrProvider.gemini)..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAsrEditor(
            center: center,
            provider: CloudAsrProvider.gemini,
            catalog: catalog,
            secret: 'private-secret',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('字符级时间轴'), findsNothing);
      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(field('热词／术语（每行一条）'), findsNothing);
      await tester.enterText(field('模型 ID'), 'my-new-transcriber');
      await tester.pumpAndSettle();
      expect(find.textContaining('新模型能力尚未确认'), findsOneWidget);
      expect(find.text('区分说话人'), findsNothing);
      await tester.ensureVisible(find.text('刷新模型列表'));
      await tester.tap(find.text('刷新模型列表'));
      await tester.pumpAndSettle();
      expect(find.textContaining('模型列表更新失败'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('模型 ID')).controller!.text,
        'my-new-transcriber',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
