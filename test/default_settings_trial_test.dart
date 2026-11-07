import 'dart:async';
import 'dart:convert';
import 'support/default_trial_features.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the plugin's speculative cache as well as durable write failures.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/recommended_subtitle_defaults.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/default_settings_trial.dart';
import 'package:video_player_app/services/media_library_navigation.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/default_settings_trial_action.dart';

class _MemoryBackend implements TrialPreferenceBackend {
  final values = <String, String>{};
  String? failWrite, failRemove;
  Completer<void>? gate;
  @override
  Future<void> refresh() async {}
  @override
  String? read(String key) => values[key];
  @override
  Future<bool> write(String key, String value) async {
    if (key == failWrite) return false;
    if (key == DefaultSettingsTrialJournal.originalKey && gate != null) {
      await gate!.future;
    }
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    if (key == failRemove) return false;
    values.remove(key);
    return true;
  }
}

class _Fixture {
  final backend = _MemoryBackend();
  Map<String, dynamic> current = {
    'size': 33,
    'ghostSize': 47,
    'enabled': false,
    'nullable': null,
  };
  late final journal = DefaultSettingsTrialJournal(() async => backend);
  int captures = 0, applies = 0, restores = 0;
  bool failApply = false, failRestore = false;
  DefaultSettingsTrial controller() => DefaultSettingsTrial(
    journal: journal,
    captureOriginal: () async {
      captures++;
      return Map.of(current);
    },
    applyRecommended: () async {
      applies++;
      current = {'size': 40, 'ghostSize': 40, 'enabled': true};
      if (failApply) throw StateError('apply failed');
    },
    restoreOriginal: (original) async {
      restores++;
      if (failRestore) throw StateError('restore failed');
      current = Map.of(original);
    },
  );
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  String? failSetKey, failRemoveKey;
  Completer<void>? styleWriteGate;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('subtitleTextStyle') && styleWriteGate != null) {
      await styleWriteGate!.future;
    }
    return key.endsWith(failSetKey ?? '\u0000')
        ? false
        : super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async =>
      key.endsWith(failRemoveKey ?? '\u0000') ? false : super.remove(key);
}

Map<String, dynamic> _rawScope(SharedPreferences preferences) => {
  for (final key in SettingsService.defaultTrialPreferenceKeys)
    key: preferences.get(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubtitleDebugSession.instance.resetForTest();
    SettingsService().resetForTest();
    SettingsService().featureSettingsForTrial = MemoryTrialFeatures();
    SettingsService().subtitlePresets = [];
  });

  test(
    'fresh startup opens the folder root after a saved page visit',
    () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.mediaLibraryRestoreLastPage, isFalse);
      expect(settings.mediaLibraryStartupEntry, 'folders');
      await settings.saveMediaLibraryRootChoice('recent');
      await settings.saveMediaLibraryLastFolder('nested');
      settings.resetForTest();
      await settings.init();

      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: settings.mediaLibraryRootEntry,
        userChosen: settings.mediaLibraryRootEntryUserChosen,
        restoreLastPage: settings.mediaLibraryRestoreLastPage,
        startupEntry: settings.mediaLibraryStartupEntry,
        lastFolderId: settings.mediaLibraryLastFolderId,
        availableEntries: MediaLibraryRootEntry.values.toSet(),
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (id) => id == 'nested',
        parentIdOf: (_) => null,
      );
      expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
      expect(plan.folderToOpen, isNull);
      expect(settings.mediaLibraryRootEntry, 'recent');
      expect(settings.mediaLibraryLastFolderId, 'nested');
    },
  );

  test('saved startup settings survive the new install defaults', () async {
    SharedPreferences.setMockInitialValues({
      'mediaLibraryRestoreLastPage': true,
      'mediaLibraryStartupEntry': 'podcasts',
      'mediaLibraryRootEntryOrder': 'recent,folders,continueLearning,podcasts',
    });
    final settings = SettingsService();
    await settings.init();
    expect(settings.mediaLibraryRestoreLastPage, isTrue);
    expect(settings.mediaLibraryStartupEntry, 'podcasts');
    expect(
      settings.mediaLibraryRootEntryOrder,
      'recent,folders,continueLearning,podcasts',
    );
  });

  group('immutable recovery journal', () {
    test('edits during a trial never overwrite either original copy', () async {
      final f = _Fixture(),
          original = <String, dynamic>{
            'size': 33,
            'ghostSize': 47,
            'enabled': false,
            'nullable': null,
          };
      final trial = f.controller();
      expect(await trial.toggle(), DefaultSettingsTrialResult.activated);
      final copies = Map.of(f.backend.values);
      expect(
        copies[DefaultSettingsTrialJournal.originalKey],
        copies[DefaultSettingsTrialJournal.recoveryKey],
      );
      f.current['size'] = 99;
      f.current['extra'] = 'trial edit';
      expect(f.backend.values, copies);
      expect(await trial.toggle(), DefaultSettingsTrialResult.restored);
      expect(f.current, original);
      expect(f.backend.values, isEmpty);
      f.current['size'] = 51;
      await trial.toggle();
      await trial.toggle();
      expect(f.current['size'], 51);
      expect(f.captures, 2);
    });

    test(
      'rapid repeated clicks cannot replace the backup or reverse mid-apply',
      () async {
        final f = _Fixture();
        f.backend.gate = Completer<void>();
        final trial = f.controller();
        final started = trial.toggle();
        await Future<void>.delayed(Duration.zero);
        expect(trial.busy, true);
        expect(await trial.toggle(), isNull);
        expect(f.applies, 0);
        f.backend.gate!.complete();
        await started;
        expect(f.captures, 1);
        expect(f.applies, 1);
        expect(trial.hasBackup, true);
      },
    );

    for (final failureKey in [
      DefaultSettingsTrialJournal.originalKey,
      DefaultSettingsTrialJournal.recoveryKey,
      DefaultSettingsTrialJournal.phaseKey,
    ]) {
      test(
        'no settings are applied before every backup write succeeds: $failureKey',
        () async {
          final f = _Fixture(), trial = _Fixture();
          final controller = f.controller();
          f.backend.failWrite = failureKey;
          await expectLater(controller.toggle(), throwsStateError);
          expect(f.applies, 0);
          expect(f.current, trial.current);
          final originalCopy =
              f.backend.values[DefaultSettingsTrialJournal.originalKey];
          f.backend.failWrite = null;
          if (controller.hasBackup) {
            await controller.toggle();
            expect(f.current, trial.current);
            expect(f.captures, 1);
            expect(f.backend.values, isEmpty);
          }
          if (originalCopy != null) {
            expect(jsonDecode(originalCopy)['version'], 1);
          }
        },
      );
    }

    test('failed application automatically restores original values', () async {
      final f = _Fixture()..failApply = true;
      final original = Map.of(f.current), trial = f.controller();
      await expectLater(trial.toggle(), throwsStateError);
      expect(f.current, original);
      expect(trial.hasBackup, false);
      expect(f.backend.values, isEmpty);
    });

    test(
      'failed rollback retains the immutable backup until a retry succeeds',
      () async {
        final f = _Fixture()
          ..failApply = true
          ..failRestore = true;
        final original = Map.of(f.current), trial = f.controller();
        await expectLater(trial.toggle(), throwsStateError);
        final backup =
            f.backend.values[DefaultSettingsTrialJournal.originalKey];
        expect(trial.hasBackup, true);
        f.failRestore = false;
        await trial.toggle();
        expect(f.current, original);
        expect(jsonDecode(backup!)['version'], 1);
        expect(f.captures, 1);
        expect(f.backend.values, isEmpty);
      },
    );

    test(
      'active trials survive restart and still restore the first original',
      () async {
        final f = _Fixture(),
            original = Map<String, dynamic>.of(_Fixture().current);
        await f.controller().toggle();
        f.current['size'] = 77;
        final reopened = f.controller();
        await reopened.initialize();
        expect(reopened.hasBackup, true);
        expect(f.current['size'], 77);
        await reopened.toggle();
        expect(f.current, original);
        expect(f.captures, 1);
      },
    );

    for (final phase in [null, 'applying', 'restoring']) {
      test('interrupted phase $phase recovers at startup', () async {
        final f = _Fixture(),
            original = Map<String, dynamic>.of(_Fixture().current);
        final backup = await f.journal.saveOriginal(original);
        if (phase != null) await f.journal.setPhase(backup, phase);
        f.current = {'size': 1};
        final reopened = f.controller();
        await reopened.initialize();
        expect(f.current, original);
        expect(reopened.hasBackup, false);
        expect(f.captures, 0);
        expect(f.backend.values, isEmpty);
      });
    }

    test('the recovery copy tolerates a corrupt primary', () async {
      final f = _Fixture(),
          original = Map<String, dynamic>.of(_Fixture().current);
      await f.controller().toggle();
      f.backend.values[DefaultSettingsTrialJournal.originalKey] = '{damaged';
      final reopened = f.controller();
      await reopened.initialize();
      expect(reopened.hasBackup, true);
      await reopened.toggle();
      expect(f.current, original);
    });

    for (final badRecord in ['{broken', '{"version":2,"payload":"{}"}']) {
      test(
        'unreadable/newer backups are preserved and cannot be overwritten: $badRecord',
        () async {
          final f = _Fixture();
          f.backend.values[DefaultSettingsTrialJournal.originalKey] = badRecord;
          f.backend.values[DefaultSettingsTrialJournal.recoveryKey] = badRecord;
          final trial = f.controller();
          await trial.initialize();
          expect(trial.hasBackup, true);
          expect(trial.error, isNotNull);
          await expectLater(trial.toggle(), throwsFormatException);
          expect(f.captures, 0);
          expect(f.applies, 0);
          expect(
            f.backend.values[DefaultSettingsTrialJournal.originalKey],
            badRecord,
          );
        },
      );
    }

    test(
      'cleanup failure keeps a recoverable entry after settings were restored',
      () async {
        final f = _Fixture(),
            original = Map<String, dynamic>.of(_Fixture().current);
        final trial = f.controller();
        await trial.toggle();
        f.backend.failRemove = DefaultSettingsTrialJournal.recoveryKey;
        await expectLater(trial.toggle(), throwsStateError);
        expect(f.current, original);
        expect(trial.hasBackup, true);
        f.backend.failRemove = null;
        await trial.toggle();
        expect(f.current, original);
        expect(f.backend.values, isEmpty);
      },
    );
  });

  test(
    'legacy subtitle-only v1 backup restores without changing other preferences',
    () async {
      final settings = SettingsService();
      await settings.init();
      final preferences = await SharedPreferences.getInstance();
      final original = settings.exportSettingsSnapshot()['subtitles'];
      final journal = settings.defaultSettingsTrial.journal;
      final saved = await journal.saveOriginal({
        'version': 1,
        'preferences': _rawScope(preferences),
        'runtime': {
          'subtitles': original,
          'avoidPlaybackControlsWithSubtitles':
              settings.avoidPlaybackControlsWithSubtitles,
        },
      });
      await journal.setPhase(saved, 'active');
      await preferences.setString(
        'subtitleTextStyle',
        jsonEncode(RecommendedSubtitleDefaults.textStyle.toJson()),
      );
      await preferences.setDouble('playbackSpeed', 1.8);
      settings.resetForTest();
      SubtitleDebugSession.instance.resetForTest();
      await settings.init();
      expect(settings.defaultSettingsTrial.hasBackup, true);
      await settings.defaultSettingsTrial.toggle();
      expect(settings.exportSettingsSnapshot()['subtitles'], original);
      expect(preferences.getDouble('playbackSpeed'), 1.8);
      expect(settings.defaultSettingsTrial.hasBackup, false);
    },
  );

  group('actual subtitle settings', () {
    Future<void> customOriginal(SettingsService settings) async {
      await settings.init();
      await settings.saveSubtitleTextStyle(
        const SubtitleTextStyle(
          fontFamilyChinese: 'MiSans',
          fontFamilyEnglish: 'Inter',
          textColor: Colors.amber,
          borderWidth: 2.3,
          backgroundOpacity: .37,
          shadowOffset: Offset(1, 4),
        ),
      );
      await settings.saveSubtitleLayoutPortrait(
        const SubtitleLayoutStyle(
          fontSize: 46,
          secondaryFontSize: 31,
          overallScale: 1.25,
        ),
      );
      await settings.saveSubtitleLayoutGhostLandscape(
        const SubtitleLayoutStyle(
          fontSize: 55,
          secondaryFontSize: 35,
          overallScale: .85,
        ),
      );
      await settings.saveAudioSubtitleLayoutPortrait(
        const SubtitleLayoutStyle(fontSize: 34, secondaryFontSize: 22),
      );
      await settings.saveAudioSubtitleTextStyle(
        const SubtitleTextStyle(textColor: Colors.cyan),
      );
      await settings.setAudioSubtitleStyleSyncWithVideo(false);
      await settings.saveSubtitleAlignment(const Alignment(.12, .62));
      await settings.saveGhostModeAlignment(const Alignment(-.22, -.16));
      await settings.saveAudioSubtitleAlignment(const Alignment(.30, .52));
      await settings.saveSubtitleDelay(.73);
      await settings.saveSubtitlePresets([
        {'x': .15, 'y': .66},
      ]);
      await settings.updateSetting('avoidPlaybackControlsWithSubtitles', false);
      await settings.updateSetting('showSubtitles', false);
      final session = SubtitleDebugSession.instance,
          preset = subtitleDebugPresets.first;
      await session.toggle();
      await session.select(preset);
      await session.updatePreset(
        preset.copyWith(textScale: 1.4, color: Colors.green),
      );
      await session.updateGhostTextScale(preset.id, .75);
      await settings.commitPresetVideoPosition(
        preset.id,
        const Alignment(.2, .4),
      );
      await settings.commitPresetAudioPosition(
        preset.id,
        const Alignment(-.2, .5),
      );
      session.browserCategory = preset.category;
      session.browserQuery = 'test';
      session.browserOffset = 123;
    }

    test(
      'all original styles, both modes, positions, presets and key absence restore exactly',
      () async {
        final settings = SettingsService();
        await customOriginal(settings);
        final prefs = await SharedPreferences.getInstance();
        final raw = _rawScope(prefs),
            original = settings.exportSettingsSnapshot()['subtitles'];
        await settings.defaultSettingsTrial.toggle();
        expect(
          settings.subtitleTextStyle.toJson(),
          RecommendedSubtitleDefaults.textStyle.toJson(),
        );
        expect(settings.subtitleLayoutGhostLandscape.adaptiveSizing, false);
        expect(
          settings.subtitleAlignment,
          RecommendedSubtitleDefaults.ordinaryAlignment,
        );
        expect(SubtitleDebugSession.instance.enabled, false);
        final backup = prefs.getString(DefaultSettingsTrialJournal.originalKey);
        await settings.saveSubtitleTextStyle(
          const SubtitleTextStyle(textColor: Colors.pink),
        );
        await settings.saveSubtitleLayoutLandscape(
          const SubtitleLayoutStyle(fontSize: 81),
        );
        await settings.saveSubtitleLayoutGhostPortrait(
          const SubtitleLayoutStyle(fontSize: 66),
        );
        await settings.saveGhostModeAlignment(const Alignment(.8, .3));
        await settings.saveAudioSubtitleAlignment(const Alignment(-.8, -.4));
        await settings.saveSubtitleDelay(2.2);
        await settings.saveSubtitlePresets([
          {'x': -.5, 'y': .1},
        ]);
        await SubtitleDebugSession.instance.toggle();
        await SubtitleDebugSession.instance.select(subtitleDebugPresets[1]);
        await SubtitleDebugSession.instance.updateGhostTextScale(
          subtitleDebugPresets.first.id,
          1.7,
        );
        await settings.commitPresetVideoPosition(
          subtitleDebugPresets.first.id,
          const Alignment(.7, .7),
        );
        await settings.updateSetting('homeGridCrossAxisCount', 8);
        expect(
          prefs.getString(DefaultSettingsTrialJournal.originalKey),
          backup,
        );
        await settings.defaultSettingsTrial.toggle();
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
        expect(_rawScope(prefs), raw);
        expect(settings.avoidPlaybackControlsWithSubtitles, false);
        expect(settings.homeGridCrossAxisCount, 4);
        expect(SubtitleDebugSession.instance.browserOffset, 123);
        expect(
          DefaultSettingsTrialJournal.storageKeys.any(prefs.containsKey),
          false,
        );
      },
    );

    test(
      'restart during an active trial keeps edits and the original recovery entry',
      () async {
        final settings = SettingsService();
        await customOriginal(settings);
        final original = settings.exportSettingsSnapshot()['subtitles'];
        await settings.defaultSettingsTrial.toggle();
        await settings.saveSubtitleLayoutGhostLandscape(
          RecommendedSubtitleDefaults.layout.copyWith(overallScale: 1.3),
        );
        settings.resetForTest();
        SubtitleDebugSession.instance.resetForTest();
        await settings.init();
        expect(settings.defaultSettingsTrial.hasBackup, true);
        expect(settings.subtitleLayoutGhostLandscape.overallScale, 1.3);
        await settings.defaultSettingsTrial.toggle();
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
      },
    );

    test(
      'startup restores an interrupted transaction before normal settings load',
      () async {
        final settings = SettingsService();
        await customOriginal(settings);
        final original = settings.exportSettingsSnapshot()['subtitles'];
        await settings.defaultSettingsTrial.toggle();
        final journal = settings.defaultSettingsTrial.journal;
        await journal.setPhase((await journal.read())!, 'restoring');
        settings.resetForTest();
        SubtitleDebugSession.instance.resetForTest();
        await settings.init();
        expect(settings.defaultSettingsTrial.hasBackup, false);
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
      },
    );

    test(
      'a failing platform remove cannot hide a persisted trial value on retry',
      () async {
        final backend = _FailingPreferences();
        SharedPreferencesStorePlatform.instance = backend;
        final settings = SettingsService();
        await settings.init();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('showSubtitles'), false);
        await settings.defaultSettingsTrial.toggle();
        backend.failRemoveKey = 'showSubtitles';
        await expectLater(
          settings.defaultSettingsTrial.toggle(),
          throwsStateError,
        );
        expect(settings.defaultSettingsTrial.hasBackup, true);
        backend.failRemoveKey = null;
        await settings.defaultSettingsTrial.toggle();
        await prefs.reload();
        expect(prefs.containsKey('showSubtitles'), false);
        expect(settings.defaultSettingsTrial.hasBackup, false);
        expect(settings.subtitleLayoutLandscape.adaptiveSizing, false);
      },
    );

    test(
      'a failed original backup never applies the recommended settings',
      () async {
        final backend = _FailingPreferences();
        SharedPreferencesStorePlatform.instance = backend;
        final settings = SettingsService();
        await customOriginal(settings);
        final original = settings.exportSettingsSnapshot()['subtitles'];
        backend.failSetKey = DefaultSettingsTrialJournal.recoveryKey;
        await expectLater(
          settings.defaultSettingsTrial.toggle(),
          throwsStateError,
        );
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
        expect(settings.defaultSettingsTrial.hasBackup, true);
        backend.failSetKey = null;
        await settings.defaultSettingsTrial.toggle();
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
      },
    );

    test(
      'failed profile writes retain originals until restoration succeeds',
      () async {
        final backend = _FailingPreferences();
        SharedPreferencesStorePlatform.instance = backend;
        final settings = SettingsService();
        await customOriginal(settings);
        final original = settings.exportSettingsSnapshot()['subtitles'];
        final preferences = await SharedPreferences.getInstance();
        final raw = _rawScope(preferences);
        backend.failSetKey = 'subtitleLayoutPortrait';
        await expectLater(
          settings.defaultSettingsTrial.toggle(),
          throwsStateError,
        );
        expect(settings.defaultSettingsTrial.hasBackup, true);
        expect(settings.defaultSettingsTrial.label, '恢复原有设置');
        backend.failSetKey = null;
        await settings.defaultSettingsTrial.toggle();
        expect(settings.exportSettingsSnapshot()['subtitles'], original);
        await preferences.reload();
        expect(_rawScope(preferences), raw);
        expect(settings.defaultSettingsTrial.hasBackup, false);
      },
    );

    test(
      'a wrongly typed journal remains visible and is never overwritten',
      () async {
        SharedPreferences.setMockInitialValues({
          DefaultSettingsTrialJournal.originalKey: 73,
        });
        final settings = SettingsService();
        await settings.init();
        expect(settings.defaultSettingsTrial.hasBackup, true);
        expect(settings.defaultSettingsTrial.error, isNotNull);
        await expectLater(
          settings.defaultSettingsTrial.toggle(),
          throwsFormatException,
        );
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.get(DefaultSettingsTrialJournal.originalKey), 73);
        expect(settings.defaultSettingsTrial.hasBackup, true);
      },
    );

    test(
      'activation waits for a complete in-flight style save before taking the backup',
      () async {
        final backend = _FailingPreferences();
        SharedPreferencesStorePlatform.instance = backend;
        final settings = SettingsService();
        await settings.init();
        backend.styleWriteGate = Completer<void>();
        final saved = settings.saveSubtitleTextStyle(
          const SubtitleTextStyle(textColor: Colors.purple, borderWidth: 3),
        );
        final started = settings.defaultSettingsTrial.toggle();
        await Future<void>.delayed(Duration.zero);
        expect(settings.defaultSettingsTrial.busy, true);
        expect(settings.defaultSettingsTrial.hasBackup, false);
        backend.styleWriteGate!.complete();
        await saved;
        await started;
        backend.styleWriteGate = null;
        await settings.defaultSettingsTrial.toggle();
        expect(
          settings.subtitleTextStyle.textColor.toARGB32(),
          Colors.purple.toARGB32(),
        );
        expect(settings.subtitleTextStyle.borderWidth, 3);
      },
    );
  });

  testWidgets(
    'the same visible button toggles test/restore and updates its label',
    (tester) async {
      final settings = SettingsService();
      await tester.runAsync(() async {
        SubtitleDebugSession.instance.resetForTest();
        await settings.init();
      });
      final original = settings.exportSettingsSnapshot()['subtitles'];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DefaultSettingsTrialButton(settings: settings)),
        ),
      );
      expect(find.text('测试默认设置'), findsOneWidget);
      Future<void> tapAndWait() async {
        final trial = settings.defaultSettingsTrial;
        await tester.tap(
          find.byKey(const ValueKey('default-settings-trial-toggle')),
        );
        // SharedPreferences callbacks and widget listeners use different test
        // zones. Let both queues progress while the busy spinner is visible.
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          if (!trial.busy) break;
        }
        expect(trial.busy, false);
      }

      await tapAndWait();
      await tester.pumpAndSettle();
      expect(find.text('恢复原有设置'), findsOneWidget);
      expect(settings.defaultSettingsTrial.hasBackup, true);
      await tapAndWait();
      await tester.pumpAndSettle();
      expect(find.text('测试默认设置'), findsOneWidget);
      expect(settings.exportSettingsSnapshot()['subtitles'], original);
      expect(tester.takeException(), isNull);
    },
  );
}
