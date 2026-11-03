// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json;
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/foundation.dart'
    show compute, debugPrint, listEquals, visibleForTesting;
import 'package:path/path.dart' as path;
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const String _defaultFileName = 'shared_preferences';

const String _defaultPrefix = 'flutter.';

/// The Windows implementation of [SharedPreferencesStorePlatform].
///
/// This class implements the `package:shared_preferences` functionality for Windows.
class SharedPreferencesWindows extends SharedPreferencesStorePlatform {
  /// Deprecated instance of [SharedPreferencesWindows].
  /// Use [SharedPreferencesStorePlatform.instance] instead.
  @Deprecated('Use `SharedPreferencesStorePlatform.instance` instead.')
  static SharedPreferencesWindows instance = SharedPreferencesWindows();

  /// Registers the Windows implementation.
  static void registerWith() {
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows();
    // A temporary work-around for having two plugins contained in a single package.
    SharedPreferencesAsyncWindows.registerWith();
  }

  /// Local copy of preferences
  Map<String, Object>? _cachedPreferences;

  Future<void> _mutations = Future<void>.value();

  /// Commit a complete preference change in one durable file replacement.
  /// Keys use the platform prefix, as in [setValue]; null removes a key.
  /// Only successful commits become visible through getAll/reload.
  Future<bool> setValues(Map<String, Object?> values) {
    final updates = Map<String, Object?>.from(values);
    final operation = _mutations.then((_) async {
      final next = Map<String, Object>.from(await _readPreferences());
      var changed = false;
      for (final entry in updates.entries) {
        final value = entry.value;
        if (value == null) {
          if (next.containsKey(entry.key)) {
            next.remove(entry.key);
            changed = true;
          }
        } else {
          final previous = next[entry.key];
          if (previous == value ||
              (previous is List &&
                  value is List &&
                  listEquals(previous, value))) {
            continue;
          }
          next[entry.key] =
              value is List<String> ? List<String>.of(value) : value;
          changed = true;
        }
      }
      if (!changed) return true;
      final saved = await _writePreferences(
        next,
        _defaultFileName,
        fs: fs,
        pathProvider: pathProvider,
      );
      if (saved) _cachedPreferences = next;
      return saved;
    });
    _mutations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// File system used to store to disk. Exposed for testing only.
  @visibleForTesting
  FileSystem fs = const LocalFileSystem();

  /// The path_provider_windows instance used to find the support directory.
  @visibleForTesting
  PathProviderWindows pathProvider = PathProviderWindows();

  /// Checks for cached preferences and returns them or loads preferences from
  /// file and returns and caches them.
  Future<Map<String, Object>> _readPreferences() async {
    _cachedPreferences ??= await _readFromFile(
      _defaultFileName,
      fs: fs,
      pathProvider: pathProvider,
    );
    return _cachedPreferences!;
  }

  @override
  Future<bool> clear() async {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<bool> clearWithPrefix(String prefix) async {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: prefix)),
    );
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;
    // Queue the key selection too: an earlier write may introduce a key that
    // a subsequently requested clear must remove.
    final operation = _mutations.then((_) async {
      final next = Map<String, Object>.from(await _readPreferences());
      next.removeWhere(
        (String key, _) =>
            key.startsWith(filter.prefix) &&
            (filter.allowList == null || filter.allowList!.contains(key)),
      );
      final saved = await _writePreferences(
        next,
        _defaultFileName,
        fs: fs,
        pathProvider: pathProvider,
      );
      if (saved) _cachedPreferences = next;
      return saved;
    });
    _mutations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) async {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    // Reload must include saves already queued by other settings controls.
    // Otherwise a batch's cache refresh can hide a concurrent successful save.
    // Take a barrier at call time; later background saves must not starve a
    // read by continually extending the queue while it waits.
    await _mutations;
    final PreferencesFilter filter = parameters.filter;
    final Map<String, Object> withPrefix = Map<String, Object>.from(
      await _readPreferences(),
    );
    withPrefix.removeWhere(
      (String key, _) => !(key.startsWith(filter.prefix) &&
          (filter.allowList?.contains(key) ?? true)),
    );
    return withPrefix;
  }

  @override
  Future<bool> remove(String key) async {
    return setValues({key: null});
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    return setValues({key: value});
  }
}

/// The Windows implementation of [SharedPreferencesAsyncPlatform].
///
/// This class implements the `package:shared_preferences` functionality for Windows.
base class SharedPreferencesAsyncWindows
    extends SharedPreferencesAsyncPlatform {
  /// Registers the Windows implementation.
  static void registerWith() {
    SharedPreferencesAsyncPlatform.instance = SharedPreferencesAsyncWindows();
  }

  /// Local copy of preferences
  Map<String, Object>? _cachedPreferences;

  /// File system used to store to disk. Exposed for testing only.
  @visibleForTesting
  FileSystem fs = const LocalFileSystem();

  /// The path_provider_windows instance used to find the support directory.
  @visibleForTesting
  PathProviderWindows pathProvider = PathProviderWindows();

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    return (await getPreferences(parameters, options)).keys.toSet();
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setInt(String key, int value, SharedPreferencesOptions options) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as String?;
  }

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as bool?;
  }

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as double?;
  }

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as int?;
  }

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return (data[key] as List<Object?>?)?.cast<String>().toList();
  }

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    final PreferencesFilters filter = parameters.filter;
    final Map<String, Object> preferences = await _readPreferences(
      windowsOptions.fileName,
    );
    preferences.removeWhere(
      (String key, _) =>
          filter.allowList == null || filter.allowList!.contains(key),
    );
    await _writePreferences(
      preferences,
      windowsOptions.fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    return _readAll(parameters.filter.allowList, options);
  }

  /// Reloads preferences from file.
  @visibleForTesting
  Future<void> reload(SharedPreferencesWindowsOptions options) async {
    _cachedPreferences = await _readFromFile(options.fileName);
  }

  Future<Map<String, Object>> _readAll(
    Set<String>? allowList,
    SharedPreferencesOptions options,
  ) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    final Map<String, Object> prefs = Map<String, Object>.from(
      await _readPreferences(windowsOptions.fileName),
    );
    prefs.removeWhere((String key, _) => !(allowList?.contains(key) ?? true));
    return prefs;
  }

  Future<void> _setValue(
    String key,
    Object value,
    SharedPreferencesOptions options,
  ) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    final Map<String, Object> preferences = await _readPreferences(
      windowsOptions.fileName,
    );
    preferences[key] = value;
    await _writePreferences(
      preferences,
      windowsOptions.fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
  }

  /// Checks for cached preferences and returns them or loads preferences from
  /// file and returns and caches them.
  Future<Map<String, Object>> _readPreferences(String fileName) async {
    _cachedPreferences ??= await _readFromFile(
      fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
    return _cachedPreferences!;
  }
}

/// Gets the file where the preferences are stored.
Future<File?> _getLocalDataFile(
  String fileName, {
  FileSystem fs = const LocalFileSystem(),
  PathProviderWindows? pathProvider,
}) async {
  pathProvider = pathProvider ?? PathProviderWindows();
  final String? directory = await pathProvider.getApplicationSupportPath();
  if (directory == null) {
    return null;
  }
  final String fileLocation = path.join(directory, '$fileName.json');
  return fs.file(fileLocation);
}

/// Gets the preferences from the stored file.
Future<Map<String, Object>> _readFromFile(
  String fileName, {
  FileSystem fs = const LocalFileSystem(),
  PathProviderWindows? pathProvider,
}) async {
  Map<String, Object> preferences = <String, Object>{};
  final File? localDataFile = await _getLocalDataFile(
    fileName,
    fs: fs,
    pathProvider: pathProvider,
  );
  if (localDataFile != null && fs is LocalFileSystem) {
    return compute(_readLocalPreferences, localDataFile.path);
  }
  if (localDataFile != null && await localDataFile.exists()) {
    final String stringMap = await localDataFile.readAsString();
    if (stringMap.isNotEmpty) {
      final Object? data = await compute(json.decode, stringMap);
      if (data is Map) {
        preferences = data.cast<String, Object>();
      }
    }
  }
  return preferences;
}

/// Writes the cached preferences to disk. Returns [true] if the operation
/// succeeded.
final _fileWrites = <String, Future<bool>>{};

Future<bool> _writePreferences(
  Map<String, Object> preferences,
  String fileName, {
  FileSystem fs = const LocalFileSystem(),
  PathProviderWindows? pathProvider,
}) async {
  try {
    final File? localDataFile = await _getLocalDataFile(
      fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
    if (localDataFile == null) {
      debugPrint('Unable to determine where to write preferences.');
      return false;
    }
    final snapshot = Map<String, Object>.from(preferences);
    final key = localDataFile.path;
    final previous = _fileWrites[key] ?? Future<bool>.value(true);
    final write = previous.then((_) async {
      try {
        if (fs is LocalFileSystem) {
          await compute(_writeLocalPreferences, (key, snapshot));
        } else {
          await localDataFile.parent.create(recursive: true);
          final encoded = await compute(json.encode, snapshot);
          await localDataFile.writeAsString(encoded, flush: true);
        }
        return true;
      } catch (e) {
        debugPrint('Error saving preferences to disk: $e');
        return false;
      }
    });
    _fileWrites[key] = write;
    try {
      return await write;
    } finally {
      if (identical(_fileWrites[key], write)) _fileWrites.remove(key);
    }
  } catch (e) {
    debugPrint('Error saving preferences to disk: $e');
    return false;
  }
}

// Run the complete JSON/UTF-8/file operation in a worker. Merely using an async
// File method still performs substantial JSON/string work on the UI isolate.
Map<String, Object> _readLocalPreferences(String location) {
  final file = io.File(location);
  if (!file.existsSync()) return {};
  final encoded = file.readAsStringSync();
  if (encoded.isEmpty) return {};
  final data = json.decode(encoded);
  return data is Map ? Map<String, Object>.from(data) : {};
}

void _writeLocalPreferences((String, Map<String, Object>) request) {
  final (location, preferences) = request;
  final file = io.File(location);
  file.parent.createSync(recursive: true);
  final temporary = io.File('$location.tmp');
  try {
    temporary.writeAsStringSync(json.encode(preferences), flush: true);
    temporary.renameSync(location);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

/// Windows specific SharedPreferences Options.
class SharedPreferencesWindowsOptions extends SharedPreferencesOptions {
  /// Constructor for SharedPreferencesWindowsOptions.
  const SharedPreferencesWindowsOptions({
    this.fileName = 'shared_preferences', // Same as current defaults.
  });

  /// The name of the file to store preferences in.
  final String fileName;

  /// Returns a new instance of [SharedPreferencesWindowsOptions] from an existing
  /// [SharedPreferencesOptions].
  static SharedPreferencesWindowsOptions fromSharedPreferencesOptions(
    SharedPreferencesOptions options,
  ) {
    if (options is SharedPreferencesWindowsOptions) {
      return options;
    }
    return const SharedPreferencesWindowsOptions();
  }
}
