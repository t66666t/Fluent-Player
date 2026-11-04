import 'package:integration_test/integration_test.dart';

import '../test/cloud_drive_accounts_test.dart' as accounts;
import '../test/cloud_drive_browser_controller_test.dart' as browser;
import '../test/cloud_drive_gateway_test.dart' as gateway;
import '../test/cloud_drive_models_test.dart' as models;
import '../test/cloud_drive_providers_test.dart' as providers;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  models.main();
  accounts.main();
  providers.main();
  browser.main();
  gateway.main();
}
