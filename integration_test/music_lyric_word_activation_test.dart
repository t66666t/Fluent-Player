import 'package:integration_test/integration_test.dart';
import '../test/music_lyric_word_activation_test.dart' as words;
import '../test/music_lyric_spatial_focus_test.dart' as spatial;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  words.main();
  spatial.main();
}
