import 'package:integration_test/integration_test.dart';

import '../test/podcast_channel_scroll_performance_test.dart' as regression;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  regression.main(profile: true);
}
