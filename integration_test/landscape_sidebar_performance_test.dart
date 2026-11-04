import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/desktop_player_sidebar.dart';
import 'package:video_player_app/widgets/player_sidebar_motion.dart';
import 'package:video_player_app/widgets/stable_video_surface.dart';
import 'package:video_player_app/widgets/subtitle_chat_sidebar.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

// Production sidebar, transcript and controls beside a real native video.
// No account, library, downloads or model inference is initialized. Feed the
// same local HTTP fixture to every target, in profile mode, before and after.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const source = String.fromEnvironment('SIDEBAR_PROFILE_VIDEO');
  const label = String.fromEnvironment(
    'SIDEBAR_PROFILE_LABEL',
    defaultValue: 'after',
  );
  const rounds = int.fromEnvironment(
    'SIDEBAR_PROFILE_ROUNDS',
    defaultValue: 100,
  );
  testWidgets('landscape sidebar native frame profile', (tester) async {
    expect(source, isNotEmpty, reason: 'Provide SIDEBAR_PROFILE_VIDEO');
    SharedPreferences.setMockInitialValues({'autoScrollSubtitles': false});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    NativeVideoPlayerMediaKit.ensureInitialized();
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    final sourceUri = Uri.parse(source);
    final controller = sourceUri.scheme == 'file'
        ? VideoPlayerController.file(File.fromUri(sourceUri))
        : VideoPlayerController.networkUrl(sourceUri);
    final frames = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => binding.scheduleFrame(),
    );
    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
    } finally {
      frames.cancel();
    }
    await controller.setVolume(0);
    await controller.setLooping(true);
    await controller.play();
    final key = GlobalKey<_ProfileState>();
    final timings = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
    binding.addTimingsCallback(collect);
    final operations = <Map<String, Object>>[];
    final rssBefore = ProcessInfo.currentRss;
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: MediaPlaybackService(),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
            ),
            home: _Profile(key: key, controller: controller),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      final playbackOnlyStart = developer.Timeline.now;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final playbackOnlyEnd = developer.Timeline.now;
      final state = key.currentState!;
      final sequence = <String?>[
        'subtitles',
        'chat',
        'settings',
        'subtitles',
        null,
      ];
      final visited = <String>{};
      for (var round = 0; round < rounds; round++) {
        final panel = sequence[round % sequence.length];
        final start = developer.Timeline.now;
        state.open(panel, onLeft: (round ~/ 25).isOdd);
        binding.scheduleFrame();
        await binding.endOfFrame;
        final committed = developer.Timeline.now;
        operations.add({
          'round': round,
          'panel': panel ?? 'closed',
          'startUs': start,
          'firstUiCommitUs': committed - start,
          'cold': panel != null && visited.add(panel),
          'left': state.left,
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final end = developer.Timeline.now;
      await Future<void>.delayed(const Duration(seconds: 1));
      final start = operations.first['startUs']! as int;
      final measured = timings.where((frame) {
        final at = frame.timestampInMicroseconds(ui.FramePhase.buildStart);
        return at >= start && at <= end;
      }).toList();
      final playbackOnly = timings.where((frame) {
        final at = frame.timestampInMicroseconds(ui.FramePhase.buildStart);
        return at >= playbackOnlyStart && at <= playbackOnlyEnd;
      }).toList();
      final hz = ui.PlatformDispatcher.instance.views.first.display.refreshRate;
      final budget = 1000000 / (hz > 0 ? hz : 60);
      Map<String, Object> distribution(Iterable<int> values) {
        final sorted = values.toList()..sort();
        if (sorted.isEmpty) return {'count': 0};
        double at(double percentile) =>
            sorted[((sorted.length - 1) * percentile).round()] / 1000;
        return {
          'count': sorted.length,
          'p95Ms': at(.95),
          'p99Ms': at(.99),
          'maxMs': sorted.last / 1000,
          'overBudget': sorted.where((v) => v > budget).length,
        };
      }

      binding.reportData = {
        'label': label,
        'platform': Platform.operatingSystem,
        'pid': pid,
        'scenario':
            'native video with production sidebar, controls and 12000 cues; synthetic chat/settings lists',
        'responseMetric':
            'callback to framework endOfFrame; excludes physical display presentation',
        'rounds': rounds,
        'refreshRate': hz,
        'budgetMs': budget / 1000,
        'ui': distribution(measured.map((f) => f.buildDuration.inMicroseconds)),
        'raster': distribution(
          measured.map((f) => f.rasterDuration.inMicroseconds),
        ),
        'firstUiCommit': distribution(
          operations.map((o) => o['firstUiCommitUs']! as int),
        ),
        'coldFirstUiCommit': distribution(
          operations
              .where((o) => o['cold'] == true)
              .map((o) => o['firstUiCommitUs']! as int),
        ),
        'warmFirstUiCommit': distribution(
          operations
              .where((o) => o['cold'] == false)
              .map((o) => o['firstUiCommitUs']! as int),
        ),
        'playbackOnlyUi': distribution(
          playbackOnly.map((f) => f.buildDuration.inMicroseconds),
        ),
        'playbackOnlyRaster': distribution(
          playbackOnly.map((f) => f.rasterDuration.inMicroseconds),
        ),
        'rssBeforeBytes': rssBefore,
        'rssAfterBytes': ProcessInfo.currentRss,
        'operations': operations,
        'frames': measured
            .map(
              (f) => {
                'vsyncUs': f.timestampInMicroseconds(ui.FramePhase.vsyncStart),
                'uiUs': f.buildDuration.inMicroseconds,
                'rasterUs': f.rasterDuration.inMicroseconds,
              },
            )
            .toList(),
      };
      expect(measured, isNotEmpty);
      expect(controller.value.hasError, isFalse);
      expect(controller.value.position, greaterThan(Duration.zero));
    } finally {
      binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    }
  });
}

class _Profile extends StatefulWidget {
  const _Profile({super.key, required this.controller});
  final VideoPlayerController controller;
  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile>
    with SingleTickerProviderStateMixin {
  late final motion = PlayerSidebarMotion(vsync: this);
  Object readingSurface = PlayerSidebarMotion.subtitleSurface;
  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  String? panel;
  bool left = false;
  final cues = List.generate(
    12000,
    (i) => SubtitleItem(
      index: i,
      startTime: Duration(seconds: i * 3),
      endTime: Duration(seconds: i * 3 + 2),
      text: '第 $i 句：横屏边栏快速切换与连续阅读。 A flowing transcript.',
    ),
  );
  void open(String? value, {required bool onLeft}) => setState(() {
    panel = value;
    left = onLeft;
  });
  @override
  Widget build(BuildContext context) {
    final reading = panel == 'subtitles' || panel == 'chat';
    if (reading) {
      readingSurface = panel == 'chat'
          ? PlayerSidebarMotion.chatSurface
          : PlayerSidebarMotion.subtitleSurface;
    }
    motion.configure(
      target: panel,
      dockExtent: panel == null
          ? 0
          : panel == 'chat'
          ? 412
          : reading
          ? 312
          : 320,
      visibleSurfaces: {
        if (panel != null) reading ? 'reading' : panel!,
        readingSurface,
      },
      immediate: MediaQuery.disableAnimationsOf(context),
    );
    final controls = VideoControlsOverlay(
      controller: widget.controller,
      layoutWidth:
          MediaQuery.sizeOf(context).width -
          (panel == null
              ? 0
              : panel == "chat"
              ? 412
              : reading
              ? 312
              : 320),
      mediaTitle: 'Sidebar frame profile',
      initialShowControls: true,
      enableSeekThumbnailPreview: false,
      isLocked: false,
      onBackPressed: () {},
      onToggleFullScreen: () {},
      onToggleLock: () {},
      onTogglePlay: () {},
      onOpenSettings: () {},
      onSpeedUpdate: (_) async {},
      showSubtitles: false,
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
    );
    final sidebar = DesktopPlayerSidebar(
      key: const ValueKey('profile-sidebar'),
      motion: motion,
      panelId: reading ? 'reading' : panel,
      panel: _LongPanel(name: 'settings', count: 2000),
      width: panel == 'chat'
          ? 400
          : reading
          ? 300
          : 320,
      retainedId: 'reading',
      retainedWidth: 300,
      retainedPanel: SubtitleChatSidebar(
        motion: motion,
        showChat: panel == 'chat',
        isVisible: reading,
        subtitleWidth: 300,
        chatWidth: 400,
        onLeft: left,
        subtitles: SubtitleSidebar(
          subtitles: cues,
          controller: widget.controller,
          isCompact: true,
          isVisible: panel == 'subtitles',
        ),
        chat: const _LongPanel(name: 'chat', count: 500),
      ),
      divider: reading ? const ColoredBox(color: Colors.grey) : null,
      dividerWidth: reading ? 12 : 0,
      viewportSize: MediaQuery.sizeOf(context),
      onLeft: left,
    );
    final video = StableVideoSurface(
      referenceSize: const Size(1920, 1080),
      child: VideoPlayer(widget.controller),
    );
    return Scaffold(
      body: Row(
        children: [
          if (left) sidebar,
          Expanded(
            key: const ValueKey('profile-video-surface'),
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  Stack(fit: StackFit.expand, children: [video, controls]),
            ),
          ),
          if (!left) sidebar,
        ],
      ),
    );
  }
}

class _LongPanel extends StatelessWidget {
  const _LongPanel({required this.name, required this.count});
  final String name;
  final int count;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(padding: const EdgeInsets.all(12), child: Text(name)),
      const TextField(decoration: InputDecoration(hintText: 'Retained draft')),
      Expanded(
        child: ListView.builder(
          itemCount: count,
          itemBuilder: (_, i) => ListTile(
            title: Text('$name $i'),
            subtitle: const Text(
              'A longer reading line with controls and text.',
            ),
          ),
        ),
      ),
    ],
  );
}
