import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _LoggedInApi extends BilibiliApiService {
  @override
  Future<void> init() async {}

  @override
  Future<BilibiliLoginState> fetchLoginState() async =>
      const BilibiliLoginState(
        BilibiliLoginStatus.loggedIn,
        account: BilibiliAccountInfo(mid: 9527, name: '山间漫游', avatarUrl: ''),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['BILIBILI_READONLY_PREVIEW'] == '1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({'bilibiliAccountReadOnly': false});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
    await SettingsService().init();
    if (preview) {
      await (FontLoader('BilibiliPreview')..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  'assets/fonts/NotoSansCJKsc-Regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  for (final profile in [
    (name: 'phone', size: const Size(360, 780), scale: 1.0),
    (name: 'large-text', size: const Size(320, 740), scale: 1.5),
    (name: 'landscape', size: const Size(640, 360), scale: 1.0),
    (name: 'desktop', size: const Size(840, 800), scale: 1.0),
  ]) {
    for (final account in [false, true]) {
      final page = account ? 'account' : 'settings';
      testWidgets('$page fits ${profile.name} without account mode controls', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = profile.name == 'desktop'
            ? TargetPlatform.windows
            : TargetPlatform.android;
        await tester.binding.setSurfaceSize(profile.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: preview ? 'BilibiliPreview' : null,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(profile.scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundaryKey,
              child: account
                  ? BilibiliAccountScreen(api: _LoggedInApi())
                  : const BilibiliSettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('账号只读模式'), findsNothing);
        expect(
          find.byKey(const ValueKey('bilibili-setting-read-only')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('bilibili-account-read-only')),
          findsNothing,
        );
        if (account) {
          expect(find.text('山间漫游'), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const ValueKey('bilibili-account-network-settings')),
          );
        } else {
          expect(find.text('账号'), findsNothing);
          await tester.ensureVisible(
            find.byKey(const ValueKey('bilibili-setting-watch-history')),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (preview) {
          // Return to the top before capturing the complete entry layout.
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          scroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File(
              '.artifacts/bilibili-readonly/$page-${profile.name}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
