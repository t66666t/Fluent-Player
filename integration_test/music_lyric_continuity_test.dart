import 'package:integration_test/integration_test.dart';
import '../test/music_lyric_depth_transition_test.dart' as depth;
import '../test/music_lyric_motion_test.dart' as motion;
import '../test/music_lyric_desktop_scroll_test.dart' as desktop;
import '../test/music_lyric_spatial_focus_test.dart' as spatial;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  depth.main();
  motion.main();
  desktop.main();
  spatial.main();
}
