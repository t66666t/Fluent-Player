import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

void main() {
  testWidgets(
    'desktop pointer down and up preserve mini playback overlay state',
    (tester) async {
      _StatefulOverlayProbe.initCount = 0;

      await tester.pumpWidget(const MaterialApp(home: _OverlayHarness()));
      expect(_StatefulOverlayProbe.initCount, 1);

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: const Offset(100, 100));
      await pointer.down(const Offset(100, 100));
      await tester.pump();

      expect(find.byKey(MediaLibraryOverlayKeys.boxSelection), findsOneWidget);
      expect(_StatefulOverlayProbe.initCount, 1);

      await pointer.up();
      await tester.pump();

      expect(find.byKey(MediaLibraryOverlayKeys.boxSelection), findsNothing);
      expect(_StatefulOverlayProbe.initCount, 1);
    },
  );
}

class _OverlayHarness extends StatefulWidget {
  const _OverlayHarness();

  @override
  State<_OverlayHarness> createState() => _OverlayHarnessState();
}

class _OverlayHarnessState extends State<_OverlayHarness> {
  bool _isBoxSelecting = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _isBoxSelecting = true),
      onPointerUp: (_) => setState(() => _isBoxSelecting = false),
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          if (_isBoxSelecting)
            const Positioned.fill(
              key: MediaLibraryOverlayKeys.boxSelection,
              child: IgnorePointer(child: ColoredBox(color: Colors.blue)),
            ),
          const Positioned(
            key: MediaLibraryOverlayKeys.playbackBottomFill,
            left: 0,
            right: 0,
            bottom: 0,
            height: 8,
            child: ColoredBox(color: Colors.grey),
          ),
          const Positioned(
            key: MediaLibraryOverlayKeys.miniPlaybackCard,
            left: 0,
            right: 0,
            bottom: 8,
            height: 80,
            child: _StatefulOverlayProbe(),
          ),
        ],
      ),
    );
  }
}

class _StatefulOverlayProbe extends StatefulWidget {
  const _StatefulOverlayProbe();

  static int initCount = 0;

  @override
  State<_StatefulOverlayProbe> createState() => _StatefulOverlayProbeState();
}

class _StatefulOverlayProbeState extends State<_StatefulOverlayProbe> {
  @override
  void initState() {
    super.initState();
    _StatefulOverlayProbe.initCount += 1;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
