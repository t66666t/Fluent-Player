import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A local presentation preference, independent of media and model settings.
class ExperimentalLayout extends ValueNotifier<bool> {
  ExperimentalLayout._() : super(false);
  static final instance = ExperimentalLayout._();
  static const preferenceKey = 'experimentalLayoutV1';
  Future<void>? _loading;
  Future<void> initialize() => _loading ??= _load();
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getBool(preferenceKey) ?? false;
  }

  Future<void> select(bool enabled) async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(preferenceKey, enabled);
    value = enabled;
  }
}
