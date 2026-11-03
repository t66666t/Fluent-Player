import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../services/library_service.dart';

/// Compare immutable revision values, never the mutable VideoItem identity.
class LibraryCardRebuild extends StatelessWidget {
  const LibraryCardRebuild({
    super.key,
    required this.itemId,
    required this.builder,
  });
  final String itemId;
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) {
    context.select<LibraryService?, (int, int)?>(
      (library) => library?.cardRevision(itemId),
    );
    return builder(context);
  }
}
