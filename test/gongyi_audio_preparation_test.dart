import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/gongyi_audio_preparation.dart';

void main() {
  test(
    'public speech uploads prefer MP3 while existing planning defaults remain compatible',
    () {
      for (final codec in ['aac', 'flac']) {
        expect(
          GongyiAudioPreparationPlan.choose(
            path: 'audio.m4a',
            codec: codec,
            durationSeconds: 300,
            sliceSeconds: 300,
            wholeFile: true,
            isAudioInput: true,
            fileBytes: 1000000,
            preferMp3: true,
          ),
          GongyiAudioPreparation.transcode,
        );
      }
      expect(
        GongyiAudioPreparationPlan.choose(
          path: 'audio.mp3',
          codec: 'mp3',
          durationSeconds: 300,
          sliceSeconds: 300,
          wholeFile: true,
          isAudioInput: true,
          fileBytes: 1000000,
          preferMp3: true,
        ),
        GongyiAudioPreparation.direct,
      );
    },
  );

  GongyiAudioPreparation plan({
    String path = 'speech.m4a',
    String? codec = 'aac',
    double? seconds = 1200,
    double sliceSeconds = 1200,
    bool whole = true,
    bool audio = true,
    int bytes = 16000000,
    int? bitRate,
    int audioStreams = 1,
    bool hasVideo = false,
  }) => GongyiAudioPreparationPlan.choose(
    path: path,
    codec: codec,
    durationSeconds: seconds,
    sliceSeconds: sliceSeconds,
    wholeFile: whole,
    isAudioInput: audio,
    fileBytes: bytes,
    audioBitRate: bitRate,
    audioStreams: audioStreams,
    hasVideo: hasVideo,
  );

  test('existing AAC and MP3 bypass conversion beyond ten minutes', () {
    expect(plan(), GongyiAudioPreparation.direct);
    expect(
      plan(path: 'podcast.MP3', codec: 'mp3'),
      GongyiAudioPreparation.direct,
    );
    expect(
      plan(bytes: GongyiAudioPreparationPlan.maximumFastAudioBytes),
      GongyiAudioPreparation.direct,
    );
  });

  test(
    'video copies only the audio stream and uses its bitrate for the budget',
    () {
      expect(
        plan(
          path: 'movie.mp4',
          audio: false,
          hasVideo: true,
          bytes: 10 * 1024 * 1024 * 1024,
          bitRate: 128000,
        ),
        GongyiAudioPreparation.copy,
      );
      expect(
        plan(
          path: 'movie.mp4',
          audio: false,
          hasVideo: true,
          bytes: 100,
          bitRate: 1000000,
        ),
        GongyiAudioPreparation.transcode,
      );
      expect(
        plan(path: 'movie.mp4', audio: false, hasVideo: true, bitRate: null),
        GongyiAudioPreparation.transcode,
      );
    },
  );

  test(
    'long recordings copy bounded slices without copying the entire file',
    () {
      expect(
        plan(seconds: 7200, sliceSeconds: 3600, whole: false, bytes: 56000000),
        GongyiAudioPreparation.copy,
      );
      expect(
        plan(seconds: 7200, sliceSeconds: 3600, whole: false, bytes: 120000000),
        GongyiAudioPreparation.transcode,
      );
      expect(plan(whole: false), GongyiAudioPreparation.copy);
    },
  );

  test('large files and unknown metadata retain the compatible encoder', () {
    expect(plan(bytes: 70000000), GongyiAudioPreparation.transcode);
    for (final seconds in [null, 0.0, -1.0, double.nan, double.infinity]) {
      expect(plan(seconds: seconds), GongyiAudioPreparation.transcode);
    }
    for (final codec in [null, 'opus', 'flac', 'ac3', 'pcm_s16le']) {
      expect(plan(codec: codec), GongyiAudioPreparation.transcode);
    }
    expect(
      plan(sliceSeconds: double.infinity),
      GongyiAudioPreparation.transcode,
    );
    expect(plan(sliceSeconds: 0), GongyiAudioPreparation.transcode);
    expect(plan(bytes: 0), GongyiAudioPreparation.transcode);
  });

  test(
    'extra tracks and mismatching containers cannot take the direct path',
    () {
      expect(plan(hasVideo: true), GongyiAudioPreparation.transcode);
      expect(plan(hasVideo: true, bitRate: 96000), GongyiAudioPreparation.copy);
      expect(plan(audioStreams: 2), GongyiAudioPreparation.copy);
      expect(plan(path: 'audio.aac'), GongyiAudioPreparation.copy);
      expect(
        plan(path: 'audio.ogg', codec: 'mp3'),
        GongyiAudioPreparation.copy,
      );
    },
  );

  test('normalization cannot replace uncertain or restricted remote tasks', () {
    for (final kind in GongyiAsrFailureKind.values) {
      final error = GongyiAsrException(kind, '音频格式错误', taskFinished: true);
      expect(
        GongyiAudioPreparationPlan.shouldNormalizeAfter(
          error,
          taskPending: true,
        ),
        isFalse,
      );
      expect(
        GongyiAudioPreparationPlan.shouldNormalizeAfter(
          error,
          taskPending: false,
        ),
        kind == GongyiAsrFailureKind.rejected ||
            kind == GongyiAsrFailureKind.tooLong,
      );
    }
    expect(
      GongyiAudioPreparationPlan.shouldNormalizeAfter(
        const GongyiAsrException(GongyiAsrFailureKind.tooLong, '音频时长超出限制'),
        taskPending: false,
      ),
      isFalse,
    );
    expect(
      GongyiAudioPreparationPlan.shouldNormalizeAfter(
        const GongyiAsrException(GongyiAsrFailureKind.tooLong, '音频文件大小超过限制'),
        taskPending: false,
      ),
      isTrue,
    );
    expect(
      GongyiAudioPreparationPlan.shouldNormalizeAfter(
        const GongyiAsrException(GongyiAsrFailureKind.rejected, '参数错误'),
        taskPending: false,
      ),
      isFalse,
    );
    expect(
      GongyiAudioPreparationPlan.shouldNormalizeAfter(
        const GongyiAsrException(GongyiAsrFailureKind.rejected, '不支持此音频格式'),
        taskPending: false,
      ),
      isTrue,
    );
    expect(
      GongyiAudioPreparationPlan.shouldNormalizeAfter(
        const GongyiAsrException(
          GongyiAsrFailureKind.rejected,
          '音频格式错误',
          taskFinished: true,
          queryRetryExhausted: true,
        ),
        taskPending: false,
      ),
      isFalse,
    );
  });
}
