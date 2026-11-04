import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/home_search_request.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/services/home_search_navigation.dart';
import 'package:video_player_app/services/home_search_preferences.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'saved remote and malformed scopes resolve to the local library',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final search = HomeSearchPreferences(preferences);
      for (final scope in HomeSearchScope.values) {
        await preferences.setString(HomeSearchPreferences.scopeKey, scope.name);
        expect(search.scope, HomeSearchScope.library);
        await search.select(scope);
        expect(
          preferences.getString(HomeSearchPreferences.scopeKey),
          'library',
        );
      }
      await preferences.setString(
        HomeSearchPreferences.scopeKey,
        'retired-scope',
      );
      expect(search.scope, HomeSearchScope.library);
      await preferences.setInt(HomeSearchPreferences.scopeKey, 2);
      expect(search.scope, HomeSearchScope.library);
    },
  );

  test('every compatibility request searches the local collection', () {
    for (final scope in HomeSearchScope.values) {
      final page = homeSearchDestination(
        HomeSearchRequest(scope: scope, query: '本地课程'),
      );
      expect(page, isA<CollectionScreen>());
      expect((page as CollectionScreen).searchQuery, '本地课程');
    }
  });

  for (final scope in HomeSearchScope.values) {
    testWidgets(
      '${scope.name} saved scope submits a local search without a chooser',
      (tester) async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(HomeSearchPreferences.scopeKey, scope.name);
        HomeSearchRequest? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showHomeSearchPrompt(context),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('搜索媒体库'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-search-scope-menu')),
          findsNothing,
        );
        expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
        await tester.enterText(find.byType(TextField), '  保留关键词  ');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(result!.scope, HomeSearchScope.library);
        expect(result!.query, '保留关键词');
        // Opening search leaves the previous user preference untouched.
        expect(
          preferences.getString(HomeSearchPreferences.scopeKey),
          scope.name,
        );
      },
    );
  }

  testWidgets(
    'cancel and reopen retain local scope without changing saved data',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(HomeSearchPreferences.scopeKey, 'bilibili');
      HomeSearchRequest? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showHomeSearchPrompt(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'cancelled draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(preferences.getString(HomeSearchPreferences.scopeKey), 'bilibili');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('搜索媒体库'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    },
  );
}
