import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Framework-provided locales used by native text-selection toolbars.
///
/// English is deliberately first so an unsupported system locale falls back
/// to English without changing the app's existing hard-coded interface text.
final List<Locale> appSupportedLocales = <Locale>[
  const Locale('en'),
  const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  const Locale('zh', 'CN'),
  const Locale('zh', 'HK'),
  const Locale('zh', 'TW'),
  for (final String languageCode in kMaterialSupportedLanguages)
    if (languageCode != 'en' && languageCode != 'zh') Locale(languageCode),
];

Iterable<LocalizationsDelegate<dynamic>> get appLocalizationDelegates =>
    GlobalMaterialLocalizations.delegates;
