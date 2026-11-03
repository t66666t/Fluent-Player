import 'package:integration_test/integration_test.dart';

import '../test/music_lyric_desktop_scroll_test.dart' as regression;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  regression.main();
}
