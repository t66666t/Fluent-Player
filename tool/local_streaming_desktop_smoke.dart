// flutter build windows --profile -t tool/local_streaming_desktop_smoke.dart
// Run from the workspace; results are written under .artifacts/model-center.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_display_state.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/subtitle_display_layer.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

final _root = p.absolute('.artifacts/model-center/streaming-desktop-smoke');

class _Models extends ModelCenterService {
  _Models({required super.storage});
  @override
  Future<void> initialize() async {}
  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(
    artifact(id)!,
    Directory(p.absolute('.artifacts/model-center/native/$id')),
  );
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(
      p.absolute('.artifacts/model-center/native/${spec.profile.model}'),
    ),
    {},
  );
}

Uint8List _wave(Float32List samples) {
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      44 + i * 2,
      (samples[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Smoke()));
}

class _Smoke extends StatefulWidget {
  const _Smoke();
  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  final _primary = SubtitleCueBuffer(), _secondary = SubtitleCueBuffer();
  final _clock = ValueNotifier(Duration.zero);
  final _overlay = ValueNotifier(
    const SubtitleDisplayState(
      entries: [
        SubtitleOverlayEntry(
          text: 'Streaming subtitle',
          secondaryText: '成对字幕增量显示',
        ),
      ],
    ),
  );
  final _frames = <FrameTiming>[];
  VideoPlayerController? _video;
  var _shape = 0, _measure = false;
  Timer? _appendTimer;

  @override
  void initState() {
    super.initState();
    _append(10000);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _timings(List<FrameTiming> frames) {
    if (_measure) _frames.addAll(frames);
  }

  void _append(int count) {
    final start = _primary.snapshot.length;
    final cues = List.generate(
      count,
      (i) => SubtitleItem(
        index: start + i + 1,
        startTime: Duration(seconds: (start + i) * 5),
        endTime: Duration(seconds: (start + i) * 5 + 4),
        text: 'Sentence ${start + i} · 字幕持续追加。',
      ),
    );
    _primary.addAll(cues);
    _secondary.addAll(
      cues.map((cue) => cue.copyWith(text: 'Translation ${cue.index} · 对应译文。')),
    );
  }

  Future<void> _run() async {
    final report = <String, dynamic>{
      'mode': 'profile',
      'platform': Platform.operatingSystem,
      'initialCues': 10000,
      'rounds': [],
    };
    try {
      await Directory(_root).create(recursive: true);
      await LlamaLogging.configure(level: LlamaLogLevel.error);
      await SettingsService().init();
      NativeVideoPlayerMediaKit.ensureInitialized();
      _video = VideoPlayerController.file(
        File(p.absolute('.artifacts/model-center/streaming-smoke.mp4')),
      );
      await _video!.initialize().timeout(const Duration(seconds: 30));
      await _video!.setVolume(0);
      await _video!.setLooping(true);
      await _video!.play();
      _video!.addListener(() {
        _clock.value = _video!.value.position;
      });
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.windows,
          support: Directory(p.join(_root, 'support')),
          documents: Directory(p.join(_root, 'docs')),
          defaultData: Directory(p.join(_root, 'data')),
          executable: Directory(p.dirname(Platform.resolvedExecutable)),
        ),
      );
      await storage.initialize();
      final center = _Models(storage: storage)
        ..catalog = await loadModelCatalog();
      final asr = center.artifact('sensevoice-small-int8')!;
      final model = center.artifact('hy-mt2-1.8b-q4')!;
      final asrSpec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: asr.id,
          name: asr.name,
          kind: TranscriptionServiceKind.local,
          model: asr.id,
          language: 'en',
        ),
        artifactIdentity: asr.identity,
        asrEnhancements: AsrEnhancementOptions.disabled,
        subtitleSegmentation: SubtitleSegmentationOptions.natural,
      );
      final translation = ModelJobSpec(
        profile: ModelServiceProfile(
          id: model.id,
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        ),
        artifactIdentity: model.identity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
          threads: 2,
        ),
      );
      final probe = decodeModelWave(
        await File('assets/models/asr/speech_probe.wav').readAsBytes(),
      );
      final samples = Float32List(34 * 16000);
      for (final second in [0, 29]) {
        samples.setRange(
          second * 16000,
          second * 16000 + probe.length.clamp(0, 4 * 16000),
          probe,
        );
      }
      for (var shape = 0; shape < 4; shape++) {
        SettingsService().subtitleViewMode = shape == 1 ? 1 : 0;
        SettingsService().subtitleArticleParagraphModeEnabled = false;
        setState(() => _shape = shape);
        await Future<void>.delayed(const Duration(seconds: 2));
        _frames.clear();
        _measure = true;
        final watch = Stopwatch()..start();
        var updates = 0, commits = 0;
        var firstPairMs = 0;
        var translationLoadActivities = 0;
        final generation =
            'smoke-$shape-${DateTime.now().microsecondsSinceEpoch}';
        final rssStart = ProcessInfo.currentRss;
        var peakRss = rssStart;
        final workers = <LocalAsrWorker>[];
        _appendTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
          final rss = ProcessInfo.currentRss;
          if (rss > peakRss) peakRss = rss;
          setState(() {
            _append(8);
            updates++;
          });
        });
        final store = await StreamingSubtitleStore.create(
          File(p.join(_root, 'session-$shape.jsonl')),
          {
            'generationId': generation,
            'primaryPath': p.join(_root, '$shape.srt'),
            'secondaryPath': p.join(_root, '$shape.translated.srt'),
          },
        );
        final cancellation = Completer<void>();
        final stream = LocalTranscriptionStream(
          openStore: () async => store,
          choice: TranscriptTranslateChoice(
            enabled: true,
            direction: TranscriptTranslateDirection.toChinese,
            provider: SubtitleTranslateProvider.local,
            aiOptions: AiSubtitleTranslationSettings.defaults,
            localSpecification: translation,
          ),
          center: center,
          translator: SubtitleTranslationService(),
          cancelSignal: cancellation.future,
          checkCancelled: () {},
          onFailure: () {},
          onActivity: (_, message) {
            if (message?.startsWith('正在加载 ') == true) {
              translationLoadActivities++;
            }
          },
          onCommitted: (_, primary, secondary) async {
            if (primary.length != secondary.length) {
              throw StateError('Unpaired output');
            }
            commits++;
            if (firstPairMs == 0) firstPairMs = watch.elapsedMilliseconds;
          },
        );
        try {
          await ModelTranscriptionRunner(
            center: center,
            createLocalWorker: () {
              final worker = LocalAsrWorker();
              workers.add(worker);
              return worker;
            },
          ).run(
            spec: asrSpec,
            sourceIdentity: 'smoke-$shape',
            checkpointScope: generation,
            duration: const Duration(seconds: 34),
            serializeConsumer: true,
            consumerModelBytes: model.bytes,
            onSessionClose: stream.close,
            onStableBatch: stream.accept,
            onProgress: (_) {},
            prepareAudio: (start, count, _, _) async {
              final file = File(
                p.join(_root, '$shape-${start.inMilliseconds}.wav'),
              );
              await file.writeAsBytes(
                _wave(
                  Float32List.sublistView(
                    samples,
                    start.inMilliseconds * 16,
                    (start + count).inMilliseconds * 16,
                  ),
                ),
              );
              return file.path;
            },
          );
          await stream.drain();
        } finally {
          await stream.close();
          _appendTimer?.cancel();
        }
        _measure = false;
        if (translationLoadActivities == 0) {
          throw StateError(
            'The profile run restored translations instead of exercising native inference',
          );
        }
        double percentile(Iterable<Duration> times, double percentile) {
          final sorted =
              times.map((duration) => duration.inMicroseconds / 1000).toList()
                ..sort();
          return sorted.isEmpty
              ? 0
              : sorted[((sorted.length - 1) * percentile).round()];
        }

        (report['rounds'] as List).add({
          'shape': [
            'video-list',
            'video-continuous-article',
            'music-landscape',
            'music-portrait',
          ][shape],
          'elapsedMs': watch.elapsedMilliseconds,
          'firstPairMs': firstPairMs,
          'translationLoadingActivities': translationLoadActivities,
          'audioSecondsPerSecond': 34000 / watch.elapsedMilliseconds,
          'asrModelLoads': workers.fold<int>(
            0,
            (count, worker) => count + worker.modelLoads,
          ),
          'rssStartBytes': rssStart,
          'sampledPeakRssBytes': peakRss,
          'rssEndBytes': ProcessInfo.currentRss,
          'pairedCommits': commits,
          'appendUpdates': updates,
          'frames': _frames.length,
          'buildP95Ms': percentile(
            _frames.map((frame) => frame.buildDuration),
            .95,
          ),
          'rasterP95Ms': percentile(
            _frames.map((frame) => frame.rasterDuration),
            .95,
          ),
          'slowFrames': _frames
              .where(
                (frame) =>
                    frame.buildDuration.inMicroseconds > 16667 ||
                    frame.rasterDuration.inMicroseconds > 16667,
              )
              .length,
          'videoPositionMs': _video!.value.position.inMilliseconds,
          'videoPlaying': _video!.value.isPlaying,
        });
      }
      report['status'] = 'passed';
    } catch (error, stack) {
      report['status'] = 'failed';
      report['error'] = '$error';
      report['stack'] = '$stack';
    } finally {
      _appendTimer?.cancel();
      _measure = false;
      await File(
        p.join(_root, 'report.json'),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      await _video?.dispose();
      exit(report['status'] == 'passed' ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = _primary.snapshot, secondary = _secondary.snapshot;
    if (_shape >= 2) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: _shape == 3 ? 360 : 1000,
            height: _shape == 3 ? 650 : 500,
            child: Theme(
              data: ThemeData.dark().copyWith(
                platform: _shape == 3
                    ? TargetPlatform.android
                    : TargetPlatform.windows,
              ),
              child: MusicLyricView(
                subtitles: primary,
                secondarySubtitles: secondary,
                positionListenable: _clock,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_video?.value.isInitialized == true)
                  Center(
                    child: AspectRatio(
                      aspectRatio: _video!.value.aspectRatio,
                      child: VideoPlayer(_video!),
                    ),
                  ),
                SubtitleDisplayLayer(
                  notifier: _overlay,
                  alignment: Alignment.bottomCenter,
                  style: const SubtitleStyle(),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 450,
            child: SubtitleSidebar(
              key: ValueKey(_shape),
              subtitles: primary,
              secondarySubtitles: secondary,
              controller: _video,
              isCompact: true,
            ),
          ),
        ],
      ),
    );
  }
}
