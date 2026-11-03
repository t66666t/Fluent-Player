import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'keyboard_inset_padding.dart';
import 'home_search_scope_menu.dart';
import '../models/home_search_request.dart';
import '../services/home_search_preferences.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/cloud_drive/models/cloud_drive_models.dart';
import '../features/cloud_drive/services/cloud_drive_account_repository.dart';
import '../features/cloud_drive/services/cloud_drive_startup.dart';
import '../utils/page_shortcut_keys.dart';
import '../features/cloud_drive/presentation/cloud_drive_screen.dart'
    show CloudDriveLoginRoute;
import 'operation_status.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const _searchFontFamily = 'Noto Sans SC';

/// Folder search remains confined to the media library.
Future<String?> showMediaLibrarySearchPrompt(BuildContext context) async =>
    (await _showSearchPrompt(context))?.query;

/// Home search restores its scope before painting the dialog so the icon
/// and label never flash the default scope on a warm or cold opening.
Future<HomeSearchRequest?> showHomeSearchPrompt(BuildContext context) async {
  HomeSearchPreferences? preferences;
  try {
    preferences = HomeSearchPreferences(await SharedPreferences.getInstance());
  } catch (error) {
    debugPrint('Unable to read home search scope: $error');
  }
  if (!context.mounted) return null;
  return _showSearchPrompt(
    context,
    preferences: preferences,
    enableScopeChooser: true,
  );
}

Future<HomeSearchRequest?> _showSearchPrompt(
  BuildContext context, {
  bool enableScopeChooser = false,
  HomeSearchPreferences? preferences,
}) {
  return showGeneralDialog<HomeSearchRequest>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭搜索',
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _MediaLibrarySearchPrompt(
        enableScopeChooser: enableScopeChooser,
        preferences: preferences,
      );
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
  const _MediaLibrarySearchPrompt({
    required this.enableScopeChooser,
    this.preferences,
  });

  final bool enableScopeChooser;
  final HomeSearchPreferences? preferences;

  @override
  State<_MediaLibrarySearchPrompt> createState() =>
      _MediaLibrarySearchPromptState();
}

class _MediaLibrarySearchPromptState extends State<_MediaLibrarySearchPrompt> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode(debugLabel: 'MediaSearchInput');
  bool _canSubmit = false;
  HomeSearchScope _scope = HomeSearchScope.library;
  bool _scopeMenuOpen = false;
  final GlobalKey _scopeAnchor = GlobalKey();
  CloudDriveAccountRepository? _accounts;
  bool _submitted = false;
  bool _loggingIn = false;
  String? _scopeError;
  Object? _scopeDiagnostic;

  bool get _cloudUnavailable =>
      _scope.isCloud &&
      (_accounts == null || !_signedInProviders.contains(_scope.name));

  Set<String> get _signedInProviders =>
      _accounts?.accounts
          .where((a) => a.authState != CloudDriveAuthState.needsLogin)
          .map((a) => a.providerId)
          .toSet() ??
      <String>{};

  void _bindAccounts() {
    if (!mounted || !widget.enableScopeChooser) return;
    final accounts = CloudDriveRuntime.instance?.accounts;
    if (!identical(accounts, _accounts)) {
      _accounts?.sessionChanges.removeListener(_accountsChanged);
      _accounts = accounts;
      accounts?.sessionChanges.addListener(_accountsChanged);
    }
    // An expired account must never silently change what the user searches.
  }

  void _accountsChanged() {
    if (mounted) setState(_bindAccounts);
  }

  Future<void> _loginScope() async {
    if (_loggingIn || !_scope.isCloud) return;
    final scope = _scope;
    setState(() {
      _loggingIn = true;
      _scopeError = null;
      _scopeDiagnostic = null;
    });
    try {
      final runtime = await CloudDriveRuntime.ensureInstalled();
      final provider = runtime.providers[scope.name];
      if (provider == null) throw StateError('搜索服务尚未就绪');
      if (!mounted) return;
      await Navigator.of(context).push<CloudDriveAccount>(
        CloudDriveLoginRoute(provider: provider, accounts: runtime.accounts),
      );
      if (mounted) {
        setState(_bindAccounts);
        _inputFocusNode.requestFocus();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _scopeError = '暂时无法打开网盘登录，请稍后重试。';
          _scopeDiagnostic = error;
        });
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _rememberScope(HomeSearchScope scope) async {
    try {
      await widget.preferences?.select(scope);
    } catch (error) {
      debugPrint('Unable to save home search scope: $error');
    }
  }

  Future<void> _chooseScope({bool keyboardNavigation = false}) async {
    if (_scopeMenuOpen) return;
    final box = _scopeAnchor.currentContext!.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _scopeMenuOpen = true);
    final scope = await showHomeSearchScopeMenu(
      context,
      anchor: anchor,
      selected: _scope,
      signedInProviders: _signedInProviders,
      keyboardNavigation: keyboardNavigation,
    );
    if (!mounted) return;
    setState(() {
      _scopeMenuOpen = false;
      if (scope != null) _scope = scope;
      _scopeError = null;
      _scopeDiagnostic = null;
      _bindAccounts();
    });
    if (scope != null) {
      unawaited(_rememberScope(_scope));
    }
    _inputFocusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _scope = widget.preferences?.scope ?? HomeSearchScope.library;
    _bindAccounts();
    if (widget.enableScopeChooser && _accounts == null) {
      unawaited(
        CloudDriveStartup.pending?.then<void>((_) {
          if (mounted) setState(_bindAccounts);
        }, onError: (Object _, StackTrace _) {}),
      );
    }
    _controller.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _accounts?.sessionChanges.removeListener(_accountsChanged);
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
    if (query.isEmpty || _submitted || _cloudUnavailable) return;
    _submitted = true;
    _inputFocusNode.unfocus();
    Navigator.of(context).pop(HomeSearchRequest(scope: _scope, query: query));
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
          if (widget.enableScopeChooser)
            _OpenScopeActivator(
              () => !_scopeMenuOpen && !isEditableTextComposing(),
            ): () =>
                unawaited(_chooseScope(keyboardNavigation: true)),
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
                                    widget.enableScopeChooser
                                        ? '${_scope.label} · 搜索'
                                        : '搜索媒体库',
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
                                            hintText: _scope.hint,
                                            hintStyle: const TextStyle(
                                              color: Colors.white38,
                                              fontFamily: _searchFontFamily,
                                            ),
                                            prefixIcon:
                                                widget.enableScopeChooser
                                                ? Tooltip(
                                                    message:
                                                        '选择搜索范围：${_scope.label}',
                                                    child: Semantics(
                                                      expanded: _scopeMenuOpen,
                                                      child: DesktopButtonClickRegion(
                                                        child: IconButton(
                                                          key: _scopeAnchor,
                                                          onPressed:
                                                              _chooseScope,
                                                          style: IconButton.styleFrom(
                                                            minimumSize:
                                                                const Size(
                                                                  40,
                                                                  36,
                                                                ),
                                                            fixedSize:
                                                                const Size(
                                                                  40,
                                                                  36,
                                                                ),
                                                            padding:
                                                                EdgeInsets.zero,
                                                            visualDensity:
                                                                VisualDensity
                                                                    .standard,
                                                            tapTargetSize:
                                                                MaterialTapTargetSize
                                                                    .padded,
                                                            hoverColor: Colors
                                                                .white
                                                                .withValues(
                                                                  alpha: 0.04,
                                                                ),
                                                            focusColor:
                                                                const Color(
                                                                  0x1A88BEFF,
                                                                ),
                                                            highlightColor:
                                                                Colors.white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.08,
                                                                    ),
                                                            shape: RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    10,
                                                                  ),
                                                            ),
                                                            foregroundColor:
                                                                _scopeMenuOpen
                                                                ? const Color(
                                                                    0xFF88BEFF,
                                                                  )
                                                                : Colors
                                                                      .white60,
                                                          ),
                                                          icon: SizedBox(
                                                            width: 40,
                                                            height: 36,
                                                            // Center the type icon itself; the disclosure
                                                            // indicator must not affect its alignment.
                                                            child: Stack(
                                                              alignment:
                                                                  Alignment
                                                                      .center,
                                                              children: [
                                                                AnimatedSwitcher(
                                                                  duration:
                                                                      MediaQuery.disableAnimationsOf(
                                                                        context,
                                                                      )
                                                                      ? Duration
                                                                            .zero
                                                                      : const Duration(
                                                                          milliseconds:
                                                                              160,
                                                                        ),
                                                                  child: Icon(
                                                                    _scope ==
                                                                            HomeSearchScope.library
                                                                        ? Icons
                                                                              .search_rounded
                                                                        : _scope
                                                                              .icon,
                                                                    key: ValueKey(
                                                                      _scope,
                                                                    ),
                                                                    size: 20,
                                                                  ),
                                                                ),
                                                                Positioned(
                                                                  right: 0,
                                                                  top: 0,
                                                                  bottom: 0,
                                                                  child: Center(
                                                                    child: AnimatedRotation(
                                                                      turns:
                                                                          _scopeMenuOpen
                                                                          ? .5
                                                                          : 0,
                                                                      duration:
                                                                          MediaQuery.disableAnimationsOf(
                                                                            context,
                                                                          )
                                                                          ? Duration.zero
                                                                          : const Duration(
                                                                              milliseconds: 200,
                                                                            ),
                                                                      curve: Curves
                                                                          .easeOutCubic,
                                                                      child: const Icon(
                                                                        key: ValueKey(
                                                                          'home-search-scope-chevron',
                                                                        ),
                                                                        Icons
                                                                            .expand_more_rounded,
                                                                        size:
                                                                            10,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : const Padding(
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
                                                BoxConstraints.tightFor(
                                                  width:
                                                      widget.enableScopeChooser
                                                      ? 48
                                                      : 38,
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
                                            onPressed:
                                                _canSubmit && !_cloudUnavailable
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
                                if (_cloudUnavailable ||
                                    _scopeError != null) ...[
                                  const SizedBox(height: 14),
                                  OperationStatus(
                                    title:
                                        _scopeError ??
                                        (_loggingIn
                                            ? '正在打开登录…'
                                            : '${_scope.label}尚未登录'),
                                    kind: _loggingIn
                                        ? OperationStatusKind.progress
                                        : _scopeError != null
                                        ? OperationStatusKind.error
                                        : OperationStatusKind.info,
                                    details: _scopeDiagnostic?.toString(),
                                    actions: [
                                      DesktopButtonClickRegion(
                                        child: TextButton.icon(
                                          onPressed: _loggingIn
                                              ? null
                                              : _loginScope,
                                          icon: const Icon(
                                            Icons.login,
                                            size: 18,
                                          ),
                                          label: Text('登录${_scope.label}'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
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

/// Plain Down opens the scope picker while editing. Composition and modified
/// arrows continue through to the input's own shortcuts.
class _OpenScopeActivator extends SingleActivator {
  _OpenScopeActivator(this.canOpen)
    : super(LogicalKeyboardKey.arrowDown, includeRepeats: false);

  final bool Function() canOpen;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      canOpen() && super.accepts(event, state);
}
