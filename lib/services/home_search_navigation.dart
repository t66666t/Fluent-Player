import 'package:flutter/material.dart';

import '../models/home_search_request.dart';
import '../screens/collection_screen.dart';
import '../widgets/media_library_search_prompt.dart';

/// Saved remote scopes now search local media instead of reopening retired pages.
Widget homeSearchDestination(HomeSearchRequest request) =>
    CollectionScreen.search(query: request.query);

Future<void> openHomeSearchResults(
  BuildContext context,
  HomeSearchRequest request,
) async {
  await Navigator.of(
    context,
  ).push(buildMediaLibrarySearchResultsRoute(homeSearchDestination(request)));
}
