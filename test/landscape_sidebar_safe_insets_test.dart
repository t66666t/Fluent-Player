import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/landscape_sidebar_safe_insets.dart';

void main() {
  test('right sidebar avoids the larger gesture or cutout inset', () {
    final padding = resolveLandscapeSidebarSafePadding(
      viewPadding: const EdgeInsets.only(right: 8),
      systemGestureInsets: const EdgeInsets.only(right: 28),
      isLeftHandedMode: false,
    );
    expect(padding, const EdgeInsets.only(right: 28));
  });

  test('left-handed sidebar applies the inset to the left edge only', () {
    final padding = resolveLandscapeSidebarSafePadding(
      viewPadding: const EdgeInsets.only(left: 36, right: 7),
      systemGestureInsets: const EdgeInsets.only(left: 20, right: 30),
      isLeftHandedMode: true,
    );
    expect(padding, const EdgeInsets.only(left: 36));
  });
}
