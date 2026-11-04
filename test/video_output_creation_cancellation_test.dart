import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _Platform extends Fake implements PlatformPlayer {
  @override
  bool isVideoControllerAttached = false;
  @override
  final videoControllerCompleter = Completer<void>();
}

class _Player extends Fake implements Player {
  @override
  final _Platform platform = _Platform();
}

void main() {
  testWidgets(
    'cancelling before a Flutter frame releases the native creation gate',
    (tester) async {
      final player = _Player();
      final output = VideoController(player);
      final failed = expectLater(output.platform.future, throwsStateError);
      expect(player.platform.videoControllerCompleter.isCompleted, isFalse);
      output.cancelPendingCreation();
      await failed;
      expect(player.platform.videoControllerCompleter.isCompleted, isTrue);
      await tester.pump();
      expect(output.notifier.value, isNull);
      output.cancelPendingCreation();
    },
  );
}
