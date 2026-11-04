import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/video_item.dart';
import 'playlist_manager.dart';

class QueueAddProgress extends ChangeNotifier {
  bool cancelled = false;
  int resolved = 0;
  String currentName = '';
  VoidCallback? cancelReader;

  void cancel() {
    cancelled = true;
    cancelReader?.call();
    notifyListeners();
  }

  void update(String name) {
    currentName = name;
    resolved++;
    notifyListeners();
  }
}

class QueueAddBatch {
  QueueAddBatch({
    Iterable<VideoItem> items = const [],
    Iterable<String> failed = const [],
  }) : items = List.of(items),
       failed = List.of(failed);
  final List<VideoItem> items;
  final List<String> failed;
}

class QueueAddResult {
  const QueueAddResult({
    this.added = const [],
    this.duplicates = 0,
    this.failed = const [],
    this.cancelled = false,
    this.queueChanged = false,
  });
  final List<String> added;
  final int duplicates;
  final List<String> failed;
  final bool cancelled, queueChanged;
  bool get completed => !cancelled && !queueChanged && failed.isEmpty;
}

typedef QueueAddResolver =
    Future<QueueAddBatch> Function(QueueAddProgress progress);

/// One ordered commit stream per queue. Resolving metadata never selects a
/// player item. A queue switch invalidates work submitted to the former queue.
class PlaybackQueueAddService {
  static final _services = Expando<PlaybackQueueAddService>();
  static PlaybackQueueAddService of(PlaylistManager queue) =>
      _services[queue] ??= PlaybackQueueAddService._(queue);
  PlaybackQueueAddService._(this.queue);
  final PlaylistManager queue;
  Future<void> _tail = Future.value();

  Future<QueueAddResult> add(
    QueueAddResolver resolver,
    QueueAddProgress progress,
  ) {
    final epoch = queue.queueEpoch;
    final result = Completer<QueueAddResult>();
    _tail = _tail.then((_) async {
      if (progress.cancelled) {
        result.complete(const QueueAddResult(cancelled: true));
        return;
      }
      if (queue.queueEpoch != epoch) {
        result.complete(const QueueAddResult(queueChanged: true));
        return;
      }
      try {
        final batch = await resolver(progress);
        if (progress.cancelled) {
          result.complete(const QueueAddResult(cancelled: true));
        } else if (queue.queueEpoch != epoch) {
          result.complete(const QueueAddResult(queueChanged: true));
        } else {
          final commit = queue.addToPlaybackQueue(batch.items);
          result.complete(
            QueueAddResult(
              added: commit.added,
              duplicates: commit.duplicates,
              failed: [...batch.failed, ...commit.failed],
            ),
          );
        }
      } catch (error, stack) {
        debugPrint('Queue addition failed: $error\n$stack');
        result.complete(
          progress.cancelled
              ? const QueueAddResult(cancelled: true)
              : const QueueAddResult(failed: ['添加失败，请检查来源或网络后重试']),
        );
      }
    });
    return result.future;
  }
}
