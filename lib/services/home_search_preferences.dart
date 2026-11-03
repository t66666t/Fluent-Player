import 'package:shared_preferences/shared_preferences.dart';

import '../models/home_search_request.dart';

class HomeSearchPreferences {
  const HomeSearchPreferences(this.preferences);
  final SharedPreferences preferences;
  static const scopeKey = 'homeSearch.lastScope';

  HomeSearchScope get scope =>
      HomeSearchScope.values
          .where((scope) => scope.name == preferences.get(scopeKey))
          .firstOrNull ??
      HomeSearchScope.library;

  Future<bool> select(HomeSearchScope scope) =>
      preferences.setString(scopeKey, scope.name);
}
