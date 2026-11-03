import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/compact_stream_quality_layout.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

const _videoQualities = [
  BilibiliStreamQuality(id: 80, label: '1080P 高清'),
  BilibiliStreamQuality(id: 64, label: '720P 高清'),
];
const _normal = BilibiliAudioQuality(id: 30280, label: '普通音质');
const _hiRes = BilibiliAudioQuality(
  id: 30251,
  label: 'Hi-Res无损',
  isSpecial: true,
);
const _dolby = BilibiliAudioQuality(id: 30250, label: '杜比全景声', isSpecial: true);
final _item = VideoItem(
  id: 'portrait-quality',
  path: 'bilibili://stream/BVtest?cid=1',
  title: 'Portrait',
  durationMs: 120000,
  lastUpdated: 0,
  sourceRef: const MediaSourceRef(
    kind: MediaSourceKind.bilibiliStream,
    value: 'BVtest',
    bvid: 'BVtest',
    cid: 1,
  ),
);

// The UI must dispatch the same public switch methods as landscape. The real
// two-player handoff, failure retention and preference writes have their own
// service tests rather than a second portrait playback implementation.
class _RecordingPlayback extends MediaPlaybackService {
  _RecordingPlayback(this.special) : super.forTesting() {
    configure();
  }
  final BilibiliAudioQuality special;
  final videoRequests = <int>[];
  final audioRequests = <int>[];
  void configure({bool specialAvailable = true}) =>
      debugOverrideStreamQualityChrome(
        item: _item,
        qualities: _videoQualities,
        selected: selectedStreamQuality ?? _videoQualities.first,
        audioQualities: [if (specialAvailable) special, _normal],
        selectedAudio: selectedStreamAudioQuality ?? special,
      );
  @override
  Future<bool> switchBilibiliStreamQuality(
    int id, {
    bool forceReconnect = false,
  }) async {
    videoRequests.add(id);
    debugOverrideStreamQualityChrome(
      item: _item,
      qualities: _videoQualities,
      selected: _videoQualities.firstWhere((q) => q.id == id),
      audioQualities: [special, _normal],
      selectedAudio: selectedStreamAudioQuality,
    );
    return true;
  }

  @override
  Future<bool> switchBilibiliAudioQuality(int id) async {
    audioRequests.add(id);
    debugOverrideStreamQualityChrome(
      item: _item,
      qualities: _videoQualities,
      selected: selectedStreamQuality,
      audioQualities: [special, _normal],
      selectedAudio: id == special.id ? special : _normal,
    );
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<({_RecordingPlayback service, VideoPlayerController controller})>
  mount(
    WidgetTester tester,
    Size playerSize, {
    bool avoidControls = true,
    BilibiliAudioQuality special = _hiRes,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(playerSize.width, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _RecordingPlayback(special);
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    controller.value = const VideoPlayerValue(
      isInitialized: true,
      duration: Duration(minutes: 2),
    );
    final visible = ValueNotifier<bool>(true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
      service.dispose();
      visible.dispose();
    });
    final layout = CompactStreamQualityLayout.fromSize(
      playerSize,
      controlCount: 2,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    key: const ValueKey('portrait-player'),
                    width: playerSize.width,
                    height: playerSize.height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoControlsOverlay(
                          controller: controller,
                          mediaItemId: _item.id,
                          isLocked: false,
                          onTogglePlay: () {},
                          onBackPressed: () {},
                          onToggleLock: () {},
                          onSpeedUpdate: (_) async {},
                          showSubtitles: true,
                          onToggleSubtitles: () {},
                          onMoveSubtitles: () {},
                          isLongPressing: false,
                          longPressFeedbackText: '',
                          onLongPressStart: () => false,
                          onLongPressEnd: () {},
                          subtitleEntries: const [],
                          subtitleStyle: const SubtitleStyle(),
                          subtitleAlignment: Alignment.bottomCenter,
                          onEnterSubtitleDragMode: () {},
                          showPlayControls: false,
                          showBottomBar: false,
                          showCompactStreamQualityControls: true,
                          compactTopRightButtons: true,
                          playbackControlsVisibility: visible,
                          onOpenAspectRatio: () {},
                          aspectRatioLabel: '16:9',
                          showDanmakuControls: true,
                          onToggleDanmaku: () {},
                          onOpenDanmakuSettings: () {},
                        ),
                        Positioned(
                          bottom: 10,
                          right: 10,
                          child: SizedBox(
                            key: const ValueKey('portrait-fullscreen'),
                            width: 48,
                            height: 48,
                            child: IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.fullscreen),
                            ),
                          ),
                        ),
                        SubtitleOverlayGroup(
                          entries: const [
                            SubtitleOverlayEntry(text: '字幕盖住画质与音质选择'),
                          ],
                          referenceHeight: 720,
                          style: const SubtitleStyle(
                            layoutStyle: SubtitleLayoutStyle(fontSize: 20),
                          ),
                          alignment: const Alignment(0, .8),
                          playbackControlsVisibility: visible,
                          playbackControlRects: () => [
                            layout.bounds.inflate(2),
                          ],
                          avoidPlaybackControls: avoidControls,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (service: service, controller: controller);
  }

  for (final size in [
    const Size(240, 135),
    const Size(280, 158),
    const Size(320, 180),
    const Size(390, 220),
    const Size(430, 322),
    const Size(600, 338),
    const Size(800, 450),
    const Size(390, 520),
  ]) {
    testWidgets(
      'portrait quality controls fit $size, avoid captions, and dispatch both switches',
      (tester) async {
        final fixture = await mount(
          tester,
          size,
          textScale: size.width == 390 ? 1.6 : 1,
        );
        final audio = find.byKey(
          const ValueKey('video-controls-audio-quality-button'),
        );
        final video = find.byKey(
          const ValueKey('video-controls-quality-button'),
        );
        final player = tester.getRect(
          find.byKey(const ValueKey('portrait-player')),
        );
        final fullscreen = tester.getRect(
          find.byKey(const ValueKey('portrait-fullscreen')),
        );
        final caption = tester.getRect(
          find.descendant(
            of: find.byType(SubtitleOverlayGroup),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration,
            ),
          ),
        );
        for (final button in [audio, video]) {
          final rect = tester.getRect(button);
          expect(
            player.contains(rect.topLeft) && player.contains(rect.bottomRight),
            isTrue,
          );
          expect(rect.height, inInclusiveRange(28, 34));
          expect(rect.width, lessThanOrEqualTo(144));
          expect(rect.overlaps(fullscreen), isFalse);
          expect(rect.overlaps(caption), isFalse);
        }
        expect(tester.getRect(audio).overlaps(tester.getRect(video)), isFalse);
        expect(
          find.byKey(const ValueKey('video-controls-bottom-panel')),
          findsNothing,
        );
        await tester.tap(video);
        await tester.pumpAndSettle();
        await tester.tap(find.text('720P 高清').last);
        await tester.pumpAndSettle();
        expect(fixture.service.videoRequests, [64]);
        expect(fixture.service.selectedStreamAudioQuality, _hiRes);
        await tester.tap(audio);
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find.byKey(const ValueKey('video-controls-audio-quality-picker')),
        );
        expect(menu.width, greaterThanOrEqualTo(160));
        expect(menu.left, greaterThanOrEqualTo(0));
        expect(menu.right, lessThanOrEqualTo(size.width));
        await tester.tap(find.text('普通音质').last);
        await tester.pumpAndSettle();
        expect(fixture.service.audioRequests, [30280]);
        expect(fixture.service.selectedStreamQuality?.id, 64);
        final label = find.descendant(
          of: audio,
          matching: find.text('Hi-Res无损'),
        );
        expect(tester.widget<Text>(label).style?.color, Colors.white54);
        fixture.service.configure(specialAvailable: false);
        await tester.pump();
        expect(audio, findsNothing);
        expect(video, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      'caption painted over portrait controls still permits $kind selection',
      (tester) async {
        final fixture = await mount(
          tester,
          const Size(320, 180),
          avoidControls: false,
          special: _dolby,
        );
        final audio = find.byKey(
          const ValueKey('video-controls-audio-quality-button'),
        );
        final caption = tester.getRect(
          find.descendant(
            of: find.byType(SubtitleOverlayGroup),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration,
            ),
          ),
        );
        expect(caption.overlaps(tester.getRect(audio)), isTrue);
        await tester.tap(audio, kind: kind);
        await tester.pumpAndSettle();
        await tester.tap(find.text('普通音质').last, kind: kind);
        await tester.pumpAndSettle();
        expect(fixture.service.audioRequests, [30280]);
        await tester.tap(
          find.byKey(const ValueKey('video-controls-quality-button')),
          kind: kind,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('720P 高清').last, kind: kind);
        await tester.pumpAndSettle();
        expect(fixture.service.videoRequests, [64]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
