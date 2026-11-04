import 'package:integration_test/integration_test.dart';
import '../test/music_lyric_motion_test.dart' as motion;
import '../test/music_lyric_desktop_scroll_test.dart' as desktop;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  motion.main();
  desktop.main();
}
