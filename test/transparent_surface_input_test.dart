import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_entry_reveal.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_message_navigation.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/widgets/sidebar_surface_transition.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_loading.dart';
import 'package:video_player_app/widgets/bilibili_panel_overlay.dart';

void main() {
  testWidgets(
    'a restoring chat cannot activate invisible message actions',
    (tester) async {
      final controller = AiMessageViewportController();
      addTearDown(controller.dispose);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiMessageViewport(
              messages: [
                AiChatMessage(id: 'a', role: 'assistant', content: 'a'),
              ],
              controller: controller,
              initialAtEnd: true,
              onNavigate: () {},
              onUserScroll: (_) => false,
              itemBuilder: (_, _) => TextButton(
                focusNode: focus,
                onPressed: () => taps++,
                child: const Text('Message action'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('Message action'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        0,
      );
      await tester.tapAt(tester.getCenter(find.text('Message action')));
      focus.requestFocus();
      await tester.pump();
      expect(taps, 0);
      expect(focus.hasFocus, isFalse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message action'));
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.all(),
  );

  for (final active in [false, true]) {
    testWidgets('Bilibili rows match their painted state: ticker=$active', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: active,
              child: BilibiliAdaptiveList(
                itemCount: 1,
                animateItems: true,
                itemBuilder: (_, _) => TextButton(
                  onPressed: () => taps++,
                  child: const Text('Bilibili row'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tapAt(tester.getCenter(find.text('Bilibili row')));
      expect(taps, active ? 0 : 1);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bilibili row'));
      expect(taps, active ? 1 : 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Bilibili results match their painted state: ticker=$active', (
      tester,
    ) async {
      var loading = true;
      var taps = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: active,
              child: StatefulBuilder(
                builder: (_, set) {
                  update = set;
                  return BilibiliLoadTransition(
                    loading: loading,
                    placeholder: const Text('Loading'),
                    child: TextButton(
                      onPressed: () => taps++,
                      child: const Text('Result action'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      update(() => loading = false);
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.text('Result action')));
      expect(taps, active ? 0 : 1);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Result action'));
      expect(taps, active ? 1 : 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a transparent Bilibili scrim cannot intercept the video', (
    tester,
  ) async {
    var open = false;
    var taps = 0;
    var dismissals = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, set) {
            update = set;
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
                Positioned.fill(
                  child: BilibiliPanelOverlay(
                    panel: open ? const Text('Panel') : null,
                    fromLeft: false,
                    width: 200,
                    onDismiss: () => dismissals++,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => open = true);
    await tester.pump();
    await tester.tapAt(const Offset(100, 200));
    expect(taps, 1);
    expect(dismissals, 0);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 200));
    expect(taps, 1);
    expect(dismissals, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a transparent sidebar cannot receive taps, focus or semantics',
    (tester) async {
      final opacity = ValueNotifier<double>(0);
      final focus = FocusNode();
      addTearDown(opacity.dispose);
      addTearDown(focus.dispose);
      final semantics = tester.ensureSemantics();
      var semanticsDisposed = false;
      addTearDown(() {
        if (!semanticsDisposed) semantics.dispose();
      });
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SidebarSurfaceTransition(
              visible: true,
              opacity: _ValueAnimation(opacity),
              child: TextButton(
                focusNode: focus,
                onPressed: () => taps++,
                child: const Text('Hidden sidebar action'),
              ),
            ),
          ),
        ),
      );
      await tester.tapAt(tester.getCenter(find.text('Hidden sidebar action')));
      focus.requestFocus();
      await tester.pump(const Duration(seconds: 1));
      expect(taps, 0);
      expect(focus.hasFocus, isFalse);
      expect(find.semantics.byLabel('Hidden sidebar action'), findsNothing);
      opacity.value = 0.001; // Still rounds to zero painted alpha.
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.text('Hidden sidebar action')));
      expect(taps, 0);
      opacity.value = 1;
      await tester.pump();
      await tester.tap(find.text('Hidden sidebar action'));
      expect(taps, 1);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.semantics.byLabel('Hidden sidebar action'), findsOneWidget);
      opacity.value = 0;
      await tester.pump();
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.text('Hidden sidebar action')));
      expect(taps, 1);
      expect(focus.hasFocus, isFalse);
      expect(find.semantics.byLabel('Hidden sidebar action'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      semanticsDisposed = true;
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('a visible sidebar settles when its ticker is paused', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: false,
          child: SidebarSurfaceTransition(
            visible: true,
            animateInitial: true,
            child: Text('Visible tool'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester
          .widget<FadeTransition>(find.byType(FadeTransition).last)
          .opacity
          .value,
      1,
    );
  });

  for (final active in [false, true]) {
    testWidgets(
      'an unrevealed cloud entry cannot be activated: active=$active',
      (tester) async {
        var taps = 0;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TickerMode(
                enabled: active,
                child: CloudDriveEntryReveal(
                  index: 5,
                  columns: 1,
                  revealed: false,
                  onRevealed: () {},
                  child: TextButton(
                    focusNode: focus,
                    onPressed: () => taps++,
                    child: const Text('Hidden cloud entry'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tapAt(tester.getCenter(find.text('Hidden cloud entry')));
        focus.requestFocus();
        await tester.pump();
        expect(taps, 0);
        expect(focus.hasFocus, isFalse);
        if (active) {
          await tester.pumpAndSettle();
          await tester.tap(find.text('Hidden cloud entry'));
          expect(taps, 1);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.all(),
    );
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('a fading deleted task cannot be restarted at width=$width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var deleting = false;
      var starts = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return TaskQueueTable(
                  tasks: const [
                    BatchSubtitleTaskView(
                      mediaKey: 'task',
                      videoPath: '/test.mp4',
                      videoName: 'Video',
                      videoDuration: '00:10',
                      isExternal: true,
                      status: TranscriptionStatus.idle,
                      progress: 0,
                      createdAt: 0,
                    ),
                  ],
                  autoDeletedKeys: {if (deleting) 'task': true},
                  onStart: (_) => starts++,
                  onRetry: (_) {},
                  onDelete: (_) {},
                  onReorder: (_, _) {},
                );
              },
            ),
          ),
        ),
      );
      final start = find.descendant(
        of: find.byKey(const ValueKey('task')),
        matching: find.byTooltip('开始'),
      );
      expect(start, findsOneWidget);
      final position = tester.getCenter(start);
      update(() => deleting = true);
      await tester.pumpAndSettle();
      await tester.tapAt(position);
      expect(starts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _ValueAnimation extends Animation<double> {
  _ValueAnimation(this.valueSource);
  final ValueNotifier<double> valueSource;
  @override
  double get value => valueSource.value;
  @override
  AnimationStatus get status =>
      value == 0 ? AnimationStatus.dismissed : AnimationStatus.completed;
  @override
  void addListener(VoidCallback listener) => valueSource.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      valueSource.removeListener(listener);
  @override
  void addStatusListener(AnimationStatusListener listener) {}
  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}
