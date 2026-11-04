import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/device_form_factor.dart';

void main() {
  const portrait = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];
  const landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
  const all = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  test('phone library and portrait player stay portrait', () {
    for (final surface in <AppOrientationSurface>[
      AppOrientationSurface.mediaLibrary,
      AppOrientationSurface.portraitPlayer,
    ]) {
      expect(
        DeviceFormFactor.preferredOrientations(
          surface: surface,
          isMobile: true,
          isTablet: false,
        ),
        portrait,
      );
    }
  });

  test('tablet library and portrait player follow the display', () {
    for (final surface in <AppOrientationSurface>[
      AppOrientationSurface.mediaLibrary,
      AppOrientationSurface.portraitPlayer,
    ]) {
      expect(
        DeviceFormFactor.preferredOrientations(
          surface: surface,
          isMobile: true,
          isTablet: true,
        ),
        all,
      );
    }
  });

  test('landscape player requests landscape on phones and tablets', () {
    for (final isTablet in <bool>[false, true]) {
      expect(
        DeviceFormFactor.preferredOrientations(
          surface: AppOrientationSurface.landscapePlayer,
          isMobile: true,
          isTablet: isTablet,
        ),
        landscape,
      );
    }
  });

  test('desktop and web defer orientation to the platform', () {
    for (final surface in AppOrientationSurface.values) {
      expect(
        DeviceFormFactor.preferredOrientations(
          surface: surface,
          isMobile: false,
          isTablet: false,
        ),
        isEmpty,
      );
    }
  });
}
