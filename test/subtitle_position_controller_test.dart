import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/services/subtitle_position_controller.dart';
import 'package:video_player_app/utils/subtitle_position_geometry.dart';

void main() {
  late List<FrameCallback> frames;
  late SubtitlePositionController controller;

  setUp(() {
    frames = <FrameCallback>[];
    controller = SubtitlePositionController(frameScheduler: frames.add);
    controller.geometry.update(
      const SubtitleLaidOutGeometry(
        viewport: Size(400, 300),
        contentSize: Size(80, 40),
        origin: Offset(40, 50),
        contentRect: Rect.fromLTWH(40, 50, 80, 40),
        paintRect: Rect.fromLTWH(40, 50, 80, 40),
        hitRect: Rect.fromLTWH(28, 38, 104, 64),
        presetDefault: false,
      ),
    );
    controller.beginEditing(const SubtitlePositionTarget.video());
  });

  tearDown(() => controller.dispose());

  test('several moves in one frame publish once and the last one commits', () {
    expect(
      controller.pointerDown(pointer: 1, local: const Offset(60, 70)),
      isTrue,
    );
    controller.pointerMove(pointer: 1, local: const Offset(70, 70));
    controller.pointerMove(pointer: 1, local: const Offset(90, 80));
    expect(frames, hasLength(1));
    expect(controller.draftOrigin, isNull);
    frames.single(Duration.zero);
    expect(controller.draftOrigin, const Offset(70, 60));
    SubtitlePlacement? committed;
    controller.onCommit = (target, placement) async {
      committed = placement;
    };
    frames.clear();
    controller.pointerMove(pointer: 1, local: const Offset(100, 80));
    final SubtitlePlacement? ended = controller.pointerUp(
      pointer: 1,
      local: const Offset(110, 90),
    );
    expect(ended, isNotNull);
    expect(committed, isNotNull);
    frames.single(Duration.zero);
    expect(controller.draftOrigin, const Offset(90, 70));
    expect(controller.acknowledgePlacement(Alignment.bottomCenter), isFalse);
    expect(controller.acknowledgePlacement(committed!.alignment!), isTrue);
    expect(controller.draftOrigin, isNull);
  });

  test('a press that does not move does not create a placement', () {
    var commits = 0;
    controller.onCommit = (_, _) async => commits++;
    controller.pointerDown(pointer: 3, local: const Offset(60, 70));
    expect(controller.pointerUp(pointer: 3), isNull);
    expect(commits, 0);
  });

  test('an older committed position cannot clear a newer drag draft', () {
    final placements = <Alignment>[];
    controller.onCommit = (_, placement) async =>
        placements.add(placement.alignment!);
    controller.pointerDown(pointer: 1, local: const Offset(60, 70));
    controller.pointerMove(pointer: 1, local: const Offset(100, 90));
    controller.pointerUp(pointer: 1);
    controller.pointerDown(pointer: 2, local: const Offset(60, 70));
    expect(controller.acknowledgePlacement(placements.first), isFalse);
    controller.pointerMove(pointer: 2, local: const Offset(150, 90));
    controller.pointerUp(pointer: 2);
    final latest = controller.draftOrigin;
    expect(controller.acknowledgePlacement(placements.first), isFalse);
    expect(controller.draftOrigin, latest);
    expect(controller.acknowledgePlacement(placements.last), isTrue);
    expect(controller.draftOrigin, isNull);
  });

  test(
    'a draft awaiting its saved layout does not leak into another target',
    () {
      Alignment? placement;
      controller.onCommit = (_, value) async => placement = value.alignment;
      controller.pointerDown(pointer: 1, local: const Offset(60, 70));
      controller.pointerMove(pointer: 1, local: const Offset(100, 90));
      controller.pointerUp(pointer: 1);
      expect(controller.draftOrigin, isNotNull);
      controller.beginEditing(const SubtitlePositionTarget.audio());
      expect(controller.draftOrigin, isNull);
      expect(controller.acknowledgePlacement(placement!), isFalse);
    },
  );

  test('a second pointer cannot take the session', () {
    controller.pointerDown(pointer: 1, local: const Offset(60, 70));
    expect(
      controller.pointerDown(pointer: 2, local: const Offset(10, 10)),
      isFalse,
    );
    controller.pointerMove(pointer: 2, local: const Offset(200, 200));
    expect(frames, isEmpty);
  });

  test('switching target drops the previous pointer', () {
    var commits = 0;
    controller.onCommit = (target, _) async {
      commits++;
      expect(target.channel, SubtitlePositionChannel.video);
    };
    controller.pointerDown(pointer: 1, local: const Offset(60, 70));
    controller.pointerMove(pointer: 1, local: const Offset(120, 70));
    controller.beginEditing(
      const SubtitlePositionTarget.preset(
        channel: SubtitlePositionChannel.audio,
        id: '清幕标准',
      ),
    );
    expect(commits, 1);
    controller.pointerMove(pointer: 1, local: const Offset(180, 70));
    expect(controller.dragging, isFalse);
  });
}
