import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_position.dart';

void main() {
  test('editing targets stay on their own channel', () {
    expect(
      SubtitlePositionTarget.resolve(ghost: true, audio: true, presetId: '清幕标准'),
      const SubtitlePositionTarget.ghost(),
    );
    expect(
      SubtitlePositionTarget.resolve(
        ghost: false,
        audio: false,
        presetId: '清幕标准',
      ),
      const SubtitlePositionTarget.preset(
        channel: SubtitlePositionChannel.video,
        id: '清幕标准',
      ),
    );
    expect(
      SubtitlePositionTarget.resolve(
        ghost: false,
        audio: true,
        presetId: '清幕标准',
      ).isAudio,
      isTrue,
    );
    expect(
      SubtitlePositionTarget.resolve(ghost: false, audio: true, presetId: null),
      const SubtitlePositionTarget.audio(),
    );
    expect(
      SubtitlePositionTarget.resolve(ghost: false, audio: false, presetId: ''),
      const SubtitlePositionTarget.video(),
    );
  });

  test('old compose jobs without a placement keep preset default', () {
    expect(
      SubtitlePlacementSnapshot.parse(null).kind,
      SubtitlePlacementParseKind.absent,
    );
    final SubtitlePlacementSnapshot custom = SubtitlePlacementSnapshot.custom(
      const Alignment(-0.25, 0.4),
    );
    final SubtitlePlacementParse restored = SubtitlePlacementSnapshot.parse(
      custom.toJson(),
    );
    expect(restored.snapshot!.alignment!.x, closeTo(-0.25, 1e-9));
    expect(
      SubtitlePlacementSnapshot.parse(<String, dynamic>{
        'version': 1,
        'mode': 'presetDefault',
      }).snapshot!.isCustom,
      isFalse,
    );
    expect(
      SubtitlePlacementSnapshot.parse(<String, dynamic>{
        'version': 4,
        'mode': 'customAlignment',
        'x': 0,
        'y': 0,
      }).kind,
      SubtitlePlacementParseKind.unrecognized,
    );
  });
}
