import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'desktop_button_click_region.dart';
import 'media_library_settings_list.dart';

/// One ordered list. Changing its width never reparents a setting's state.
class MediaLibrarySettingsPage extends StatefulWidget {
  const MediaLibrarySettingsPage({super.key, required this.items});

  final List<Widget> items;

  @override
  State<MediaLibrarySettingsPage> createState() =>
      _MediaLibrarySettingsPageState();
}

class _MediaLibrarySettingsPageState extends State<MediaLibrarySettingsPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final inset = width < 600 ? 12.0 : 24.0;
    final contentWidth = math.min(1280.0, math.max(0.0, width - inset * 2));
    final headerInset = (width - contentWidth) / 2;
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        iconTheme: const IconThemeData(color: AppTokens.text2, size: 18),
        listTileTheme: base.listTileTheme.copyWith(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          minTileHeight: 56,
          minVerticalPadding: 10,
          horizontalTitleGap: 8,
          titleTextStyle: base.textTheme.bodyLarge?.copyWith(
            color: AppTokens.text1,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        appBar: AppBar(
          backgroundColor: AppTokens.bgBase,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 64,
          titleSpacing: 0,
          leadingWidth: headerInset + 40,
          leading: Padding(
            padding: EdgeInsets.only(left: math.max(0, headerInset - 8)),
            child: DesktopButtonClickRegion(
              child: BackButton(onPressed: () => Navigator.of(context).pop()),
            ),
          ),
          title: const Text('媒体库设置'),
          titleTextStyle: base.textTheme.titleLarge?.copyWith(
            color: AppTokens.text1,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available = math.min(
                1280.0,
                math.max(0.0, constraints.maxWidth - inset * 2),
              );
              final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
              final columns = available >= 960 * scale ? 2 : 1;
              return Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const PageStorageKey('media-library-all-settings'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 24),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: available,
                      child: MediaLibrarySettingsList(
                        items: widget.items,
                        columns: columns,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
