import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/deferred_subtitle_edits.dart';

List<SubtitleItem> _draft(String text) => [
  SubtitleItem(
    index: 1,
    startTime: Duration.zero,
    endTime: const Duration(seconds: 1),
    text: text,
  ),
];

void main() {
  test('a newer owner supersedes an old failed draft before exit', () async {
    final document = Object();
    final oldOwner = DeferredSubtitleEdits();
    final newOwner = DeferredSubtitleEdits();
    var storageAvailable = false;
    var disk = 'original';
    Future<void> save(List<SubtitleItem> items) async {
      if (!storageAvailable) throw const FileSystemException('offline disk');
      disk = items.single.text;
    }

    oldOwner.schedule(_draft('stale failed edit'), save, documentId: document);
    await expectLater(oldOwner.flush(), throwsA(isA<FileSystemException>()));
    expect(oldOwner.hasPending, isTrue);
    storageAvailable = true;
    newOwner.schedule(
      _draft('new successful edit'),
      save,
      documentId: document,
    );
    expect(oldOwner.hasPending, isFalse);
    await newOwner.flush();
    expect(disk, 'new successful edit');
    expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
    expect(disk, 'new successful edit');
  });

  test(
    'an older late failure cannot reactivate after the newer owner saves',
    () async {
      final document = Object();
      final oldOwner = DeferredSubtitleEdits();
      final newOwner = DeferredSubtitleEdits();
      final entered = Completer<void>(), failOld = Completer<void>();
      var disk = 'original';
      oldOwner.schedule(_draft('old in flight'), (_) async {
        entered.complete();
        await failOld.future;
        throw const FileSystemException('late old failure');
      }, documentId: document);
      final oldSave = oldOwner.flush();
      final oldFailure = expectLater(
        oldSave,
        throwsA(isA<FileSystemException>()),
      );
      await entered.future;
      newOwner.schedule(_draft('new acknowledged edit'), (items) async {
        disk = items.single.text;
      }, documentId: document);
      await newOwner.flush();
      failOld.complete();
      await oldFailure;
      expect(oldOwner.hasPending, isFalse);
      expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
      expect(disk, 'new acknowledged edit');
    },
  );

  test(
    'a superseded pending owner does not run its callback or block exit',
    () async {
      final document = Object();
      final first = DeferredSubtitleEdits(), second = DeferredSubtitleEdits();
      final written = <String>[];
      first.schedule(_draft('obsolete pending'), (items) async {
        written.add(items.single.text);
      }, documentId: document);
      second.schedule(_draft('newest scheduled'), (items) async {
        written.add(items.single.text);
      }, documentId: document);
      expect(first.hasPending, isFalse);
      expect(await first.flushForAction(), isTrue);
      expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
      expect(written, ['newest scheduled']);
    },
  );

  test(
    'new scheduling on the same owner replaces its failed callback',
    () async {
      final document = Object();
      final editor = DeferredSubtitleEdits();
      var oldCalls = 0;
      final written = <String>[];
      editor.schedule(_draft('failed'), (_) async {
        oldCalls++;
        throw const FileSystemException('injected failure');
      }, documentId: document);
      await expectLater(editor.flush(), throwsA(isA<FileSystemException>()));
      editor.schedule(_draft('replacement'), (items) async {
        written.add(items.single.text);
      }, documentId: document);
      expect(await editor.flushForAction(), isTrue);
      expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
      expect(oldCalls, 1);
      expect(written, ['replacement']);
    },
  );

  test(
    'group changes preserve the captured in-flight document and its successor',
    () async {
      final editor = DeferredSubtitleEdits();
      final entered = Completer<void>(), release = Completer<void>();
      final written = <String>[];
      editor.schedule(_draft('group A'), (items) async {
        entered.complete();
        await release.future;
        written.add(items.single.text);
      }, documentId: 'group-A');
      final firstSave = editor.flush();
      await entered.future;
      editor.schedule(_draft('group B'), (items) async {
        written.add(items.single.text);
      }, documentId: 'group-B');
      final exit = DeferredSubtitleEdits.flushPendingForExit();
      release.complete();
      await firstSave;
      expect(await exit, isTrue);
      expect(written, ['group A', 'group B']);
    },
  );

  test(
    'independent document failure is retained when another owner succeeds',
    () async {
      final first = DeferredSubtitleEdits(), second = DeferredSubtitleEdits();
      final written = <String>[];
      var available = false;
      first.schedule(_draft('A recovered'), (items) async {
        if (!available) throw const FileSystemException('A offline');
        written.add(items.single.text);
      }, documentId: 'document-A');
      await expectLater(first.flush(), throwsA(isA<FileSystemException>()));
      second.schedule(_draft('B saved'), (items) async {
        written.add(items.single.text);
      }, documentId: 'document-B');
      await second.flush();
      expect(first.hasPending, isTrue);
      available = true;
      expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
      expect(written, ['B saved', 'A recovered']);
    },
  );

  test(
    'window exit saves the newest draft before its debounce fires',
    () async {
      final directory = await Directory.systemTemp.createTemp('subtitle_exit_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/last-edit.txt');
      final editor = DeferredSubtitleEdits();
      final entered = Completer<void>();
      final disk = Completer<void>();
      final written = <String>[];
      Future<void> save(List<SubtitleItem> subtitles) async {
        written.add(subtitles.single.text);
        entered.complete();
        await disk.future;
        await file.writeAsString(subtitles.single.text, flush: true);
      }

      editor.schedule(_draft('old'), save);
      editor.schedule(_draft('last keystroke'), save);
      var finished = false;
      final exit = DeferredSubtitleEdits.flushPendingForExit().then((value) {
        finished = true;
        return value;
      });
      await entered.future;
      expect(finished, isFalse);
      expect(await file.exists(), isFalse);
      disk.complete();
      expect(await exit, isTrue);
      expect(written, ['last keystroke']);
      expect(await file.readAsString(), 'last keystroke');
      expect(editor.hasPending, isFalse);
    },
  );

  test(
    'exit drains edits received while an earlier save is in flight',
    () async {
      final editor = DeferredSubtitleEdits();
      final entered = Completer<void>();
      final disk = Completer<void>();
      final written = <String>[];
      Future<void> save(List<SubtitleItem> subtitles) async {
        written.add(subtitles.single.text);
        if (written.length == 1) {
          entered.complete();
          await disk.future;
        }
      }

      editor.schedule(_draft('first'), save);
      final first = editor.flush();
      await entered.future;
      final exit = DeferredSubtitleEdits.flushPendingForExit();
      editor.schedule(_draft('newest'), save);
      disk.complete();
      await first;
      expect(await exit, isTrue);
      expect(written, ['first', 'newest']);
      expect(editor.hasPending, isFalse);
    },
  );

  test(
    'exit retains a failed draft and succeeds after storage recovers',
    () async {
      final editor = DeferredSubtitleEdits();
      var fail = true;
      final written = <String>[];
      editor.schedule(_draft('keep me'), (subtitles) async {
        if (fail) throw const FileSystemException('injected disk failure');
        written.add(subtitles.single.text);
      });
      final previous = FlutterError.onError;
      final errors = <FlutterErrorDetails>[];
      FlutterError.onError = errors.add;
      try {
        expect(await DeferredSubtitleEdits.flushPendingForExit(), isFalse);
        expect(editor.hasPending, isTrue);
        expect(written, isEmpty);
        expect(errors.single.exception, isA<FileSystemException>());
        fail = false;
        expect(await DeferredSubtitleEdits.flushPendingForExit(), isTrue);
        expect(written, ['keep me']);
        expect(editor.hasPending, isFalse);
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  test(
    'exit waits for independent editors, including a disposed editor save',
    () async {
      final first = DeferredSubtitleEdits();
      final second = DeferredSubtitleEdits();
      final written = <String>[];
      final gate = Completer<void>();
      final entered = Completer<void>();
      first.schedule(_draft('closed editor'), (subtitles) async {
        entered.complete();
        await gate.future;
        written.add(subtitles.single.text);
      });
      // Editors use this when their widget is disposed.
      first.flushInBackground();
      await entered.future;
      second.schedule(_draft('current editor'), (subtitles) async {
        written.add(subtitles.single.text);
      });
      final exit = DeferredSubtitleEdits.flushPendingForExit();
      gate.complete();
      expect(await exit, isTrue);
      expect(written, ['closed editor', 'current editor']);
    },
  );
}
