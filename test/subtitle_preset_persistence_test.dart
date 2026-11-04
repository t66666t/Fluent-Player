import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'ordinary and ghost original layouts stay independent after reload',
    () async {
      final settings = SettingsService()..resetForTest();
      await settings.init();
      const ordinary = SubtitleLayoutStyle(fontSize: 36, secondaryFontSize: 20);
      const ghost = SubtitleLayoutStyle(fontSize: 48, secondaryFontSize: 30);
      await settings.saveSubtitleLayoutLandscape(ordinary);
      await settings.saveSubtitleLayoutGhostLandscape(ghost);
      await settings.saveSubtitleLayoutPortrait(
        ordinary.copyWith(fontSize: 38),
      );
      expect(settings.subtitleLayoutGhostLandscape.fontSize, 48);
      await settings.saveSubtitleLayoutGhostPortrait(
        ghost.copyWith(fontSize: 52),
      );
      expect(settings.subtitleLayoutLandscape.fontSize, 38);
      settings.resetForTest();
      await settings.init();
      for (final layout in [
        settings.subtitleLayoutLandscape,
        settings.subtitleLayoutPortrait,
      ]) {
        expect(layout.fontSize, 38);
        expect(layout.secondaryFontSize, 20);
      }
      for (final layout in [
        settings.subtitleLayoutGhostLandscape,
        settings.subtitleLayoutGhostPortrait,
      ]) {
        expect(layout.fontSize, 52);
        expect(layout.secondaryFontSize, 30);
      }
    },
  );
  test(
    'legacy preset scales are copied once and each mode persists independently',
    () async {
      final p = subtitleDebugPresets.first.copyWith(textScale: 1.4);
      final other = subtitleDebugPresets[1].copyWith(textScale: 1.2);
      SharedPreferences.setMockInitialValues({
        SubtitleDebugSession.storageKey: jsonEncode({
          'enabled': true,
          'selectedId': p.id,
          'custom': {p.id: p.toJson(), other.id: other.toJson()},
        }),
      });
      final s = SubtitleDebugSession();
      addTearDown(s.dispose);
      await s.initialize();
      expect(s.ghostTextScale(p.id), 1.4);
      expect(s.ghostTextScale(other.id), 1.2);
      final preferences = await SharedPreferences.getInstance();
      final migrated = jsonDecode(
        preferences.getString(SubtitleDebugSession.storageKey)!,
      );
      expect(migrated['ghostTextScales'][p.id], 1.4);

      await s.updatePreset(p.copyWith(textScale: .8));
      expect(s.ghostTextScale(p.id), 1.4);
      for (final value in [1.1, 1.2, 1.3, 1.5]) {
        s.updateGhostTextScale(p.id, value);
      }
      await s.flush();
      expect(s.preset!.textScale, .8);
      expect(s.presetForMode(ghost: true)!.textScale, 1.5);
      expect(s.preset!.toJson(), p.copyWith(textScale: .8).toJson());

      final reloaded = SubtitleDebugSession();
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      expect(reloaded.preset!.textScale, .8);
      expect(reloaded.presetForMode(ghost: true)!.textScale, 1.5);
      expect(reloaded.ghostTextScale(other.id), 1.2);
      await reloaded.resetPreset(p.id);
      expect(reloaded.preset!.textScale, 1);
      expect(reloaded.ghostTextScale(p.id), 1);
      expect(reloaded.ghostTextScale(other.id), 1.2);
      expect(reloaded.resolved(other.id).textScale, 1.2);
    },
  );

  test(
    'new presets start independent and ghost scales are validated',
    () async {
      final s = SubtitleDebugSession();
      addTearDown(s.dispose);
      await s.initialize();
      final p = subtitleDebugPresets.first;
      await s.updatePreset(p.copyWith(textScale: 1.6));
      expect(s.ghostTextScale(p.id), 1);
      await s.updateGhostTextScale(p.id, 20);
      expect(s.ghostTextScale(p.id), 1.8);
      await s.updateGhostTextScale(p.id, -20);
      expect(s.ghostTextScale(p.id), .6);
      expect(
        () => s.updateGhostTextScale(p.id, double.nan),
        throwsArgumentError,
      );
      expect(() => s.updateGhostTextScale('missing', 1), throwsArgumentError);
      expect(s.resolved(p.id).textScale, 1.6);
    },
  );
  test(
    'mode, hidden entry and per-preset edits survive a fresh session',
    () async {
      final a = SubtitleDebugSession();
      await a.initialize();
      await a.toggle();
      await a.select(subtitleDebugPresets[36]);
      final edited = a.preset!.copyWith(
        textScale: 1.4,
        box: .73,
        color: Colors.amber,
        secondaryColor: Colors.cyan,
        shadowBlur: 4,
        shadowOffset: const Offset(2, 3),
        outline: 4,
      );
      await a.updatePreset(edited);
      final b = SubtitleDebugSession();
      await b.initialize();
      expect(b.enabled, isTrue);
      expect(b.catalogVisible, isTrue);
      expect(b.preset!.toJson(), edited.toJson());
      expect(b.resolved(subtitleDebugPresets[0].id).textScale, 1);
      await b.useOriginal();
      final c = SubtitleDebugSession();
      await c.initialize();
      expect(c.enabled, isTrue);
      expect(c.catalogVisible, isFalse);
      expect(c.preset, isNull);
      await c.openCatalog();
      await c.select(subtitleDebugPresets[36]);
      expect(c.preset!.textScale, 1.4);
      await c.close();
      final d = SubtitleDebugSession();
      await d.initialize();
      expect(d.enabled, isFalse);
      await d.toggle();
      expect(d.preset!.toJson(), edited.toJson());
      await d.resetPreset(edited.id);
      expect(d.preset!.toJson(), subtitleDebugPresets[36].toJson());
      for (final s in [a, b, c, d]) {
        s.dispose();
      }
    },
  );
  test(
    'rapid writes finish in order and preserve the last slider value',
    () async {
      final s = SubtitleDebugSession();
      await s.initialize();
      await s.toggle();
      await s.select(subtitleDebugPresets.first);
      for (int i = 0; i < 40; i++) {
        s.updatePreset(s.preset!.copyWith(textScale: 1 + i / 100));
      }
      await s.flush();
      final reloaded = SubtitleDebugSession();
      await reloaded.initialize();
      expect(reloaded.preset!.textScale, closeTo(1.39, .000001));
      s.dispose();
      reloaded.dispose();
    },
  );
  test(
    'all presets retain ratio and immutable background geometry after tweaks',
    () {
      for (final p in subtitleDebugPresets) {
        final changed = p.copyWith(
          textScale: 1.5,
          box: .8,
          backgroundColor: Colors.blue,
        );
        final restored = SubtitleDebugPreset.restore(changed.toJson())!;
        expect(restored.toJson(), changed.toJson());
        expect(restored.backgroundPadding, p.backgroundPadding);
        expect(
          restored.styleFor(secondary: true).fontSize /
              restored.styleFor().fontSize,
          closeTo(p.ratio, .0001),
        );
        expect(
          restored.styleFor().backgroundColor.toARGB32(),
          Colors.blue.toARGB32(),
        );
      }
    },
  );
  test(
    'damaged preferences safely fall back, and invalid values are clamped',
    () async {
      SharedPreferences.setMockInitialValues({
        SubtitleDebugSession.storageKey: '{broken',
      });
      final s = SubtitleDebugSession();
      await s.initialize();
      expect(s.enabled, isFalse);
      final raw = subtitleDebugPresets.first.toJson()
        ..['textScale'] = 90
        ..['box'] = -1;
      final p = SubtitleDebugPreset.restore(raw)!;
      expect(p.textScale, 1.8);
      expect(p.box, 0);
      expect(SubtitleDebugPreset.restore({'id': 'missing'}), isNull);
      s.dispose();
    },
  );
  test(
    'queue serialization and materialization keep the exact preset snapshot',
    () async {
      final preset = subtitleDebugPresets[18].copyWith(textScale: 1.3, box: .4);
      final request = VideoComposeRequest(
        videoId: 'v',
        videoPath: 'input.mp4',
        title: 'sample',
        renderSecondarySubtitle: true,
        continuousSubtitle: false,
        embedSoftSubtitles: false,
        softSubtitleOnly: false,
        softSubtitleUseSourceQuality: true,
        softSubtitleTracks: const [],
        resolution: VideoComposeResolution.p720,
        subtitleStyle: const SubtitleStyle(),
        subtitleAlignment: Alignment.bottomCenter,
        subtitlePreset: preset,
        outputPath: 'output.mp4',
      );
      final originalSnapshot = request.toJson();
      final s = SubtitleDebugSession();
      addTearDown(s.dispose);
      await s.initialize();
      await s.updateGhostTextScale(preset.id, 1.8);
      expect(request.toJson(), originalSnapshot);
      expect(request.subtitlePreset!.textScale, 1.3);
      expect(
        request.subtitlePreset!.toJson().containsKey('ghostTextScales'),
        isFalse,
      );
      final placed = VideoComposeRequest(
        videoId: request.videoId,
        videoPath: request.videoPath,
        title: request.title,
        renderSecondarySubtitle: request.renderSecondarySubtitle,
        continuousSubtitle: request.continuousSubtitle,
        embedSoftSubtitles: request.embedSoftSubtitles,
        softSubtitleOnly: request.softSubtitleOnly,
        softSubtitleUseSourceQuality: request.softSubtitleUseSourceQuality,
        softSubtitleTracks: request.softSubtitleTracks,
        resolution: request.resolution,
        subtitleStyle: request.subtitleStyle,
        subtitleAlignment: request.subtitleAlignment,
        subtitlePlacement: SubtitlePlacementSnapshot.custom(
          const Alignment(-0.2, 0.15),
        ),
        subtitlePreset: preset,
        outputPath: request.outputPath,
      );
      final restored = VideoComposeRequest.fromJson(
        placed.toJson(),
      ).copyWith(videoPath: 'local.mp4');
      expect(restored.subtitlePreset!.toJson(), preset.toJson());
      expect(restored.subtitlePlacement!.alignment!.x, closeTo(-0.2, 1e-9));
      expect(restored.videoPath, 'local.mp4');
      final legacy = request.toJson()..remove('subtitlePreset');
      expect(VideoComposeRequest.fromJson(legacy).subtitlePreset, isNull);
      expect(VideoComposeRequest.fromJson(legacy).subtitlePlacement, isNull);
    },
  );
}
