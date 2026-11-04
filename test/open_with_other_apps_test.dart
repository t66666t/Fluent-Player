import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/open_with_other_apps.dart';

void main() {
  test('Android opens the exported file itself', () {
    const String output = '/storage/ABCD-1234/Movies/clip_compose_1.mp4';
    final ExternalOpenPlan plan = planExternalOpen(
      path: output,
      isAndroid: true,
      isIOS: false,
    );
    expect(plan.strategy, ExternalOpenStrategy.openFileDirectly);
    expect(plan.path, output);
  });

  test('iOS opens the exported file itself', () {
    const String output =
        '/var/mobile/Containers/Data/Application/x/Documents/ComposedVideos/clip.mp4';
    final ExternalOpenPlan plan = planExternalOpen(
      path: output,
      isAndroid: false,
      isIOS: true,
    );
    expect(plan.strategy, ExternalOpenStrategy.openFileDirectly);
    expect(plan.path, output);
  });

  test('desktop reveals the exported file instead of sharing it', () {
    const String output = r'C:\Videos\clip_compose_1.mp4';
    final ExternalOpenPlan plan = planExternalOpen(
      path: output,
      isAndroid: false,
      isIOS: false,
    );
    expect(plan.strategy, ExternalOpenStrategy.revealInFileManager);
    expect(plan.path, output);
  });
}
