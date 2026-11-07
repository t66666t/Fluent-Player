import 'dart:async';
import 'package:video_player_app/utils/app_branding.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_screen.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';

class _StorageProbe extends StorageAuditService {
  _StorageProbe()
    : super(
        buildInput: () async => const StorageScanInput(roots: []),
        deletionBlockedReason: () => null,
      );

  int scans = 0;
  final pending = Completer<StorageSnapshot>();

  @override
  Future<StorageSnapshot> scan({void Function(int, int)? onProgress}) {
    scans++;
    return pending.future;
  }
}

class _CacheProbe extends ChangeNotifier implements MediaCacheService {
  final paused = <String>[];
  final resumed = <String>[];
  final entries = [
    for (final id in ['one', 'two'])
      CacheTask(
        id: id,
        source: CacheSource(
          ref: MediaSourceRef(
            value: 'BV$id',
            kind: MediaSourceKind.bilibiliStream,
            bvid: 'BV$id',
            cid: 1,
          ),
          itemId: id,
          title: id,
          kind: MediaType.video,
        ),
        createdAt: 1,
        state: CacheTaskState.paused,
      ),
  ];

  @override
  bool get ready => true;
  @override
  List<CacheTask> get tasks => entries;
  @override
  List<CacheVariant> get variants => [];
  @override
  String? get loadError => null;
  @override
  String? get persistenceError => null;
  @override
  int get runningCount => entries.where((task) => task.state.running).length;
  @override
  double get bytesPerSecond => 0;
  @override
  int get cachedBytes => 0;
  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause(
    String id, {
    CacheTaskState state = CacheTaskState.paused,
  }) async {
    paused.add(id);
    entries.firstWhere((task) => task.id == id).state = state;
    notifyListeners();
  }

  @override
  Future<void> resume(String id) async {
    resumed.add(id);
    entries.firstWhere((task) => task.id == id).state = CacheTaskState.queued;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('storage shortcuts preserve busy and modal route guards', (
    tester,
  ) async {
    final service = _StorageProbe();
    final snapshot = StorageSnapshot(
      scannedAt: DateTime(2026, 10, 27),
      roots: const [],
      files: const [],
      warnings: const [],
    );
    final navigator = GlobalKey<NavigatorState>();
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StorageManagementScreen(
          service: service,
          initialSnapshot: snapshot,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(clipboard, contains('$kAppDisplayName 存储诊断'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(service.scans, 1);
    service.pending.complete(snapshot);
    await tester.pumpAndSettle();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('覆盖页面')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    clipboard = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(clipboard, isNull);
    expect(service.scans, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cache commands protect input and toggle only filtered tasks', (
    tester,
  ) async {
    final service = _CacheProbe();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(home: MediaCacheScreen(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    final input = find.byType(TextField);
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.enterText(input, 'one');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(service.resumed, isEmpty);
    expect(service.paused, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(service.resumed, ['one']);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(service.paused, ['one']);
    await tester.tap(find.text('已缓存 0'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(service.resumed, ['one']);
    expect(service.paused, ['one']);
    expect(tester.takeException(), isNull);
  });
}
