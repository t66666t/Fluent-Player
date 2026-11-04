import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/app_storage_service.dart';

/// Only resolves native paths and reads existing records. Never starts the app
/// services, writes preferences, initializes a library, or moves any user data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'friendly Windows display name retains installed storage identity',
    (tester) async {
      final locations = await StorageLocations.system();
      final expectedSupport = p.join(
        Platform.environment['APPDATA']!,
        'com.example',
        'Fluent_Player',
      );
      expect(
        p.equals(locations.support.path, expectedSupport),
        isTrue,
        reason:
            'CompanyName/ProductName form the installed preference namespace',
      );

      const expectedData = String.fromEnvironment(
        'FLUENT_VERIFY_EXISTING_DATA_ROOT',
      );
      if (expectedData.isEmpty) return;
      final preferences =
          jsonDecode(
                await File(
                  p.join(locations.support.path, 'shared_preferences.json'),
                ).readAsString(),
              )
              as Map;
      final configured =
          preferences['flutter.largeDataRootPath'] ??
          preferences['largeDataRootPath'];
      expect(configured, isA<String>());
      expect(
        p.equals(p.normalize(configured as String), p.normalize(expectedData)),
        isTrue,
      );
      final layout =
          await readStorageJson(
                File(p.join(locations.support.path, 'storage', 'layout.json')),
              )
              as Map;
      expect(
        p.equals(
          p.normalize(layout['dataRoot'] as String),
          p.normalize(expectedData),
        ),
        isTrue,
      );
      final library =
          await readStorageJson(
                File(p.join(layout['dataRoot'] as String, 'library.json')),
              )
              as Map;
      expect(
        library['videos'],
        isNotEmpty,
        reason:
            'The existing library must be read instead of the new empty default',
      );
      // Counts are diagnostic; private media titles and account values stay local.
      // ignore: avoid_print
      print(
        'Existing library verified: ${(library['videos'] as List).length} videos, '
        '${(library['collections'] as List).length} collections.',
      );
    },
    skip: !Platform.isWindows,
  );
}
