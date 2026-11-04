import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/app_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all additional license entries can load their shipped text', () async {
    registerAppLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final names = entries.expand((entry) => entry.packages).toSet();
    expect(
      names,
      containsAll([
        'Fluent Player (GPL-3.0-or-later)',
        'MiSans',
        'ASR native dependencies',
        'Optional UnRAR tool',
        'Python',
        'QuickJS-NG',
      ]),
    );
    expect(
      entries.every(
        (entry) => entry.paragraphs.any((p) => p.text.trim().isNotEmpty),
      ),
      isTrue,
    );
    expect(await rootBundle.loadString('PRIVACY.md'), isNotEmpty);
    expect(await rootBundle.loadString('THIRD_PARTY_NOTICES.md'), isNotEmpty);
  });
}
