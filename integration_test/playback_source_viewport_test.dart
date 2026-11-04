import 'package:integration_test/integration_test.dart';

import '../test/playback_source_viewport_test.dart' as viewport_regressions;

/// The same first-frame assertions on a native Flutter surface. Player pages
/// are stand-ins: decoder/texture handoff retains its separate regression suite.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  viewport_regressions.main();
}
