import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('媒体列表模式关键配置可初始化并恢复', () async {
    SharedPreferences.setMockInitialValues({
      'mediaLibraryViewMode': 1,
      'mediaListCrossAxisCount': 12,
      'mediaListShowThumbnail': false,
      'mediaListShowIndex': true,
      'mediaListItemHeightScale': 0.12,
      'mediaListMainSpacingScale': 0.01,
      'mediaListCrossSpacingScale': 0.05,
      'mediaListTitleScale': 0.06,
      'mediaListCoverOffset': -0.35,
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.mediaLibraryViewMode, 1);
    expect(settings.mediaListCrossAxisCount, 12);
    expect(settings.mediaListShowThumbnail, isFalse);
    expect(settings.mediaListShowIndex, isTrue);
    expect(settings.mediaListItemHeightScale, 0.12);
    expect(settings.mediaListMainSpacingScale, 0.01);
    expect(settings.mediaListCrossSpacingScale, 0.05);
    expect(settings.mediaListTitleScale, 0.06);
    expect(settings.mediaListCoverOffset, -0.35);
  });

  test('媒体列表每行数量支持 1-20 并在越界时钳制', () async {
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.updateSetting('mediaListCrossAxisCount', 20);
    expect(settings.mediaListCrossAxisCount, 20);

    await settings.updateSetting('mediaListCrossAxisCount', 99);
    expect(settings.mediaListCrossAxisCount, 20);

    await settings.updateSetting('mediaListCrossAxisCount', 0);
    expect(settings.mediaListCrossAxisCount, 1);
  });

  test('媒体列表允许极小行高、零间距和极小标题字号', () async {
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.updateSetting('mediaListItemHeightScale', 0.001);
    await settings.updateSetting('mediaListMainSpacingScale', 0.0);
    await settings.updateSetting('mediaListCrossSpacingScale', 0.0);
    await settings.updateSetting('mediaListTitleScale', 0.001);

    expect(settings.mediaListItemHeightScale, 0.001);
    expect(settings.mediaListMainSpacingScale, 0.0);
    expect(settings.mediaListCrossSpacingScale, 0.0);
    expect(settings.mediaListTitleScale, 0.001);
  });

  test('结构化导入排序设置可恢复并持久化更新', () async {
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.saveStructuredImportSort(
      field: 'modifiedTime',
      direction: 'descending',
    );

    expect(settings.structuredImportSortField, 'modifiedTime');
    expect(settings.structuredImportSortDirection, 'descending');

    await settings.saveStructuredImportSortField('fileName');
    await settings.saveStructuredImportSortDirection('ascending');

    expect(settings.structuredImportSortField, 'fileName');
    expect(settings.structuredImportSortDirection, 'ascending');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('structuredImportSortField'), 'fileName');
    expect(prefs.getString('structuredImportSortDirection'), 'ascending');
  });

  test('注册表初始化会归一化越界和非法配置并回写', () async {
    SharedPreferences.setMockInitialValues({
      'mediaListCrossAxisCount': 99,
      'structuredImportSortField': 'unexpected',
      'structuredImportSortDirection': 'sideways',
    });

    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.mediaListCrossAxisCount, 20);
    expect(settings.structuredImportSortField, 'fileName');
    expect(settings.structuredImportSortDirection, 'ascending');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('mediaListCrossAxisCount'), 20);
    expect(prefs.getString('structuredImportSortField'), 'fileName');
    expect(prefs.getString('structuredImportSortDirection'), 'ascending');
  });

  test('结构化导入文件名排序符合自然顺序与拼音顺序', () {
    final names = ['张三10.mp4', 'A02.mp4', '李四2.mp4', 'A1.mp4', '陈一.mp4'];
    names.sort(LibraryService.compareStructuredImportNames);

    expect(names, ['A1.mp4', 'A02.mp4', '陈一.mp4', '李四2.mp4', '张三10.mp4']);

    final reversed = [...names.reversed];
    expect(reversed, ['张三10.mp4', '李四2.mp4', '陈一.mp4', 'A02.mp4', 'A1.mp4']);
  });
}
