import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'support/default_trial_features.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The plugin exposes its path-provider instance for storage tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/default_settings_trial.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';

class _Paths extends PathProviderWindows {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

class _CountingStore extends SharedPreferencesWindows {
  final batchSizes = <int>[];
  @override
  Future<bool> setValues(Map<String, Object?> values) {
    batchSizes.add(values.length);
    return super.setValues(values);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _CountingStore backend;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('windows_prefs_trial_');
    backend = _CountingStore()..pathProvider = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = backend;
    SettingsService().resetForTest();
    SettingsService().featureSettingsForTrial = MemoryTrialFeatures();
    SubtitleDebugSession.instance.resetForTest();
  });
  tearDown(() async {
    SettingsService().resetForTest();
    SubtitleDebugSession.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test(
    'batched writes preserve types, removals, unrelated keys and file format',
    () async {
      expect(
        await backend.setValues({
          'flutter.original': '保留',
          'flutter.remove': 17,
          'other.prefix': 'keep',
        }),
        true,
      );
      expect(
        await backend.setValues({
          'flutter.remove': null,
          'flutter.bool': false,
          'flutter.int': 7,
          'flutter.double': 2.5,
          'flutter.list': ['中文', 'English'],
        }),
        true,
      );
      final reopened = SharedPreferencesWindows()
        ..pathProvider = _Paths(directory.path);
      expect(await reopened.getAll(), {
        'flutter.original': '保留',
        'flutter.bool': false,
        'flutter.int': 7,
        'flutter.double': 2.5,
        'flutter.list': ['中文', 'English'],
      });
      final disk = jsonDecode(
        await File('${directory.path}/shared_preferences.json').readAsString(),
      );
      expect(disk['other.prefix'], 'keep');
      expect(
        File('${directory.path}/shared_preferences.json.tmp').existsSync(),
        false,
      );
    },
  );

  test(
    'interleaved saves and clear serialize without dropping unrelated changes',
    () async {
      final writes = [
        backend.setValue('String', 'flutter.before', 'first'),
        backend.setValues({'flutter.one': 1, 'flutter.two': 2}),
        backend.remove('flutter.one'),
        backend.clear(),
        backend.setValue('String', 'flutter.after', 'last'),
        backend.setValues({'flutter.final': true, 'other.prefix': 42}),
      ];
      final duringWriteRead = backend.getAll();
      expect(await Future.wait(writes), everyElement(true));
      expect(await duringWriteRead, {
        'flutter.after': 'last',
        'flutter.final': true,
      });
      expect(await backend.getAll(), {
        'flutter.after': 'last',
        'flutter.final': true,
      });
      final disk = jsonDecode(
        await File('${directory.path}/shared_preferences.json').readAsString(),
      );
      expect(disk['other.prefix'], 42);
    },
  );

  test(
    'failed writes leave the original file and committed cache intact; retry succeeds',
    () async {
      await backend.setValues({'flutter.original': 'safe'});
      final path = '${directory.path}/shared_preferences.json';
      final original = await File(path).readAsBytes();
      final obstruction = await Directory('$path.tmp').create();
      expect(
        await backend.setValues({
          'flutter.original': 'bad',
          'flutter.new': true,
        }),
        false,
      );
      expect(await backend.getAll(), {'flutter.original': 'safe'});
      expect(await File(path).readAsBytes(), original);
      await obstruction.delete();
      expect(await backend.setValues({'flutter.new': true}), true);
      final reopened = SharedPreferencesWindows()
        ..pathProvider = _Paths(directory.path);
      expect(await reopened.getAll(), {
        'flutter.original': 'safe',
        'flutter.new': true,
      });
    },
  );

  test(
    '38 MB preferences stay responsive and a real trial uses one scoped batch',
    () async {
      // Synthetic history only: never copy or alter the user's actual settings.
      final history = List.filled(
        1000000,
        '{"text":"字幕text\\n","value":42},',
      ).join();
      var ticks = 0;
      var maximumGap = Duration.zero;
      var previous = DateTime.now();
      final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final now = DateTime.now();
        final gap = now.difference(previous);
        if (gap > maximumGap) maximumGap = gap;
        previous = now;
        ticks++;
      });
      addTearDown(timer.cancel);
      final elapsed = Stopwatch()..start();
      expect(
        await backend.setValues({
          'flutter.syntheticHistory': history,
          'other.prefix': 'unrelated',
        }),
        true,
      );
      expect(
        ticks,
        greaterThan(0),
        reason: 'UI event queue must run during encoding and disk I/O',
      );
      final path = '${directory.path}/shared_preferences.json';
      expect(await File(path).length(), greaterThan(38 * 1000 * 1000));
      final reopened = SharedPreferencesWindows()
        ..pathProvider = _Paths(directory.path);
      final beforeRead = ticks;
      expect((await reopened.getAll())['flutter.syntheticHistory'], history);
      expect(
        ticks,
        greaterThan(beforeRead),
        reason: 'cold JSON loading also belongs in a worker',
      );
      final settings = SettingsService();
      await settings.init();
      await settings.saveSubtitleTextStyle(
        const SubtitleTextStyle(textColor: Colors.amber, borderWidth: 2.3),
      );
      final preferences = await SharedPreferences.getInstance();
      final original = {
        for (final key in SettingsService.defaultTrialPreferenceKeys)
          key: preferences.get(key),
      };
      backend.batchSizes.clear();
      final beforeTrial = ticks;
      final activationStarted = elapsed.elapsedMilliseconds;
      await settings.defaultSettingsTrial.toggle();
      final activationMs = elapsed.elapsedMilliseconds - activationStarted;
      expect(
        backend.batchSizes,
        hasLength(5),
        reason: 'two backups, two phases, one complete settings batch',
      );
      expect(backend.batchSizes.where((size) => size > 1), hasLength(1));
      expect(ticks, greaterThan(beforeTrial));
      expect(settings.subtitleLayoutLandscape.adaptiveSizing, false);
      // An unrelated save between activation and restoration must survive.
      await preferences.setString('duringTrial', 'keep');
      backend.batchSizes.clear();
      final restorationStarted = elapsed.elapsedMilliseconds;
      await settings.defaultSettingsTrial.toggle();
      final restorationMs = elapsed.elapsedMilliseconds - restorationStarted;
      expect(backend.batchSizes, hasLength(5));
      expect(settings.defaultSettingsTrial.hasBackup, false);
      expect({
        for (final key in SettingsService.defaultTrialPreferenceKeys)
          key: preferences.get(key),
      }, original);
      final finalStore = SharedPreferencesWindows()
        ..pathProvider = _Paths(directory.path);
      final finalDisk = await finalStore.getAll();
      expect(finalDisk['flutter.syntheticHistory'], history);
      expect(finalDisk['flutter.duringTrial'], 'keep');
      expect(
        finalDisk.keys.where((key) => key.contains('defaultSettingsTrial.')),
        isEmpty,
      );
      expect(settings.subtitleTextStyle.borderWidth, 2.3);
      // Record measurements without making CI depend on disk/CPU speed.
      // ignore: avoid_print
      print(
        'Windows preferences benchmark: ${await File(path).length()} bytes, '
        '${elapsed.elapsedMilliseconds} ms total, $ticks UI pulses, '
        '$activationMs ms activation, $restorationMs ms restoration, '
        '${maximumGap.inMilliseconds} ms largest event gap',
      );
      timer.cancel();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'existing v1 recovery records still restore after switching the Windows backend',
    () async {
      final settings = SettingsService();
      await settings.init();
      final original = settings.exportSettingsSnapshot()['subtitles'];
      await settings.defaultSettingsTrial.toggle();
      final journal = settings.defaultSettingsTrial.journal;
      await journal.setPhase((await journal.read())!, 'restoring');
      settings.resetForTest();
      SubtitleDebugSession.instance.resetForTest();
      final reopened = _CountingStore()..pathProvider = _Paths(directory.path);
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = reopened;
      await settings.init();
      expect(settings.defaultSettingsTrial.hasBackup, false);
      expect(settings.exportSettingsSnapshot()['subtitles'], original);
      expect(
        (await reopened.getAll()).keys,
        isNot(contains('flutter.${DefaultSettingsTrialJournal.originalKey}')),
      );
    },
  );
}
