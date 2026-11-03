import '../../theme/app_page_transitions.dart';
import '../../widgets/community_unavailable_page.dart';
class DouyinDownloadScreen extends CommunityUnavailablePage {
  const DouyinDownloadScreen({super.key, String? initialInput, String? targetFolderId});
}
class DouyinDownloadRoute extends AppMaterialPageRoute<void> {
  DouyinDownloadRoute({String? initialInput, String? targetFolderId})
    : super(builder: (_) => const CommunityUnavailablePage());
}
