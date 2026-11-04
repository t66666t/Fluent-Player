import '../models/import_card_placement.dart';
import '../services/library_service.dart';
import '../utils/app_toast.dart';
import 'library_folder_picker.dart';

/// Background transfers use the root navigator when a rule asks for a target.
void installImportLocationPicker(LibraryService library) {
  library.importPlacementPicker = (feature, initial) async {
    final context = AppToast.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      throw const ImportPlacementException('请回到应用选择导入位置后重试，已下载内容仍保留');
    }
    if (initial != null &&
        !library.activityProjection.isVisibleCollection(initial)) {
      AppToast.show('原导入目标已不可用，请重新选择位置');
    }
    final result = await showLibraryFolderPicker(
      context,
      library: library,
      initialFolderId: initial,
      title: '${feature.label} · 选择导入位置',
      offerSetAsDefault: false,
    );
    return result == null
        ? null
        : ImportPlacementRequest.explicit(feature, result.folderId);
  };
}
