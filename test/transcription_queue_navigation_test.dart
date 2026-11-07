import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/transcription_queue_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    for (final visible in [true, false]) {
      testWidgets(
        'queue covers library at $size and restores visible=$visible',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({
            'showMiniPlaybackCard': visible,
          });
          final settings = SettingsService()..resetForTest();
          await settings.init();
          final playback = MediaPlaybackService();
          await playback.stop();
          final item = VideoItem(
            id: 'queue-navigation',
            path: 'local.mp4',
            title: 'Local media',
            durationMs: 120000,
            lastUpdated: 0,
          );
          playback.publishRestoredSessionPreview(
            item,
            const Duration(seconds: 12),
          );
          final manager = TranscriptionManager(settings: settings);
          final translate = SubtitleTranslateSettings();
          await translate.ensureLoaded();
          addTearDown(() async {
            await playback.stop();
            manager.dispose();
            translate.dispose();
            settings.resetForTest();
          });
          final root = GlobalKey<NavigatorState>();
          Future<void>? opened;
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: settings),
                ChangeNotifierProvider.value(value: playback),
                ChangeNotifierProvider.value(value: translate),
                ChangeNotifierProvider.value(value: manager),
                ChangeNotifierProvider.value(value: LibraryService()),
              ],
              child: MaterialApp(
                navigatorKey: root,
                navigatorObservers: [AppToast.routeObserver],
                theme: ThemeData.dark(),
                home: MediaLibraryShell(
                  home: Scaffold(
                    body: Builder(
                      builder: (context) => Center(
                        child: TextButton(
                          onPressed: () {
                            opened = openTranscriptionQueue(
                              context,
                              TranscriptionMediaSelection(),
                            );
                            unawaited(opened!);
                          },
                          child: const Text('Open queue'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final cardState = tester.state(find.byType(MiniPlaybackCard));
          expect(
            find.byTooltip('播放列表'),
            visible ? findsOneWidget : findsNothing,
          );
          final position = playback.position;
          final playbackState = playback.state;
          await tester.tap(find.text('Open queue'));
          await tester.pumpAndSettle();
          expect(find.byType(BatchSubtitleScreen), findsOneWidget);
          expect(root.currentState!.canPop(), isTrue);
          expect(find.byType(MiniPlaybackCard), findsNothing);
          expect(find.byTooltip('播放列表'), findsNothing);
          expect(settings.showMiniPlaybackCard, visible);
          expect(playback.currentItem, same(item));
          expect(playback.position, position);
          expect(playback.state, playbackState);
          await tester.tap(find.byIcon(Icons.arrow_back));
          await tester.pumpAndSettle();
          await opened;
          expect(root.currentState!.canPop(), isFalse);
          expect(find.byType(BatchSubtitleScreen), findsNothing);
          expect(tester.state(find.byType(MiniPlaybackCard)), same(cardState));
          expect(
            find.byTooltip('播放列表'),
            visible ? findsOneWidget : findsNothing,
          );
          expect(settings.showMiniPlaybackCard, visible);
          expect(playback.position, position);
          expect(playback.state, playbackState);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
