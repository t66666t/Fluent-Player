import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/subtitle_model.dart';
import 'serial_task_queue.dart';

/// Owns a captured document and callback, including after its editor unmounts.
class DeferredSubtitleEdits {
  static final _active = <DeferredSubtitleEdits>{};
  static final _documents = <Object, _SubtitleEditDocument>{};
  final _queue = SerialTaskQueue();
  Timer? _timer;
  _SubtitleEditTicket? _pending;
  Future<void> _lastSave = Future<void>.value();
  int _revision = 0;
  int _saving = 0;

  bool get hasPending => _pending != null || _saving > 0;

  /// A normal desktop exit must finish drafts before destroying the Dart VM.
  static Future<bool> flushPendingForExit() async {
    while (_active.isNotEmpty) {
      var saved = true;
      for (final editor in _active.toList()) {
        if (!await editor.flushForAction()) saved = false;
      }
      if (!saved) return false;
    }
    return true;
  }

  void schedule(
    List<SubtitleItem> subtitles,
    Future<void> Function(List<SubtitleItem>) save, {
    Object? documentId,
  }) {
    final snapshot = List<SubtitleItem>.unmodifiable(subtitles);
    _revision++;
    final document = documentId == null
        ? null
        : _documents.putIfAbsent(documentId, _SubtitleEditDocument.new);
    final ticket = _SubtitleEditTicket(
      this,
      () => save(snapshot),
      documentId,
      document,
    );
    if (document != null) {
      // Acquire before releasing the old owner, retaining one shared schedule
      // token while any pending/in-flight ticket for this document exists.
      document.references++;
      final previous = document.latest;
      document.latest = ticket;
      if (previous != null) previous.owner._discardPending(previous);
    }
    final replaced = _pending;
    if (replaced != null) _discardPending(replaced);
    _pending = ticket;
    _active.add(this);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 220), flushInBackground);
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    if (pending == null) return _lastSave;
    _pending = null;
    final revision = _revision;
    _saving++;
    // The queue also defers callbacks until after a widget's dispose/build.
    final operation = _queue.enqueue(() async {
      try {
        if (pending.isCurrent) await pending.save();
      } catch (_) {
        if (_revision == revision && _pending == null && pending.isCurrent) {
          _pending = pending;
        }
        rethrow;
      } finally {
        _saving--;
        if (!identical(_pending, pending)) _release(pending);
        if (!hasPending) _active.remove(this);
      }
    });
    _lastSave = operation;
    return operation;
  }

  void _discardPending(_SubtitleEditTicket ticket) {
    if (!identical(_pending, ticket)) return;
    _pending = null;
    _release(ticket);
    if (!hasPending) {
      _active.remove(this);
      _timer?.cancel();
      _timer = null;
      _lastSave = Future<void>.value();
    }
  }

  static void _release(_SubtitleEditTicket ticket) {
    if (ticket.released) return;
    ticket.released = true;
    final document = ticket.document;
    if (document != null && --document.references == 0) {
      if (identical(_documents[ticket.documentId], document)) {
        _documents.remove(ticket.documentId);
      }
    }
  }

  void flushInBackground() {
    unawaited(flush().catchError(_reportError));
  }

  Future<bool> flushForAction() async {
    try {
      await flush();
      return true;
    } catch (error, stack) {
      _reportError(error, stack);
      return false;
    }
  }

  static void _reportError(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'subtitle editor',
        context: ErrorDescription('while saving subtitle edits'),
      ),
    );
  }
}

class _SubtitleEditDocument {
  _SubtitleEditTicket? latest;
  int references = 0;
}

class _SubtitleEditTicket {
  _SubtitleEditTicket(this.owner, this.save, this.documentId, this.document);
  final DeferredSubtitleEdits owner;
  final Future<void> Function() save;
  final Object? documentId;
  final _SubtitleEditDocument? document;
  bool released = false;
  bool get isCurrent => document == null || identical(document!.latest, this);
}
