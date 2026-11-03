import 'package:flutter/material.dart';

import '../features/cloud_drive/presentation/cloud_drive_screen.dart';
import '../features/podcasts/podcast_pages.dart';
import '../models/home_search_request.dart';
import '../screens/bilibili/bilibili_home_page.dart';
import '../screens/collection_screen.dart';
import '../theme/app_page_transitions.dart';
import '../widgets/media_library_search_prompt.dart';
import '../widgets/media_library_shell.dart';

Widget homeSearchDestination(HomeSearchRequest request) =>
    switch (request.scope) {
      HomeSearchScope.library => CollectionScreen.search(query: request.query),
      HomeSearchScope.podcasts => PodcastLibrarySearchPage(
        initialQuery: request.query,
      ),
      HomeSearchScope.podcastSearch => PodcastDiscoverPage(
        initialQuery: request.query,
      ),
      HomeSearchScope.bilibili => BilibiliHomePage(
        isActive: true,
        initialKeyword: request.query,
        showAppBar: true,
      ),
      _ => CloudDriveScreen(
        initialProviderId: request.scope.name,
        initialQuery: request.query,
        popOnSearchBack: true,
      ),
    };

Future<void> openHomeSearchResults(
  BuildContext context,
  HomeSearchRequest request,
) async {
  if (request.scope == HomeSearchScope.library) {
    await Navigator.of(
      context,
    ).push(buildMediaLibrarySearchResultsRoute(homeSearchDestination(request)));
  } else {
    await pushAboveMediaLibrary<void>(
      context,
      AppMaterialPageRoute<void>(
        settings: RouteSettings(name: '/home-search/${request.scope.name}'),
        builder: (_) => homeSearchDestination(request),
      ),
    );
  }
}
