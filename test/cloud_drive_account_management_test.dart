import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_view_preferences.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'support/cloud_drive_fixture.dart';

const _credential = CloudDriveCredential(
  cookies: [
    CloudDriveCookie(
      name: 'session',
      value: 'another-account',
      domain: '.example.invalid',
    ),
  ],
);

Future<void> _openAccountMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('cloud-drive-account-menu')));
  await tester.pumpAndSettle();
}

Future<void> _requestRemoval(WidgetTester tester) async {
  await _openAccountMenu(tester);
  await tester.tap(find.text('移除当前账号'));
  await tester.pumpAndSettle();
}

Future<void> _showScreen(WidgetTester tester, CloudDriveRuntime runtime) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await runtime.shutdown();
  });
  await tester.pumpWidget(
    MaterialApp(home: CloudDriveScreen(runtime: runtime)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await MediaPlaybackService().stop();
  });

  for (final providerId in cloudDriveProviderNames.keys) {
    testWidgets(
      '$providerId account menu removes only the current account after confirmation',
      (tester) async {
        final runtime = await cloudRuntime([
          for (final id in cloudDriveProviderNames.keys)
            FixtureCloudProvider(id, {}),
        ]);
        final preferences = CloudDriveViewPreferences(
          await SharedPreferences.getInstance(),
        );
        await preferences.selectProvider(providerId);
        for (final account in runtime.accounts.accounts) {
          await preferences.selectAccount(account.providerId, account.localId);
        }
        final account = runtime.accounts.accounts.singleWhere(
          (a) => a.providerId == providerId,
        );
        final others = runtime.accounts.accounts
            .where((a) => a.providerId != providerId)
            .toList();
        await _showScreen(tester, runtime);

        await _requestRemoval(tester);
        expect(find.text('移除网盘账号'), findsOneWidget);
        expect(find.textContaining('网盘文件和观看记录会保留'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(runtime.accounts.findLocal(account.localId), isNotNull);
        expect(await runtime.accounts.credentialFor(account), isNotNull);
        expect(preferences.accountId(providerId), account.localId);

        await _requestRemoval(tester);
        await tester.tap(find.widgetWithText(TextButton, '移除'));
        await tester.pumpAndSettle();
        expect(runtime.accounts.findLocal(account.localId), isNull);
        expect(await runtime.accounts.credentialFor(account), isNull);
        expect(preferences.accountId(providerId), isNull);
        expect(find.text('添加网盘账号'), findsOneWidget);
        for (final other in others) {
          expect(runtime.accounts.findLocal(other.localId), isNotNull);
          expect(await runtime.accounts.credentialFor(other), isNotNull);
          expect(preferences.accountId(other.providerId), other.localId);
        }

        await _openAccountMenu(tester);
        expect(find.text('添加账号'), findsOneWidget);
        expect(find.text('移除当前账号'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('removing the selected account remembers the remaining account', (
    tester,
  ) async {
    final runtime = await cloudRuntime([FixtureCloudProvider('baidu', {})]);
    final remaining = runtime.accounts.accounts.single;
    final selected = await runtime.accounts.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'second',
      displayName: '第二个账号',
      credential: _credential,
    );
    final preferences = CloudDriveViewPreferences(
      await SharedPreferences.getInstance(),
    );
    await preferences.selectAccount('baidu', selected.localId);
    await _showScreen(tester, runtime);

    await _requestRemoval(tester);
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();
    expect(runtime.accounts.accounts.single.localId, remaining.localId);
    expect(preferences.accountId('baidu'), remaining.localId);
    expect(find.text(remaining.displayName), findsOneWidget);
    expect(find.text('添加网盘账号'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing another account in settings preserves the selection', (
    tester,
  ) async {
    final runtime = await cloudRuntime([FixtureCloudProvider('baidu', {})]);
    final removed = await runtime.accounts.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'second',
      displayName: '备用账号',
      credential: _credential,
    );
    final selected = await runtime.accounts.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'third',
      displayName: '当前账号',
      credential: _credential,
    );
    final preferences = CloudDriveViewPreferences(
      await SharedPreferences.getInstance(),
    );
    await preferences.selectAccount('baidu', selected.localId);
    await _showScreen(tester, runtime);

    await tester.tap(find.byTooltip('网盘设置 (P)'));
    await tester.pumpAndSettle();
    final row = find.widgetWithText(ListTile, removed.displayName);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('账号管理')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从本机移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();
    expect(runtime.accounts.findLocal(removed.localId), isNull);
    expect(find.text(removed.displayName), findsNothing);
    expect(preferences.accountId('baidu'), selected.localId);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(selected.displayName), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
