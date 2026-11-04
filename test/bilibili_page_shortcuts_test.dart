import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

class _SearchApi extends BilibiliPublicApiService {
  int videoSearches = 0;
  final keywords = <String>[];
  int userSearches = 0;
  Completer<void>? pending;

  @override
  Future<BilibiliSearchPage<BilibiliSearchVideo>> searchVideos(
    String keyword, {
    int page = 1,
    BilibiliVideoSearchFilter filter = const BilibiliVideoSearchFilter(),
    DateTime? now,
  }) async {
    videoSearches++;
    keywords.add(keyword);
    await pending?.future;
    return BilibiliSearchPage(items: const [], page: page, numPages: 1);
  }

  @override
  Future<BilibiliSearchPage<BilibiliSearchUser>> searchUsers(
    String keyword, {
    int page = 1,
  }) async {
    userSearches++;
    return BilibiliSearchPage(items: const [], page: page, numPages: 1);
  }

  @override
  Future<List<String>> suggestKeywords(String keyword) async => const [];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
  });

  testWidgets(
    'a pushed keyword search runs once and returns via Escape or Back',
    (tester) async {
      final api = _SearchApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            pageTransitionsTheme: appPageTransitionsTheme,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                AppMaterialPageRoute<void>(
                  builder: (_) => BilibiliHomePage(
                    isActive: true,
                    initialKeyword: ' lesson ',
                    showAppBar: true,
                    api: api,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      for (final escape in [true, false]) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'lesson',
        );
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byType(BilibiliHomePage), findsNothing);
        expect(find.text('open'), findsOneWidget);
      }
      expect(api.keywords, ['lesson', 'lesson']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Bilibili search keys respect editing, busy state and dialogs', (
    tester,
  ) async {
    final api = _SearchApi();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: BilibiliHomePage(isActive: true, api: api)),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);
    for (final key in [
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.slash,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(navigator.currentState!.canPop(), isFalse);
    expect(api.videoSearches, 0);
    await tester.enterText(find.byType(TextField), 'lesson');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.videoSearches, 1);

    api.pending = Completer<void>();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(api.videoSearches, 2);
    api.pending!.complete();
    await tester.pumpAndSettle();
    api.pending = null;
    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    expect(api.userSearches, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect((api.videoSearches, api.userSearches), (2, 2));

    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(BilibiliHomePage)),
        builder: (_) => const AlertDialog(content: Text('modal')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(api.userSearches, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('inactive Bilibili root does not claim search keys', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BilibiliHomePage(isActive: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
