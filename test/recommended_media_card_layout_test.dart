import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';

import 'support/default_trial_features.dart';

class _IdlePlayback extends ChangeNotifier implements MediaPlaybackService {
  @override
  VideoItem? get currentItem => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previews = Platform.environment['CARD_DEFAULT_PREVIEWS'] == '1';
  final measurements = <Map<String, dynamic>>[];
  setUpAll(() async {
    await (FontLoader('CardLayoutFixture')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  tearDownAll(() async {
    if (!previews) return;
    final out = Directory('.artifacts/default-media-cards');
    await out.create(recursive: true);
    await File(
      '${out.path}/metrics.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(measurements));
  });

  for (final screen in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1200, 750),
    const Size(1280, 800),
    const Size(1920, 1080),
    const Size(2560, 1440),
  ]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'readable cards keep two real title lines at $screen / $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'mediaLibraryReadableCardDefaults': true,
          });
          SubtitleDebugSession.instance.resetForTest();
          final settings = SettingsService()..resetForTest();
          settings.defaultTrialDevice = DefaultSettingsDevice(
            screen.longestSide >= 1600
                ? TargetPlatform.windows
                : TargetPlatform.android,
            screen,
          );
          settings.featureSettingsForTrial = MemoryTrialFeatures();
          await settings.init();
          final playback = _IdlePlayback();
          addTearDown(playback.dispose);
          tester.view.physicalSize = screen;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const title =
              '这是一个需要完整显示至少两行的课程标题：字幕、音乐与视频学习 Introduction to a longer lesson';
          const folderTitle = '这个文件夹的名称也需要至少两行空间，下面还要显示项目数量';
          final capture = GlobalKey();
          MediaLibraryCardGridMetrics? result;
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsService>.value(value: settings),
                ChangeNotifierProvider<LibraryService>.value(
                  value: LibraryService(),
                ),
                ChangeNotifierProvider<MediaPlaybackService>.value(
                  value: playback,
                ),
              ],
              child: MaterialApp(
                theme: ThemeData.dark().copyWith(
                  textTheme: ThemeData.dark().textTheme.apply(
                    fontFamily: 'CardLayoutFixture',
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      final style = settings.homeCardStyleFor(screen);
                      final metrics = MediaLibraryLayoutDefaults.cardGrid(
                        screenSize: screen,
                        style: style,
                        textScaler: MediaQuery.textScalerOf(context),
                        textStyle: DefaultTextStyle.of(context).style,
                      );
                      result = metrics;
                      return SingleChildScrollView(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: RepaintBoundary(
                            key: capture,
                            child: SizedBox(
                              width:
                                  metrics.cellWidth * 2 + metrics.crossSpacing,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: metrics.cellWidth,
                                    height: metrics.cellHeight,
                                    child: MediaLibraryMediaGridCard(
                                      item: VideoItem(
                                        id: 'fixture',
                                        path: 'fixture.mp4',
                                        title: title,
                                        durationMs: 65000,
                                        lastUpdated: 1,
                                      ),
                                      titleScale: metrics.titleScale,
                                      relativePath: '课程 / 学习资料',
                                      coverOverride: const ColoredBox(
                                        color: Color(0xff334960),
                                        child: Center(
                                          child: Icon(
                                            Icons.movie_outlined,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                      showActivityMenu: false,
                                      showLocate: false,
                                      onTap: () {},
                                      onLocate: () {},
                                    ),
                                  ),
                                  SizedBox(width: metrics.crossSpacing),
                                  SizedBox(
                                    width: metrics.cellWidth,
                                    height: metrics.cellHeight,
                                    child: MediaLibraryFolderGridCard(
                                      collection: VideoCollection(
                                        id: 'folder-fixture',
                                        name: folderTitle,
                                        createTime: 1,
                                        coverLabel: '',
                                      ),
                                      titleScale: metrics.titleScale,
                                      showActivityMenu: false,
                                      onTap: () {},
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final label in [title, folderTitle]) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.text(label),
            );
            final twoLines = TextPainter(
              text: paragraph.text,
              textDirection: paragraph.textDirection,
              textScaler: paragraph.textScaler,
              maxLines: 2,
            )..layout(maxWidth: paragraph.size.width);
            expect(twoLines.didExceedMaxLines, true);
            expect(
              paragraph.size.height + .1,
              greaterThanOrEqualTo(twoLines.height),
              reason: '$label is clipped below two lines',
            );
            twoLines.dispose();
          }
          final font = MediaLibraryLayoutDefaults.titleFontSize(
            result!.cellWidth,
            result!.titleScale,
          );
          expect(font, closeTo(result!.cellWidth / 12, .01));
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(title),
          );
          expect(paragraph.text.style!.fontSize, 12.5);
          expect(
            paragraph.getTransformTo(null).entry(0, 0),
            closeTo(result!.cellWidth / 150, 1e-6),
          );
          expect(
            paragraph.getTransformTo(null).entry(1, 1),
            closeTo(result!.cellWidth / 150, 1e-6),
          );
          if (previews && scale == 1) {
            measurements.add({
              'screen': [screen.width, screen.height],
              'columns': result!.crossAxisCount,
              'cardWidth': result!.cellWidth,
              'cardHeight': result!.cellHeight,
              'titleFontSize': font,
            });
            if ([320.0, 768.0, 1920.0].contains(screen.width)) {
              await tester.runAsync(() async {
                final out = Directory('.artifacts/default-media-cards');
                await out.create(recursive: true);
                final boundary =
                    capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final rendered = await boundary.toImage(pixelRatio: 2);
                final bytes = await rendered.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${out.path}/${screen.width.toInt()}x${screen.height.toInt()}.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                rendered.dispose();
              });
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
