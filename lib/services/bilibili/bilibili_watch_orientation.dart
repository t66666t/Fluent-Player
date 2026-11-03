import 'package:flutter/services.dart';

/// The screen orientation the Bilibili loading page asks for on a phone
/// when the landscape playback page comes next, made the way that page
/// makes it, so the switch between the two turns nothing.
class BilibiliWatchOrientation {
  const BilibiliWatchOrientation();

  /// What the landscape playback page asks for when it opens.
  Future<void> requestLandscape() =>
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

  /// What the playback page does when it is left: the orientation follows
  /// the device again, as before the video was tapped.
  Future<void> restore() =>
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
}
