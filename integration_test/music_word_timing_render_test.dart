import 'package:integration_test/integration_test.dart';
import '../test/music_word_timing_render_test.dart' as regression;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  regression.main();
}
