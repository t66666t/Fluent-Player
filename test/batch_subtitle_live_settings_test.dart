import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'batchSubtitleAutoDelete': false,
      'batchSubtitleOutputPathStrategy': 'sameAsVideo',
      'batchSubtitleCustomOutputDir': r'D:\old-output',
      'batchSubtitleEmbedSoftCopyAndEmbed': false,
      'batchSubtitleEmbedSoftDeleteOriginal': false,
      'batchSubtitleEmbedSoftPrefixEnabled': false,
      'batchSubtitleEmbedSoftPrefix': '[AI字幕]',
      'batchSubtitleEmbedSoftSuffixEnabled': false,
      'batchSubtitleEmbedSoftSuffix': '',
      'batchSubtitleEmbedAutoDeleteSrt': false,
    });
    settings = SettingsService();
    settings.resetForTest();
    await settings.init();
  });

  test(
    'enqueue results distinguish new tasks from duplicates without losing the queue',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);
      expect(
        await manager.startTranscription('/internal.mp4', videoId: 'internal'),
        TranscriptionEnqueueResult.added,
      );
      expect(
        await manager.startTranscription('/internal.mp4', videoId: 'internal'),
        TranscriptionEnqueueResult.alreadyQueued,
      );
      expect(
        await manager.startExternalTranscription(
          '/external.mp4',
          outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
        ),
        TranscriptionEnqueueResult.added,
      );
      expect(
        await manager.startExternalTranscription(
          '/external.mp4',
          outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
        ),
        TranscriptionEnqueueResult.alreadyQueued,
      );
      expect(manager.getQueueSnapshot().length, 2);
    },
  );

  test(
    'every batch subtitle field changes in memory before persistence awaits',
    () async {
      final autoDeleteWrite = settings.updateBatchSubtitleAutoDelete(true);
      expect(settings.batchSubtitleAutoDelete, isTrue);
      await autoDeleteWrite;

      final outputWrite = settings.updateBatchSubtitleOutputLocation(
        SubtitleOutputPathStrategy.customDirectory,
        customOutputDir: r'D:\new-output',
      );
      expect(
        settings.batchSubtitleOutputPathStrategy,
        SubtitleOutputPathStrategy.customDirectory,
      );
      expect(settings.batchSubtitleCustomOutputDir, r'D:\new-output');
      await outputWrite;

      final embedModeWrite = settings.updateBatchSubtitleEmbedMode(
        copyAndEmbed: true,
        deleteOriginal: false,
      );
      expect(settings.batchSubtitleEmbedSoftCopyAndEmbed, isTrue);
      expect(settings.batchSubtitleEmbedSoftDeleteOriginal, isFalse);
      await embedModeWrite;

      final prefixEnabledWrite = settings
          .updateBatchSubtitleEmbedSoftPrefixEnabled(true);
      expect(settings.batchSubtitleEmbedSoftPrefixEnabled, isTrue);
      await prefixEnabledWrite;

      final prefixWrite = settings.updateBatchSubtitleEmbedSoftPrefix('[实时]');
      expect(settings.batchSubtitleEmbedSoftPrefix, '[实时]');
      await prefixWrite;

      final suffixEnabledWrite = settings
          .updateBatchSubtitleEmbedSoftSuffixEnabled(true);
      expect(settings.batchSubtitleEmbedSoftSuffixEnabled, isTrue);
      await suffixEnabledWrite;

      final suffixWrite = settings.updateBatchSubtitleEmbedSoftSuffix('_新版');
      expect(settings.batchSubtitleEmbedSoftSuffix, '_新版');
      await suffixWrite;

      final deleteSrtWrite = settings.updateBatchSubtitleEmbedAutoDeleteSrt(
        true,
      );
      expect(settings.batchSubtitleEmbedAutoDeleteSrt, isTrue);
      await deleteSrtWrite;
    },
  );

  test(
    'embedding modes stay mutually exclusive without a transient state',
    () async {
      await settings.updateBatchSubtitleEmbedSoftDeleteOriginal(true);
      expect(settings.batchSubtitleEmbedSoftDeleteOriginal, isTrue);
      expect(settings.batchSubtitleEmbedSoftCopyAndEmbed, isFalse);

      final switchWrite = settings.updateBatchSubtitleEmbedSoftCopyAndEmbed(
        true,
      );
      expect(settings.batchSubtitleEmbedSoftCopyAndEmbed, isTrue);
      expect(settings.batchSubtitleEmbedSoftDeleteOriginal, isFalse);
      await switchWrite;

      await expectLater(
        settings.updateBatchSubtitleEmbedMode(
          copyAndEmbed: true,
          deleteOriginal: true,
        ),
        throwsArgumentError,
      );
    },
  );

  test('queued external tasks expose the latest output location', () async {
    final manager = TranscriptionManager(settings: settings);
    addTearDown(manager.dispose);

    await manager.startExternalTranscription(
      r'D:\videos\sample.mp4',
      outputPathStrategy: SubtitleOutputPathStrategy.sameAsVideo,
      customOutputDir: r'D:\stale-snapshot',
    );

    final locationWrite = settings.updateBatchSubtitleOutputLocation(
      SubtitleOutputPathStrategy.customDirectory,
      customOutputDir: r'D:\live-output',
    );

    final task = manager.getQueueSnapshot().single;
    expect(task.outputPathStrategy, SubtitleOutputPathStrategy.customDirectory);
    expect(task.customOutputDir, r'D:\live-output');
    await locationWrite;
  });

  test(
    'atomic output update persists the matching strategy and directory',
    () async {
      await settings.updateBatchSubtitleOutputLocation(
        SubtitleOutputPathStrategy.customDirectory,
        customOutputDir: r'D:\paired-output',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('batchSubtitleOutputPathStrategy'),
        'customDirectory',
      );
      expect(
        prefs.getString('batchSubtitleCustomOutputDir'),
        r'D:\paired-output',
      );
    },
  );
}
