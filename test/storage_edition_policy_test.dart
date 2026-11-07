import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_presentation.dart';

void main() {
  test(
    'community storage offers local and RSS sources and preserves legacy files',
    () {
      expect(
        storageSourceFilters,
        containsAll([
          StorageSourceFilter.local,
          StorageSourceFilter.podcast,
          StorageSourceFilter.legacy,
        ]),
      );
      for (final source in [
        StorageSourceFilter.bilibili,
        StorageSourceFilter.cloudDrive,
        StorageSourceFilter.website,
      ]) {
        expect(storageSourceFilters, isNot(contains(source)));
      }
      expect(StorageCategory.models.title, '本地模型');
      expect(StorageCategory.materialized.title, '转写与合成素材');
    },
  );
}
