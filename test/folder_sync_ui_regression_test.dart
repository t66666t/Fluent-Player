import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_request_prompt.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_settings_sheet.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/services/library_service.dart';

class _Sync extends ProgressSyncService {
  _Sync()
    : super(
        library: LibraryService(),
        store: MemoryProgressSyncStore(),
        enableNetwork: false,
      );
  final requests = <FolderTransferTask>[];
  @override
  List<FolderTransferTask> get folderTransfers => requests;
  void changed() => notifyListeners();
}

FolderTransferTask _request(String id) => FolderTransferTask(
  id: id,
  direction: FolderTransferDirection.receive,
  peerId: 'peer',
  peerName: 'Computer',
  sourceCollectionId: id,
  folderName: id,
  createdAt: DateTime(2026),
  phase: FolderTransferPhase.offered,
);

void main() {
  testWidgets(
    'request banners queue and disappear when requests are cancelled',
    (tester) async {
      final sync = _Sync();
      final first = _request('first');
      final second = _request('second');
      sync.requests.add(first);
      await tester.pumpWidget(
        ChangeNotifierProvider<ProgressSyncService>.value(
          value: sync,
          child: const MaterialApp(
            home: Scaffold(
              body: FolderSyncRequestPrompt(child: SizedBox.expand()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Computer想与你同步「first」'), findsOneWidget);
      sync.requests.add(second);
      sync.changed();
      await tester.pump();
      expect(find.text('Computer想与你同步「first」'), findsOneWidget);
      expect(find.text('Computer想与你同步「second」'), findsNothing);
      first.phase = FolderTransferPhase.cancelled;
      sync.changed();
      await tester.pump();
      expect(find.text('Computer想与你同步「first」'), findsNothing);
      expect(find.text('Computer想与你同步「second」'), findsOneWidget);
      second.phase = FolderTransferPhase.cancelled;
      sync.changed();
      await tester.pump();
      expect(find.text('Computer想与你同步「second」'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
    },
  );

  testWidgets('missing one-way authority requires explicit source selection', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FolderSyncSettingsForm(
              initial: const FolderSyncSettings(
                mode: FolderSyncMode.oneWay,
                sourceDeviceId: 'removed-peer',
              ),
              devices: const {'local': 'Computer', 'phone': 'Phone'},
              localDeviceId: 'local',
              onSave: (_) async {
                saves++;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('请选择内容来源设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
