import 'package:integration_test/integration_test.dart';

import '../test/music_lyric_mobile_performance_test.dart' as mobile;
import '../test/music_lyric_spatial_focus_test.dart' as focus;
import '../test/music_lyric_word_activation_test.dart' as activation;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  mobile.main();
  focus.main();
  activation.main();
}
