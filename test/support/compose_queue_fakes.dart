import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/video_compose/video_compose_artifact_cleaner.dart';
import 'package:video_player_app/services/video_compose/video_compose_orchestrator.dart';
import 'package:video_player_app/services/video_compose/video_compose_task_store.dart';
import 'package:video_player_app/services/video_compose_manager.dart';

VideoComposeTaskState composeRecord(String id, {String? outputPath}) =>
    VideoComposeTaskState(
      taskId: id,
      request: VideoComposeRequest(
        videoId: id,
        videoPath: 'input.mp4',
        title: '视频 $id',
        renderSecondarySubtitle: false,
        continuousSubtitle: false,
        embedSoftSubtitles: false,
        softSubtitleOnly: false,
        softSubtitleUseSourceQuality: true,
        softSubtitleTracks: const [],
        resolution: VideoComposeResolution.source,
        subtitleStyle: const SubtitleStyle(),
        subtitleAlignment: Alignment.bottomCenter,
        outputPath: outputPath ?? '$id-output.mp4',
      ),
      createdAt: DateTime(2026, 10, 28),
      completedAt: DateTime(2026, 10, 28),
      stage: VideoComposeStage.completed,
      progress: 1,
      message: '合成完成',
    );

class MemoryComposeStore extends VideoComposeTaskStore {
  MemoryComposeStore([this.records = const []]);
  List<VideoComposeTaskState> records;
  final saved = <List<VideoComposeTaskState>>[];

  @override
  Future<List<VideoComposeTaskState>> loadTasks() async => records;

  @override
  Future<void> saveTasks(Iterable<VideoComposeTaskState> tasks) async {
    records = tasks.toList();
    saved.add(records);
  }
}

class RecordingComposeCleaner extends VideoComposeArtifactCleaner {
  final deletions = <({String id, bool output})>[];
  final failedIds = <String>{};
  Completer<void>? gate;

  @override
  Future<bool> cleanupTaskArtifacts(
    String taskId, {
    bool deleteOutput = false,
    String? outputPath,
  }) async {
    if (outputPath == null) return true;
    deletions.add((id: taskId, output: deleteOutput));
    await gate?.future;
    return !failedIds.contains(taskId);
  }
}

class ControlledComposeOrchestrator implements VideoComposeOrchestrator {
  final started = <String>[];
  final cancelled = <String>[];
  final running = <String, Completer<void>>{};
  String? _active;

  @override
  Future<void> run({
    required String taskId,
    required VideoComposeRequest request,
    required VideoComposeArtifactCallback onArtifact,
    required VideoComposeStatusCallback onStatus,
  }) async {
    started.add(taskId);
    _active = taskId;
    final done = running[taskId] = Completer<void>();
    onStatus(stage: VideoComposeStage.rendering);
    await done.future;
    _active = null;
    if (cancelled.contains(taskId)) throw StateError('cancelled');
    onStatus(stage: VideoComposeStage.completed, progress: 1);
  }

  @override
  Future<void> cancelRunningCompose() async {
    if (_active != null) cancelled.add(_active!);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<VideoComposeTaskState> enqueueCompose(
  VideoComposeManager manager,
  String id,
) => manager.enqueue(
  videoId: id,
  videoPath: 'input.mp4',
  title: id,
  primarySubtitlePath: null,
  secondarySubtitlePath: null,
  renderSecondarySubtitle: false,
  continuousSubtitle: false,
  embedSoftSubtitles: false,
  softSubtitleOnly: false,
  softSubtitleUseSourceQuality: true,
  softSubtitleTracks: const [],
  resolution: VideoComposeResolution.source,
  renderMode: VideoComposeRenderMode.precise,
  subtitleStyle: const SubtitleStyle(),
  subtitleStylePortrait: const SubtitleStyle(),
  subtitleAlignment: Alignment.bottomCenter,
  splitSubtitleByLine: true,
  customOutputPath: 'compose-output',
);
