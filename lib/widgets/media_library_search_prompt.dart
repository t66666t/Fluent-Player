import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'keyboard_inset_padding.dart';
import '../models/home_search_request.dart';
import '../utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const _searchFontFamily = 'Noto Sans SC';

/// Folder search remains confined to the media library.
Future<String?> showMediaLibrarySearchPrompt(BuildContext context) async =>
    (await _showSearchPrompt(context))?.query;

/// Home search always searches the local media library.
Future<HomeSearchRequest?> showHomeSearchPrompt(BuildContext context) =>
    _showSearchPrompt(context);

Future<HomeSearchRequest?> _showSearchPrompt(BuildContext context) {
  return showGeneralDialog<HomeSearchRequest>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭搜索',
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) {
      return const _MediaLibrarySearchPrompt();
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final eased = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.04),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

/// Route name of a search results page, so the library frame can tell when
/// one is on top.
const String mediaLibrarySearchResultsRouteName =
    'media-library-search-results';

Route<void> buildMediaLibrarySearchResultsRoute(Widget page) {
  return AppMaterialPageRoute<void>(
    builder: (_) => page,
    settings: const RouteSettings(name: mediaLibrarySearchResultsRouteName),
  );
}

/// Search results read in Noto Sans SC, the mini player over them included.
ThemeData mediaLibrarySearchResultsTheme(ThemeData base) {
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Noto Sans SC'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Noto Sans SC'),
  );
}

class _MediaLibrarySearchPrompt extends StatefulWidget {
  const _MediaLibrarySearchPrompt();

  @override
  State<_MediaLibrarySearchPrompt> createState() =>
      _MediaLibrarySearchPromptState();
}

class _MediaLibrarySearchPromptState extends State<_MediaLibrarySearchPrompt> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode(debugLabel: 'MediaSearchInput');
  bool _canSubmit = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  void _submit() {
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final query = _controller.text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (query.isEmpty || _submitted) return;
    _submitted = true;
    _inputFocusNode.unfocus();
    Navigator.of(
      context,
    ).pop(HomeSearchRequest(scope: HomeSearchScope.library, query: query));
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    // Keep the prompt pinned over the app bar on every form factor. The IME
    // only reduces its maximum available height; a normal one-line prompt does
    // not move at all when the keyboard appears.
    final outerHorizontal = isCompact ? 12.0 : 24.0;

    final baseTheme = Theme.of(context);
    final searchTheme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: _searchFontFamily),
      primaryTextTheme: baseTheme.primaryTextTheme.apply(
        fontFamily: _searchFontFamily,
      ),
    );

    return Theme(
      data: searchTheme,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (isEditableTextComposing()) return;
            Navigator.of(context).maybePop();
          },
        },
        child: KeyboardInsetPadding(
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                outerHorizontal,
                isCompact ? 6.0 : 8.0,
                outerHorizontal,
                isCompact ? 10.0 : 24.0,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxPanelHeight = constraints.maxHeight;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 720,
                        maxHeight: maxPanelHeight,
                      ),
                      child: Material(
                        key: const ValueKey('media-search-panel'),
                        color: const Color(0xFF242426),
                        elevation: 18,
                        shadowColor: Colors.black.withValues(alpha: 0.48),
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            isCompact ? 22 : 18,
                          ),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: SingleChildScrollView(
                          key: const ValueKey('media-search-content'),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              isCompact ? 14 : 18,
                              isCompact ? 14 : 16,
                              isCompact ? 12 : 14,
                              isCompact ? 14 : 16,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 2,
                                    bottom: 10,
                                  ),
                                  child: Text(
                                    '搜索媒体库',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: _searchFontFamily,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight: 50,
                                        ),
                                        child: TextField(
                                          controller: _controller,
                                          focusNode: _inputFocusNode,
                                          autofocus: true,
                                          minLines: 1,
                                          maxLines: 1,
                                          textAlignVertical:
                                              const TextAlignVertical(y: -0.08),
                                          keyboardType: TextInputType.text,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .singleLineFormatter,
                                          ],
                                          textInputAction:
                                              TextInputAction.search,
                                          onSubmitted: (_) => _submit(),
                                          scrollPadding: const EdgeInsets.only(
                                            bottom: 28,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontFamily: _searchFontFamily,
                                            fontSize: 17,
                                            height: 1.45,
                                          ),
                                          decoration: InputDecoration(
                                            hintText:
                                                HomeSearchScope.library.hint,
                                            hintStyle: const TextStyle(
                                              color: Colors.white38,
                                              fontFamily: _searchFontFamily,
                                            ),
                                            prefixIcon: const Padding(
                                              padding: EdgeInsets.only(
                                                left: 10,
                                                right: 6,
                                              ),
                                              child: Center(
                                                child: SizedBox.square(
                                                  dimension: 22,
                                                  child: Icon(
                                                    Icons.search_rounded,
                                                    size: 22,
                                                    color: Colors.white54,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            prefixIconConstraints:
                                                const BoxConstraints.tightFor(
                                                  width: 38,
                                                  height: 50,
                                                ),
                                            filled: true,
                                            fillColor: Colors.black.withValues(
                                              alpha: 0.24,
                                            ),
                                            // Flutter reserves a 4 px internal gap
                                            // before EditableText. A 10/6 px prefix
                                            // inset compensates for it, yielding 10 px
                                            // on both visible sides of the icon.
                                            // Asymmetric
                                            // vertical padding optically raises both
                                            // entered and hint text by one pixel.
                                            contentPadding:
                                                const EdgeInsets.fromLTRB(
                                                  0,
                                                  12,
                                                  14,
                                                  14,
                                                ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide.none,
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide(
                                                color: Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                              ),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: const BorderSide(
                                                color: Color(0xFF5EA6FF),
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Semantics(
                                      button: true,
                                      label: '确认搜索',
                                      child: SizedBox.square(
                                        key: const ValueKey(
                                          'media-search-submit',
                                        ),
                                        dimension: 50,
                                        child: DesktopButtonClickRegion(
                                          child: IconButton.filled(
                                            onPressed: _canSubmit
                                                ? _submit
                                                : null,
                                            tooltip: _isDesktop
                                                ? '搜索（Enter）'
                                                : '搜索',
                                            style: IconButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF147CE5,
                                              ),
                                              disabledBackgroundColor:
                                                  Colors.white10,
                                              foregroundColor: Colors.white,
                                              disabledForegroundColor:
                                                  Colors.white30,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                            ),
                                            icon: const Icon(
                                              Icons.arrow_forward_rounded,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
