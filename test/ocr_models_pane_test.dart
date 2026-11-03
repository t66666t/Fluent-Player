import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/widgets/ocr_models_pane.dart';

class _Center extends ModelCenterService {
  _Center({required super.storage}) : super(secrets: _Secrets());
  final enqueued = <String>[];
  @override
  Future<void> enqueue(String id) async {
    enqueued.add(id);
    downloads[id] = ModelDownload(
      artifactId: id,
      phase: ModelDownloadPhase.paused,
      message: '已保存下载进度',
    );
    notifyListeners();
  }
}

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('Roboto')
      ..addFont(
        File(
          'assets/fonts/NotoSansCJKsc-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await loader.load();
  });
  late Directory root;
  late _Center center;
  late OcrModelManager manager;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ocr-model-ui-');
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
    center = _Center(storage: storage);
    manager = OcrModelManager(center: center, rootOverride: root);
    await manager.initialize();
    await manager.presets();
  });
  tearDown(() async {
    await center.shutdown();
    await root.delete(recursive: true);
  });
  for (final width in [320.0, 600.0, 1200.0]) {
    testWidgets(
      'OCR model management renders and downloads shared components at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final boundary = GlobalKey();
        String? chosen;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 800),
                    textScaler: TextScaler.linear(width == 320 ? 1.3 : 1),
                  ),
                  child: OcrModelsPane(
                    manager: manager,
                    language: OcrSubtitleLanguage.chinese,
                    canChoose: true,
                    onChoose: (model) => chosen = model.id,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pumpAndSettle();
        expect(find.text('OCR 下载来源'), findsOneWidget);
        expect(find.text('PP-OCRv6 Tiny'), findsNothing);
        expect(find.text('PP-OCRv6 Small'), findsOneWidget);
        await tester.tap(find.text('语言、兼容性与来源').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        await tester.tap(find.text('语言、兼容性与来源').first);
        await tester.pumpAndSettle();
        final download = find.widgetWithText(FilledButton, '下载 / 继续').first;
        await tester.ensureVisible(download);
        await tester.pumpAndSettle();
        await tester.tap(download);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(
          center.enqueued,
          containsAll(['ocr-v6-small-det', 'ocr-v6-small-rec']),
        );
        expect(center.sourcePreference, 'auto');
        expect(chosen, isNull);
        for (final id in center.enqueued) {
          center.downloads[id]!.phase = ModelDownloadPhase.installed;
        }
        center.notifyListeners();
        await tester.pumpAndSettle();
        final choose = find.widgetWithText(FilledButton, '选择此模型').first;
        await tester.ensureVisible(choose);
        await tester.pumpAndSettle();
        await tester.tap(choose);
        await tester.pump();
        expect(chosen, 'ppocr-v6-small');
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/ocr-upgrade/models-${width.round()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
