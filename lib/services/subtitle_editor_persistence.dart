import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/managed_subtitle_asset.dart';
import '../models/subtitle_model.dart';
import '../utils/serial_task_queue.dart';
import 'library_service.dart';
import 'subtitle_word_timing_store.dart';

/// Disk work belongs to the library, rather than to a mounted playback page.
class SubtitleEditorPersistence {
  static final _queues = Expando<SerialTaskQueue>();
  static final _copies = Expando<Map<String, String>>();

  static final _failed = Expando<Map<String, _SubtitleEditDraft>>();
  static final _pendingLibraries = <LibraryService>{};

  static String documentKey(
    LibraryService library,
    String videoId,
    String sourcePath,
  ) {
    final key = '$videoId\u0000${p.normalize(sourcePath)}';
    for (final entry
        in _copies[library]?.entries ?? <MapEntry<String, String>>[]) {
      if (entry.key.startsWith('$videoId\u0000') &&
          p.equals(entry.value, sourcePath)) {
        return entry.key;
      }
    }
    return key;
  }

  static Future<String> save({
    required LibraryService library,
    required String videoId,
    required String sourcePath,
    required List<SubtitleItem> subtitles,
  }) {
    final draft = _SubtitleEditDraft(videoId, sourcePath, subtitles);
    final queue = _queues[library] ??= SerialTaskQueue();
    return queue.enqueue(() async {
      final key = documentKey(library, videoId, sourcePath);
      // A closed editor cannot own retries. Keep failed documents with their
      // library, independently of whichever document is now being edited.
      await _retryFailed(library, except: key, propagate: false);
      try {
        final output = await _saveDraft(library, draft);
        _failed[library]?.remove(key);
        if (_failed[library]?.isNotEmpty != true) {
          _pendingLibraries.remove(library);
        }
        return output;
      } catch (_) {
        if (library.getVideo(videoId) != null) {
          (_failed[library] ??= {})[key] = draft;
          _pendingLibraries.add(library);
        }
        rethrow;
      }
    });
  }

  static Future<void> retryPending(LibraryService library) {
    final queue = _queues[library] ??= SerialTaskQueue();
    return queue.enqueue(() => _retryFailed(library, propagate: true));
  }

  /// Closed editors relinquish failed documents to their library. Finish those
  /// drafts too before a normal desktop exit destroys their in-memory owner.
  static Future<void> retryPendingForExit() async {
    while (_pendingLibraries.isNotEmpty) {
      Object? firstError;
      StackTrace? firstStack;
      for (final library in _pendingLibraries.toList()) {
        try {
          await retryPending(library);
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStack!);
      }
    }
  }

  static Future<void> _retryFailed(
    LibraryService library, {
    String? except,
    required bool propagate,
  }) async {
    final failures = _failed[library];
    if (failures == null) {
      _pendingLibraries.remove(library);
      return;
    }
    Object? firstError;
    StackTrace? firstStack;
    for (final entry in failures.entries.toList()) {
      if (entry.key == except) continue;
      if (library.getVideo(entry.value.videoId) == null) {
        failures.remove(entry.key);
        continue;
      }
      try {
        await _saveDraft(library, entry.value);
        failures.remove(entry.key);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (failures.isEmpty) _pendingLibraries.remove(library);
    if (propagate && firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  static Future<String> _saveDraft(
    LibraryService library,
    _SubtitleEditDraft draft,
  ) async {
    final videoId = draft.videoId;
    final sourcePath = draft.sourcePath;
    final snapshot = draft.subtitles;
    if (library.getVideo(videoId) == null) {
      throw StateError('媒体已移除，无法保存字幕修改');
    }
    final copies = _copies[library] ??= <String, String>{};
    final key = '$videoId\u0000${p.normalize(sourcePath)}';
    final owned = await library.subtitleFileBelongsToCard(videoId, sourcePath);
    var output = owned && p.extension(sourcePath).toLowerCase() == '.srt'
        ? sourcePath
        : copies[key];
    if (output != null && !await File(output).exists()) output = null;
    final createCopy = output == null;
    output ??= await library.allocateSubtitleFile(
      videoId,
      'edited.${DateTime.now().microsecondsSinceEpoch}.srt',
    );
    await write(output, snapshot);
    if (createCopy) {
      final sourceAssetId = library
          .managedSubtitleAssetForPath(videoId, sourcePath)
          ?.assetId;
      final baseLabel = '${p.basenameWithoutExtension(sourcePath)}（编辑副本）';
      await library.registerManagedSubtitleAsset(
        videoId,
        path: output,
        kind: ManagedSubtitleAssetKind.manual,
        displayName: baseLabel,
        sourceAssetId: sourceAssetId,
      );
      final item = library.getVideo(videoId);
      if (item == null) throw StateError('媒体已移除，无法登记字幕修改');
      final local = Map<String, String>.from(item.localSubtitles ?? const {});
      var label = baseLabel;
      var serial = 2;
      while (local.containsKey(label) && local[label] != output) {
        label = '$baseLabel $serial';
        serial++;
      }
      local[label] = output;
      await library.updateVideoLocalSubtitles(videoId, local);
      copies[key] = output;
    }
    await library.refreshSubtitleWordTimingBinding(videoId, output);
    library.notifySubtitleFilesChanged(videoId: videoId);
    return output;
  }

  static Future<void> write(String path, List<SubtitleItem> subtitles) async {
    final buffer = StringBuffer();
    for (var i = 0; i < subtitles.length; i++) {
      final item = subtitles[i];
      buffer
        ..writeln(i + 1)
        ..writeln('${_time(item.startTime)} --> ${_time(item.endTime)}')
        ..writeln(item.text)
        ..writeln();
    }
    final next = File('$path.editor.next');
    try {
      await next.writeAsString(buffer.toString(), flush: true);
      await next.rename(path);
      await SubtitleWordTimingStore.write(path, subtitles);
    } finally {
      if (await next.exists()) await next.delete();
    }
  }

  static String _time(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.inHours)}:${two(value.inMinutes.remainder(60))}:'
        '${two(value.inSeconds.remainder(60))},'
        '${value.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}';
  }
}

class _SubtitleEditDraft {
  _SubtitleEditDraft(
    this.videoId,
    this.sourcePath,
    List<SubtitleItem> subtitles,
  ) : subtitles = List<SubtitleItem>.unmodifiable(subtitles);
  final String videoId, sourcePath;
  final List<SubtitleItem> subtitles;
}
