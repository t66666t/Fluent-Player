import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_localizations.dart';

void main() {
  Future<String> copyLabelFor(WidgetTester tester, Locale locale) async {
    late String label;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: appLocalizationDelegates,
        supportedLocales: appSupportedLocales,
        home: Builder(
          builder: (context) {
            label = MaterialLocalizations.of(context).copyButtonLabel;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return label;
  }

  testWidgets('selection labels follow supported system locales', (
    tester,
  ) async {
    expect(await copyLabelFor(tester, const Locale('zh', 'CN')), '复制');
    expect(await copyLabelFor(tester, const Locale('en', 'US')), 'Copy');
    expect(await copyLabelFor(tester, const Locale('fr', 'FR')), 'Copier');
  });

  testWidgets('unsupported system locale falls back to English', (
    tester,
  ) async {
    expect(await copyLabelFor(tester, const Locale('zz', 'ZZ')), 'Copy');
  });
}
