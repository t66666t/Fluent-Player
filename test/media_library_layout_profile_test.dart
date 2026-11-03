import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_list_layout_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('横纵间距都是卡片宽度的比例，列数变化时像素间距跟着变', () {
    const wide = MediaLibraryLayoutDefaults.distributeWidth;
    final five = wide(
      availableWidth: 1280,
      columns: 5,
      spacingScale: 0.12,
    );
    final ten = wide(
      availableWidth: 1280,
      columns: 10,
      spacingScale: 0.12,
    );

    expect(five.crossSpacing / five.cellWidth, closeTo(0.12, 1e-9));
    expect(ten.crossSpacing / ten.cellWidth, closeTo(0.12, 1e-9));
    expect(five.outerPadding / five.cellWidth, closeTo(0.12, 1e-9));
    expect(ten.cellWidth, lessThan(five.cellWidth));
    expect(ten.crossSpacing, lessThan(five.crossSpacing));

    final occupied =
        ten.outerPadding * 2 + ten.crossSpacing * 9 + ten.cellWidth * 10;
    expect(occupied, closeTo(1280, 1e-6));
  });

  test('对数滑条中点落在舒适区支点，两端仍能到达极限', () {
    const range = MediaLibraryLayoutDefaults.columnRange;
    expect(range.fromSlider(0.5), closeTo(8, 1e-6));
    expect(range.toSlider(8), closeTo(0.5, 1e-6));
    expect(range.fromSlider(0), closeTo(1, 1e-6));
    expect(range.fromSlider(1), closeTo(20, 1e-6));

    const title = MediaLibraryLayoutDefaults.titleRange;
    expect(title.fromSlider(0.5), closeTo(0.104, 1e-6));
    expect(title.fromSlider(0), closeTo(0.045, 1e-6));
    expect(title.fromSlider(1), closeTo(0.22, 1e-6));

    const spacing = MediaLibraryLayoutDefaults.spacingRange;
    expect(spacing.fromSlider(0.5), closeTo(0.08, 1e-4));
    expect(spacing.fromSlider(0), closeTo(0, 1e-4));
    expect(spacing.fromSlider(1), closeTo(0.45, 1e-4));
  });

  test('不同尺寸设备的默认列数按横竖屏分开', () {
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(const Size(390, 844)),
      3,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(const Size(844, 390)),
      6,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(744, 1133),
      ),
      5,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1133, 744),
      ),
      8,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(800, 1280),
      ),
      6,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1280, 800),
      ),
      10,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1024, 1366),
      ),
      7,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1366, 1024),
      ),
      11,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1080, 1920),
      ),
      8,
    );
    expect(
      MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(
        const Size(1920, 1080),
      ),
      12,
    );
  });

  test('未设置时使用尺寸默认值，旧列数只继承给横屏', () async {
    SharedPreferences.setMockInitialValues({
      'homeGridCrossAxisCount': 10,
      'homeCardTitleFontSize': 0.104,
      'homeCardAspectRatio': 1.0 / 1.39,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();

    const landscape = Size(1280, 800);
    const portrait = Size(800, 1280);
    final landscapeStyle = settings.homeCardStyleFor(landscape);
    final portraitStyle = settings.homeCardStyleFor(portrait);

    expect(landscapeStyle.crossAxisCount, 10);
    expect(portraitStyle.crossAxisCount, 6);
    expect(landscapeStyle.titleScale, closeTo(0.104, 1e-9));
    expect(portraitStyle.titleScale, closeTo(0.104, 1e-9));
    expect(landscapeStyle.heightScale, closeTo(1.39, 1e-6));
    expect(portraitStyle.heightScale, closeTo(1.39, 1e-6));
    expect(landscapeStyle.crossSpacingScale, closeTo(0.08, 1e-9));
    expect(portraitStyle.mainSpacingScale, closeTo(0.08, 1e-9));
  });

  test('横屏和竖屏的卡片样式可以分别写入并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    const landscape = Size(1280, 800);
    const portrait = Size(800, 1280);

    await settings.updateHomeCardStyleFor(
      landscape,
      crossAxisCount: 10,
      titleScale: 0.104,
      heightScale: 1.39,
      crossSpacingScale: 0.10,
      mainSpacingScale: 0.16,
    );
    await settings.updateHomeCardStyleFor(
      portrait,
      crossAxisCount: 6,
      titleScale: 0.11,
      heightScale: 1.5,
      crossSpacingScale: 0.08,
      mainSpacingScale: 0.14,
    );

    final landscapeStyle = settings.homeCardStyleFor(landscape);
    final portraitStyle = settings.homeCardStyleFor(portrait);
    expect(landscapeStyle.crossAxisCount, 10);
    expect(portraitStyle.crossAxisCount, 6);
    expect(landscapeStyle.titleScale, closeTo(0.104, 1e-9));
    expect(portraitStyle.titleScale, closeTo(0.11, 1e-9));
    expect(landscapeStyle.heightScale, closeTo(1.39, 1e-6));
    expect(portraitStyle.heightScale, closeTo(1.5, 1e-6));
    expect(landscapeStyle.crossSpacingScale, closeTo(0.10, 1e-9));
    expect(portraitStyle.crossSpacingScale, closeTo(0.08, 1e-9));
    expect(landscapeStyle.mainSpacingScale, closeTo(0.16, 1e-9));
    expect(portraitStyle.mainSpacingScale, closeTo(0.14, 1e-9));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('homeGridCrossAxisCountLandscape'), 10);
    expect(prefs.getInt('homeGridCrossAxisCountPortrait'), 6);
    expect(prefs.getDouble('homeCardTitleFontSizePortrait'), closeTo(0.11, 1e-9));
    expect(
      prefs.getDouble('homeCardTitleFontSizeLandscape'),
      closeTo(0.104, 1e-9),
    );
  });

  test('文件夹卡片样式跟随首页，旧的独立文件夹设置会被忽略', () async {
    SharedPreferences.setMockInitialValues({
      'homeGridCrossAxisCount': 8,
      'homeCardTitleFontSize': 0.11,
      'homeCardAspectRatio': 1.0 / 1.5,
      'homeCardCrossSpacingScaleLandscape': 0.20,
      'homeCardMainSpacingScaleLandscape': 0.18,
      'videoCardCrossAxisCount': 3,
      'videoCardCrossAxisCountPortrait': 2,
      'videoCardTitleFontSize': 0.05,
      'videoCardAspectRatio': 1.0 / 0.8,
      'videoCardCrossSpacingScaleLandscape': 0.01,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();

    const landscape = Size(1280, 800);
    const portrait = Size(800, 1280);
    final homeLandscape = settings.homeCardStyleFor(landscape);
    final collectionLandscape = settings.collectionCardStyleFor(landscape);
    final collectionPortrait = settings.collectionCardStyleFor(portrait);

    expect(collectionLandscape.crossAxisCount, homeLandscape.crossAxisCount);
    expect(collectionLandscape.crossAxisCount, 8);
    expect(collectionLandscape.titleScale, closeTo(0.11, 1e-9));
    expect(collectionLandscape.heightScale, closeTo(1.5, 1e-6));
    expect(collectionLandscape.crossSpacingScale, closeTo(0.20, 1e-9));
    expect(collectionLandscape.mainSpacingScale, closeTo(0.18, 1e-9));
    // Portrait still uses the size-class default, not the leftover folder key.
    expect(collectionPortrait.crossAxisCount, 6);

    await settings.updateCollectionCardStyleFor(
      landscape,
      crossAxisCount: 9,
    );
    expect(settings.homeCardStyleFor(landscape).crossAxisCount, 9);
    expect(settings.collectionCardStyleFor(landscape).crossAxisCount, 9);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('homeGridCrossAxisCountLandscape'), 9);
    expect(prefs.getInt('videoCardCrossAxisCountLandscape'), isNull);
  });

  test('全新安装按尺寸给出默认列数，标题高度使用舒适区默认值', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    final phonePortrait = settings.homeCardStyleFor(const Size(390, 844));
    final tabletLandscape = settings.collectionCardStyleFor(
      const Size(1280, 800),
    );
    expect(phonePortrait.crossAxisCount, 3);
    expect(tabletLandscape.crossAxisCount, 10);
    expect(phonePortrait.titleScale, closeTo(0.104, 1e-9));
    expect(tabletLandscape.heightScale, closeTo(1.08, 1e-6));
  });

  test('最近添加和继续学习的区块间隙是纵向间距的固定倍数', () {
    const flow = MediaLibraryFlowSpacing(row: 10, outer: 4);
    expect(flow.leading, 10);
    expect(flow.attached, 5);
    expect(flow.block, 15);
    expect(flow.section, 20);
    expect(flow.gap(0), isNull);

    const size = Size(390, 844);
    const card = MediaCardStyleSettings(
      crossAxisCount: 3,
      titleScale: 0.104,
      heightScale: 1.08,
      crossSpacingScale: 0.08,
      mainSpacingScale: 0.16,
    );
    final resolved = mediaLibraryFlowSpacingFor(
      screenSize: size,
      useList: false,
      cardStyle: card,
      listStyle: MediaListStyleSettings(
        crossAxisCount: 1,
        titleScale: 0.03,
        heightScale: 0.1,
        crossSpacingScale: 0.03,
        mainSpacingScale: 0.03,
        showThumbnail: true,
        showIndex: false,
      ),
    );
    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: size,
      style: card,
    );
    expect(resolved.row, metrics.mainSpacing);
    expect(resolved.outer, metrics.outerPadding);
    expect(resolved.section, metrics.mainSpacing * 2);
  });

  test('square cover keeps the media-card title block', () {
    const style = MediaCardStyleSettings(
      crossAxisCount: 3,
      titleScale: 0.104,
      heightScale: 1.08,
      crossSpacingScale: 0.08,
      mainSpacingScale: 0.16,
    );
    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      screenSize: const Size(390, 844),
      style: style,
    );
    final wideCover =
        metrics.cellWidth / MediaLibraryCardGridMetrics.standardCoverAspectRatio;
    final info = metrics.cellHeight - wideCover;
    final square = metrics.cellHeightForCoverAspect(1);
    expect(square - metrics.cellWidth, closeTo(info, 0.001));
    expect(square, greaterThan(metrics.cellHeight));
  });
}
