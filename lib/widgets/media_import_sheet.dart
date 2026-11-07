import 'package:flutter/material.dart';

import '../theme/app_typography.dart';

/// The existing import list on a brighter surface above the library.
Future<T?> showMediaImportSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0x59000000),
  elevation: 0,
  showDragHandle: false,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (context) => _MediaImportSurface(child: builder(context)),
);

class _MediaImportSurface extends StatelessWidget {
  const _MediaImportSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Material(
        color: const Color(0xFF32353B),
        surfaceTintColor: Colors.transparent,
        elevation: 20,
        shadowColor: const Color(0xB3000000),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
          side: BorderSide(color: Color(0x26FFFFFF)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: base.copyWith(
            iconTheme: base.iconTheme.copyWith(
              color: const Color(0xFFD9DFE9),
              size: 22,
            ),
            hoverColor: const Color(0x0DFFFFFF),
            highlightColor: const Color(0x12FFFFFF),
            focusColor: const Color(0x244B8EF0),
            listTileTheme: base.listTileTheme.copyWith(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              minLeadingWidth: 24,
              horizontalTitleGap: 14,
              minVerticalPadding: 10,
              minTileHeight: 58,
              titleAlignment: ListTileTitleAlignment.center,
              iconColor: const Color(0xFFD9DFE9),
              textColor: const Color(0xFFF0F2F6),
              titleTextStyle: base.textTheme.bodyLarge?.copyWith(
                color: const Color(0xFFF0F2F6),
                fontSize: 15,
                fontWeight: AppFontWeight.label,
                height: 1.4,
              ),
              subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFBEC4CE),
                fontSize: 12,
                fontWeight: AppFontWeight.reading,
                height: 1.4,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: child,
          ),
        ),
      ),
    );
  }
}
