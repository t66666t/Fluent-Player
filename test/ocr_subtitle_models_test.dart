import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';

void main() {
  group('NormalizedOcrRegion', () {
    test('default region covers the lower subtitle band', () {
      const region = NormalizedOcrRegion.subtitleDefault();
      expect(region.left, 0.05);
      expect(region.top, 0.72);
      expect(region.right, 0.95);
      expect(region.bottom, 1.0);
    });

    test('normalizes reversed and out-of-range coordinates', () {
      const raw = NormalizedOcrRegion(
        left: 1.2,
        top: 0.9,
        right: -0.2,
        bottom: 0.1,
      );
      final value = raw.normalized();
      expect(value.left, 0);
      expect(value.top, 0.1);
      expect(value.right, 1);
      expect(value.bottom, 0.9);
    });

    test('maps normalized coordinates to source pixels', () {
      const region = NormalizedOcrRegion(
        left: 0.1,
        top: 0.5,
        right: 0.9,
        bottom: 0.75,
      );
      expect(
        region.toPixelRect(const Size(1920, 1080)),
        const Rect.fromLTRB(192, 540, 1728, 810),
      );
    });
  });

  test('OCR managed subtitle kind round-trips through JSON', () {
    const asset = ManagedSubtitleAsset(
      assetId: 'asset-1',
      path: '/tmp/subtitle.ocr.zh-Hans.srt',
      kind: ManagedSubtitleAssetKind.ocr,
      displayName: 'OCR 字幕 · 中文',
      language: 'zh-Hans',
      createdAt: 1,
    );
    final restored = ManagedSubtitleAsset.fromJson(asset.toJson());
    expect(restored.kind, ManagedSubtitleAssetKind.ocr);
    expect(restored.displayName, 'OCR 字幕 · 中文');
    expect(restored.language, 'zh-Hans');
  });

  test('multiple OCR tracks keep their number region and language', () {
    const tracks = <OcrSubtitleTrack>[
      OcrSubtitleTrack(
        number: 1,
        region: NormalizedOcrRegion(
          left: 0.05,
          top: 0.72,
          right: 0.95,
          bottom: 0.88,
        ),
        language: OcrSubtitleLanguage.chinese,
      ),
      OcrSubtitleTrack(
        number: 2,
        region: NormalizedOcrRegion(
          left: 0.08,
          top: 0.54,
          right: 0.92,
          bottom: 0.70,
        ),
        language: OcrSubtitleLanguage.english,
      ),
    ];
    final restored = tracks
        .map((track) => OcrSubtitleTrack.fromJson(track.toJson()))
        .toList();
    expect(restored, hasLength(2));
    expect(restored[0].number, 1);
    expect(restored[0].language, OcrSubtitleLanguage.chinese);
    expect(restored[1].number, 2);
    expect(restored[1].language, OcrSubtitleLanguage.english);
    expect(restored[1].region.top, 0.54);

    final job = OcrSubtitleJob(
      videoId: 'video-1',
      videoPath: 'video.mp4',
      tracks: restored,
      start: Duration.zero,
      end: const Duration(minutes: 1),
    ).copyWith(outputPaths: const <String>['zh.srt', 'en.srt']);
    expect(job.tracks, hasLength(2));
    expect(job.outputPaths, const <String>['zh.srt', 'en.srt']);
    expect(job.outputPath, 'zh.srt');
  });
}
