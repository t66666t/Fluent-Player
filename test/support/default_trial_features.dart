import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/services/app_default_settings_trial.dart';

/// Keep existing core/journal tests isolated from the user's feature storage.
/// Real JSON/SQLite/network round trips have their own integration fixture.
class MemoryTrialFeatures implements DefaultTrialFeatureStore {
  Map<String, dynamic> values = {'original': true};
  bool failApply = false, failRestore = false;
  int reloads = 0;
  @override
  Future<void> flush() async {}
  @override
  Future<Map<String, dynamic>> capture() async => Map.of(values);
  @override
  Future<void> apply(DefaultSettingsDevice device) async {
    values = {
      'model': RecommendedAppDefaults.modelValues(device),
      'cache': RecommendedAppDefaults.cacheValues(device),
      'podcasts': RecommendedAppDefaults.podcastValues(device),
    };
    if (failApply) throw StateError('feature apply failed');
  }

  @override
  Future<void> restore(Map<String, dynamic> snapshot) async {
    if (failRestore) throw StateError('feature restore failed');
    values = Map.of(snapshot);
  }

  @override
  Future<void> reloadRuntime() async {
    reloads++;
  }
}
