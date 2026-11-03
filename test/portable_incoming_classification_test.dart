import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_navigation.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';

void main() {
  test('classifies fluentpack by extension case-insensitively', () {
    expect(
      PortableIncomingClassification.kindForFileName('Backup.FLUENTPACK'),
      PortableIncomingFileKind.fluentpack,
    );
    expect(
      PortableIncomingClassification.isPackagePath(r'C:\packs\library.fluentpack'),
      isTrue,
    );
    expect(
      PortableTransferService.hasPackageExtension('library.fluentpack.zip'),
      isFalse,
    );
  });

  test('does not treat zip archives as fluentpack', () {
    expect(
      PortableIncomingClassification.kindForFileName('media.zip'),
      PortableIncomingFileKind.archive,
    );
    expect(
      PortableIncomingClassification.isPackagePath('media.zip'),
      isFalse,
    );
  });

  test('rejects mixed fluentpack + media or archive drops', () {
    expect(
      PortableIncomingClassification.isMixed(
        hasFluentPack: true,
        hasOtherSupported: true,
      ),
      isTrue,
    );
    expect(
      PortableIncomingClassification.isMixed(
        hasFluentPack: true,
        hasOtherSupported: false,
      ),
      isFalse,
    );
    expect(
      PortableIncomingClassification.dropMixMessage,
      contains('FluentPack'),
    );
    expect(
      PortableIncomingClassification.shareMixMessage,
      contains('FluentPack'),
    );
  });

  test('fromPath keeps the original file name as displayName', () {
    final source = PortableImportSource.fromPath(
      r'D:\exports\Family 2026.fluentpack',
    );
    expect(source.displayName, 'Family 2026.fluentpack');
    expect(source.ownedTemporaryCopy, isFalse);
  });
}
