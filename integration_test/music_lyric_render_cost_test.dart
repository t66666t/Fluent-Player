import 'package:integration_test/integration_test.dart';
import '../test/music_lyric_render_cost_test.dart' as render_cost;
import '../test/music_lyric_motion_test.dart' as motion;
import '../test/music_lyric_desktop_scroll_test.dart' as desktop;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  render_cost.main();
  motion.main();
  desktop.main();
}
