import '../../theme/app_page_transitions.dart';
import '../../widgets/community_unavailable_page.dart';
class WebMediaBrowserRoute extends AppMaterialPageRoute<void> {
  WebMediaBrowserRoute({Uri? initialUrl, String? targetFolderId, Object? preferences, Object? session})
    : super(builder: (_) => const CommunityUnavailablePage());
}
