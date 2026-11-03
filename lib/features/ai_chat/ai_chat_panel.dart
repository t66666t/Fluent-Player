import '../../utils/keyboard_shortcut_hints.dart';
import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/subtitle_model.dart';
import '../../models/video_item.dart';
import '../../services/settings_service.dart';
import '../../services/app_haptics.dart';
import '../../widgets/bilibili_subtitle_tracks_section.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_copy.dart';
import 'ai_chat_draft_binding.dart';
import 'ai_chat_models.dart';
import 'ai_chat_reading_state.dart';
import 'ai_chat_session.dart';
import 'ai_chat_settings.dart';
import 'ai_agent_catalog.dart';
import 'ai_context_dialog.dart';
import 'ai_settings_dialog.dart';
import 'ai_markdown.dart';
import 'ai_video_context.dart';
import 'ai_chat_layout.dart';
import 'ai_message_navigation.dart';
import 'ai_scroll_to_latest_button.dart';
import 'ai_capsule_menu.dart';
import 'ai_chat_toolbar.dart';
import 'ai_chat_typography.dart';
import 'ai_usage_widgets.dart';
import 'ai_compaction_dialog.dart';
import 'ai_quick_prompts.dart';
import 'ai_quick_prompts_dialog.dart';
import '../youtube_download/services/yt_dlp_download_service.dart';
import '../youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Tests that drive the panel with [WidgetTester.pumpAndSettle] turn this off.
/// A focused desktop composer blinks a cursor, so settle never goes idle.
@visibleForTesting
bool debugAiChatDesktopAutofocus = true;

/// Optional fullscreen view of the conversation. The playback panel and its
/// controller remain mounted underneath, so generation and playback continue.
Future<void> showAiChatPage(
  BuildContext context, {
  required VideoItem videoItem,
  List<SubtitleItem> primarySubtitles = const [],
  List<SubtitleItem> secondarySubtitles = const [],
  String? primaryPath,
  String? secondaryPath,
  Duration position = Duration.zero,
  ValueListenable<Duration>? positionListenable,
  ValueChanged<Duration>? onSeek,
  AiChatController? controller,
  TextEditingController? inputController,
  AiQuickPromptStore? quickPromptStore,
  AiMessageBookmark? initialBookmark,
  bool followOutput = true,
  void Function(AiMessageBookmark?, bool)? onReadingPosition,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  // Dialog.fullscreen also consumes viewInsets. Use the route's full surface
  // directly, leaving the shared viewport as the sole owner of avoidance.
  builder: (context) => AiChatFullscreenSurface(
    child: AiChatPanel(
      videoItem: videoItem,
      primarySubtitles: primarySubtitles,
      secondarySubtitles: secondarySubtitles,
      primaryPath: primaryPath,
      secondaryPath: secondaryPath,
      position: position,
      positionListenable: positionListenable,
      onSeek: onSeek,
      controller: controller,
      inputController: inputController,
      quickPromptStore: quickPromptStore,
      initialBookmark: initialBookmark,
      followOutput: followOutput,
      onReadingPosition: onReadingPosition,
      isFullscreen: true,
      onExitFullscreen: () {
        unawaited(AppHaptics.lightTap(SettingsService()));
        Navigator.pop(context);
      },
      onClose: () {
        unawaited(AppHaptics.lightTap(SettingsService()));
        Navigator.pop(context);
      },
    ),
  ),
);

/// Shared fullscreen shell for video and music conversations. The keyboard
/// viewport alone owns inset avoidance, including on phones in landscape.
class AiChatFullscreenSurface extends StatelessWidget {
  const AiChatFullscreenSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: aiChatTheme(Theme.of(context)),
    child: Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: AiKeyboardViewport(
          reservedBottomInset: MediaQuery.viewPaddingOf(context).bottom,
          child: child,
        ),
      ),
    ),
  );
}

class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    super.key,
    required this.videoItem,
    this.primarySubtitles = const <SubtitleItem>[],
    this.secondarySubtitles = const <SubtitleItem>[],
    this.position = Duration.zero,
    this.primaryPath,
    this.secondaryPath,
    this.onClose,
    this.onBack,
    this.onBackToSubtitles,
    this.isVisible = true,
    this.onSeek,
    this.positionListenable,
    this.controller,
    this.inputController,
    this.quickPromptStore,
    this.sessions,
    this.isFullscreen = false,
    this.fullscreenReturnLabel,
    this.onExitFullscreen,
    this.initialBookmark,
    this.followOutput = true,
    this.onReadingPosition,
  });

  final VideoItem videoItem;
  final List<SubtitleItem> primarySubtitles;
  final List<SubtitleItem> secondarySubtitles;
  final Duration position;
  final String? primaryPath;
  final String? secondaryPath;
  final VoidCallback? onClose;

  /// Close the tool and restore the panel that opened it.
  final VoidCallback? onBack;
  final VoidCallback? onBackToSubtitles;
  final bool isVisible;
  final ValueChanged<Duration>? onSeek;
  final ValueListenable<Duration>? positionListenable;
  final AiChatController? controller;
  final TextEditingController? inputController;
  final AiQuickPromptStore? quickPromptStore;

  /// When [controller] is omitted, the panel borrows the process-lifetime
  /// session from here (or [AiChatSessions.instance]). Tests pass their own.
  final AiChatSessions? sessions;
  final bool isFullscreen;

  /// A fullscreen host that returns directly to playback can name that action.
  final String? fullscreenReturnLabel;
  final VoidCallback? onExitFullscreen;
  final AiMessageBookmark? initialBookmark;
  final bool followOutput;
  final void Function(AiMessageBookmark?, bool)? onReadingPosition;

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  late final AiChatController _controller;
  late final AiQuickPromptStore _quickPrompts;

  /// Follows the open item, so a video podcast is not labeled as a plain video.
  AiChatMediaCopy get _media => AiChatMediaCopy.of(widget.videoItem);
  late final TextEditingController _input;
  late final AiChatDraftBinding _draftBinding;
  late final bool _usesSession;
  late final bool _ownsInput;

  /// Desktop entry focus waits until the field is enabled, which is after
  /// the session finishes loading.
  bool _needsEntryFocus = false;
  String? _seenConversationId;
  late int _readingVisit;
  final Object _readingOwner = Object();
  AiMessageBookmark? _entryBookmark;
  bool _entryAtEnd = true;
  bool _restoringReading = false;
  bool _routeCurrent = true;
  final _inputFocus = FocusNode(debugLabel: 'AiChatComposer');
  final _toolbarMenuAnchor = GlobalKey();
  final _scroll = AiMessageViewportController();
  final Set<String> _expandedReasoning = {};
  int _messagePresentationRevision = 0;
  final _awayNotifier = ValueNotifier<bool>(false);
  bool get _awayFromBottom => _awayNotifier.value;
  set _awayFromBottom(bool value) => _awayNotifier.value = value;
  bool _followOutput = true;
  bool _scrollingDown = false;
  bool _bottomScheduled = false;
  bool _fullscreenOpen = false;
  bool _sending = false;
  bool _narrowMessages = false;
  Widget? _cachedContent;
  Object? _cachedLayout;
  ThemeData? _cachedTheme;
  ThemeData? _baseTheme;
  ThemeData? _chatTheme;

  void _updateUi(VoidCallback update) {
    _cachedContent = null;
    setState(update);
  }

  @override
  void initState() {
    super.initState();
    _quickPrompts = widget.quickPromptStore ?? AiQuickPromptStore.instance;
    _quickPrompts.addListener(_readingSettingsChanged);
    unawaited(_quickPrompts.load());
    AiChatReadingSettings.instance.addListener(_readingSettingsChanged);
    unawaited(AiChatReadingSettings.instance.load());
    _followOutput = widget.followOutput;
    _usesSession = widget.controller == null;
    if (_usesSession) {
      // The panel is a view. Closing it must not cancel the reply.
      final session = (widget.sessions ?? AiChatSessions.instance).retain(
        video: widget.videoItem,
        createLoader: AiVideoContextLoader.new,
      );
      _controller = session.controller;
      _input = widget.inputController ?? session.input;
      _ownsInput = false;
      _bindPlaybackSources();
    } else {
      _controller = widget.controller!;
      _ownsInput = widget.inputController == null;
      _input = widget.inputController ?? TextEditingController();
    }
    _readingVisit = _controller.readingState.visit;
    _draftBinding = AiChatDraftBinding.retain(_controller, _input);
    _resumeReadingPosition(initial: true);
    _controller.addListener(_changed);
    _seenConversationId = _controller.active?.id;
    final pendingDraft = _controller.takeDraft();
    if (pendingDraft != null) {
      _input.text = pendingDraft;
      _input.selection = TextSelection.collapsed(offset: pendingDraft.length);
    }
    _scroll.addListener(_scrollChanged);
    _inputFocus.onKeyEvent = _handleComposerKey;
    unawaited(_attachSession());
    if (_desktopComposer) {
      if (_controller.ready) {
        _focusComposer();
      } else {
        _needsEntryFocus = true;
      }
    }
  }

  void _saveReadingPosition({bool leaving = false}) {
    if (_restoringReading ||
        _fullscreenOpen ||
        !_routeCurrent ||
        (!widget.isVisible && !leaving) ||
        !_scroll.hasClients) {
      return;
    }
    _controller.readingState.save(
      _readingOwner,
      _readingVisit,
      AiChatReadingPosition(
        bookmark: _scroll.bookmark,
        atEnd: _followOutput && !_scroll.awayFromBottom,
        followOutput: _followOutput,
        expandedReasoning: _expandedReasoning,
      ),
    );
  }

  void _resumeReadingPosition({bool initial = false}) {
    final reading = _controller.readingState;
    final saved = reading.position;
    if (!initial &&
        !_restoringReading &&
        _readingVisit == reading.visit &&
        reading.isOwnedBy(_readingOwner) &&
        _scroll.hasClients) {
      // A menu/dialog or a hidden mounted panel keeps its live viewport. Reusing
      // a fractional bookmark here would move the text if its answer grew while
      // covered. A different conversation or fullscreen owner still restores.
      _followOutput = saved?.followOutput ?? _followOutput;
      _cachedContent = null;
      if (_followOutput) _bottom();
      return;
    }
    final explicit = initial ? widget.initialBookmark : null;
    final bookmark = explicit ?? saved?.bookmark;
    final validBookmark =
        bookmark != null &&
        (_controller.active?.messages.any((m) => m.id == bookmark.messageId) ??
            false);
    _entryAtEnd = explicit != null
        ? (saved?.atEnd ?? false)
        : (saved?.atEnd ?? true);
    if (!_entryAtEnd && !validBookmark) _entryAtEnd = true;
    _entryBookmark = _entryAtEnd ? null : bookmark;
    _followOutput =
        _entryAtEnd &&
        (saved?.followOutput ?? (initial ? widget.followOutput : true));
    _expandedReasoning
      ..clear()
      ..addAll(saved?.expandedReasoning ?? const <String>{});
    _messagePresentationRevision++;
    _readingVisit = reading.visit;
    _seenConversationId = _controller.active?.id;
    _awayFromBottom = !_entryAtEnd;
    _restoringReading = true;
    _cachedContent = null;
    if (widget.isVisible && !_fullscreenOpen) reading.claim(_readingOwner);
    final visit = _readingVisit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_restoringReading ||
          !widget.isVisible ||
          !_routeCurrent ||
          _fullscreenOpen ||
          visit != _readingVisit ||
          visit != reading.visit) {
        return;
      }
      if (!initial) {
        if (_entryAtEnd) {
          _scroll.scrollToEnd();
        } else if (_entryBookmark != null) {
          _scroll.restore(_entryBookmark!);
        }
      }
      // Fractional anchors can need a second layout after their lazy message
      // mounts. Do not let that intermediate geometry overwrite the snapshot.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || visit != _readingVisit || visit != reading.visit) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || visit != _readingVisit || visit != reading.visit) {
            return;
          }
          _restoringReading = false;
          _saveReadingPosition();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent == current) return;
    if (!current) {
      _saveReadingPosition(leaving: true);
      unawaited(_controller.flushDrafts());
    }
    _routeCurrent = current;
    if (current && widget.isVisible && !_fullscreenOpen) {
      _resumeReadingPosition();
    }
  }

  /// Desktop keyboards should land in the composer. Phones keep the keyboard
  /// closed until the field is tapped.
  bool get _desktopComposer =>
      debugAiChatDesktopAutofocus &&
      const {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (!widget.isVisible ||
        _fullscreenOpen ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    // Leave Ctrl, Option/Alt and Command chords to the platform's editor.
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final value = _input.value;
    // Enter confirms an IME candidate; Escape dismisses it. Neither should
    // submit a draft or navigate away while composition is active.
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !keyboard.isShiftPressed) {
      final leave = widget.isFullscreen
          ? widget.onExitFullscreen ?? widget.onClose
          : widget.onBack ?? widget.onBackToSubtitles ?? widget.onClose;
      if (leave == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) leave();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // Handle physical keyboards on phones and tablets as well as desktops.
    // Consume repeats so holding Enter never submits twice or leaks a newline.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (keyboard.isShiftPressed) {
      final selection = value.selection;
      final range = selection.isValid
          ? TextRange(start: selection.start, end: selection.end)
          : TextRange.collapsed(value.text.length);
      final next = value
          .replaced(range, '\n')
          .copyWith(
            selection: TextSelection.collapsed(offset: range.start + 1),
            composing: TextRange.empty,
          );
      // Use the editor's update path so selection and undo stay consistent,
      // and consume the event to prevent a second native newline.
      final editor = node.context?.findAncestorStateOfType<EditableTextState>();
      if (editor != null) {
        editor.userUpdateTextEditingValue(next, SelectionChangedCause.keyboard);
      } else {
        _input.value = next;
      }
    } else {
      unawaited(_send(keepInputFocus: true));
    }
    return KeyEventResult.handled;
  }

  String get _sendShortcutHint {
    if (!KeyboardShortcutHints.of(context)) return '发送';
    final apple =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final enter = apple ? 'Return' : 'Enter';
    return '$enter 发送 · Shift+$enter 换行';
  }

  void _focusComposer({int attempt = 0, bool untilFocused = false}) {
    if (!_desktopComposer) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isVisible || _fullscreenOpen) return;
      // A player tap registered in the same frame can hand focus back to the
      // video. Keep asking until this field actually holds it.
      if (untilFocused && _inputFocus.hasFocus) return;
      if (!_controller.ready) {
        _needsEntryFocus = true;
        return;
      }
      // The field may not be attached on the first frame after the sidebar opens.
      if (_inputFocus.context == null || !_inputFocus.canRequestFocus) {
        if (attempt < 8) {
          _focusComposer(attempt: attempt + 1, untilFocused: untilFocused);
        }
        return;
      }
      _inputFocus.requestFocus();
      if (untilFocused && attempt < 3) {
        _focusComposer(attempt: attempt + 1, untilFocused: true);
      }
    });
  }

  void _bindPlaybackSources() {
    if (!_usesSession) return;
    final host = this;
    _controller.bindContext((loader) {
      loader.bindPlaybackSources(
        bilibiliTracks: bilibiliSubtitleTracksFor(context, widget.videoItem),
        ytDlpTasks: () {
          if (!host.mounted) return const <YtDlpTaskRecord>[];
          try {
            return host.context.read<YtDlpDownloadService>().tasks;
          } catch (_) {
            return const <YtDlpTaskRecord>[];
          }
        },
      );
    });
  }

  /// Join a chat that may already be streaming, then point context at this view.
  Future<void> _attachSession() async {
    if (!_usesSession) {
      if (!_controller.ready) await _refresh(initial: true);
      return;
    }
    final joined = _controller.initializationStarted || _controller.ready;
    if (!_controller.ready) {
      await _controller.initialize(
        primarySubtitles: widget.primarySubtitles,
        secondarySubtitles: widget.secondarySubtitles,
        primaryPath: widget.primaryPath,
        secondaryPath: widget.secondaryPath,
        position: _subtitlePosition,
      );
    }
    if (!mounted) return;
    // The first initializer already loaded context. A later view, or a chat
    // that kept running with no view, needs the subtitles on screen now.
    if (joined) await _refresh();
  }

  @override
  void didUpdateWidget(AiChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible && !widget.isVisible) {
      unawaited(_controller.flushDrafts());
      _saveReadingPosition(leaving: true);
      _followOutput = false;
      _cachedContent = null;
      _inputFocus.unfocus();
    }
    if (!oldWidget.isVisible && widget.isVisible) {
      _resumeReadingPosition();
      _focusComposer();
    }
    if (oldWidget.videoItem != widget.videoItem ||
        oldWidget.isFullscreen != widget.isFullscreen ||
        oldWidget.fullscreenReturnLabel != widget.fullscreenReturnLabel ||
        (oldWidget.onBackToSubtitles == null) !=
            (widget.onBackToSubtitles == null) ||
        (oldWidget.onBack == null) != (widget.onBack == null) ||
        (oldWidget.onClose == null) != (widget.onClose == null) ||
        (oldWidget.onSeek == null) != (widget.onSeek == null)) {
      _cachedContent = null;
    }
    if (_usesSession && oldWidget.videoItem != widget.videoItem) {
      _controller.adoptVideo(widget.videoItem);
      _bindPlaybackSources();
    }
    if (oldWidget.primarySubtitles != widget.primarySubtitles ||
        oldWidget.secondarySubtitles != widget.secondarySubtitles ||
        oldWidget.primaryPath != widget.primaryPath ||
        oldWidget.secondaryPath != widget.secondaryPath) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh({
    bool initial = false,
    bool retryOnlineSources = false,
  }) async {
    if (initial) {
      await _controller.initialize(
        primarySubtitles: widget.primarySubtitles,
        secondarySubtitles: widget.secondarySubtitles,
        primaryPath: widget.primaryPath,
        secondaryPath: widget.secondaryPath,
        position: _subtitlePosition,
      );
    } else {
      await _controller.refreshContext(
        retryOnlineSources: retryOnlineSources,
        primarySubtitles: widget.primarySubtitles,
        secondarySubtitles: widget.secondarySubtitles,
        primaryPath: widget.primaryPath,
        secondaryPath: widget.secondaryPath,
        position: _subtitlePosition,
      );
    }
  }

  Duration get _subtitlePosition {
    final raw =
        (widget.positionListenable?.value ?? widget.position) -
        SettingsService().subtitleOffset;
    return raw < Duration.zero ? Duration.zero : raw;
  }

  void _seekSubtitle(Duration value) {
    if (widget.onSeek == null) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    widget.onSeek!(value + SettingsService().subtitleOffset);
  }

  void _scrollChanged() {
    _saveReadingPosition();
    widget.onReadingPosition?.call(_scroll.bookmark, _followOutput);
    final away = _scroll.hasClients && _scroll.awayFromBottom;
    final changed = away != _awayFromBottom;
    if (!_restoringReading && changed && mounted) {
      _awayFromBottom = away;
    }
  }

  bool _userScrolled(UserScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.direction != ScrollDirection.idle) {
      _restoringReading = false;
    }
    // Extent changes from reasoning expansion or streamed Markdown are not
    // user intent. Only a deliberate downward scroll back to the end resumes
    // following; an upward gesture stops even within the bottom threshold.
    if (notification.direction == ScrollDirection.forward) {
      _scrollingDown = false;
      _followOutput = false;
    } else if (notification.direction == ScrollDirection.reverse) {
      _scrollingDown = true;
      // Let the user's drag and its ballistic activity finish before resuming
      // automatic jumps, even when a gesture starts close to the tail.
      _followOutput = false;
    } else if (_scrollingDown) {
      _scrollingDown = false;
      _followOutput = notification.metrics.extentAfter <= 24;
    }
    return false;
  }

  void _changed() {
    // Only the visible view consumes edit drafts and rebuilds streamed content.
    if (!mounted || !widget.isVisible || !_routeCurrent || _fullscreenOpen) {
      return;
    }
    final focusEntry = _needsEntryFocus && _controller.ready;
    if (focusEntry) _needsEntryFocus = false;
    final nextConversationId = _controller.active?.id;
    final openedConversation = _readingVisit != _controller.readingState.visit;
    if (openedConversation) _resumeReadingPosition();
    _seenConversationId = nextConversationId;
    final draft = _controller.takeDraft();
    if (draft != null) {
      _input.text = draft;
      _input.selection = TextSelection.collapsed(offset: draft.length);
      _inputFocus.requestFocus();
    }
    _updateUi(() {});
    if (focusEntry || openedConversation) _focusComposer();
    if (_followOutput && !_restoringReading) _bottom();
  }

  void _bottom({bool force = false}) {
    if (force) {
      _restoringReading = false;
      _scrollingDown = false;
      _followOutput = true;
    }
    if (!widget.isVisible || !_followOutput || (_bottomScheduled && !force)) {
      return;
    }
    _bottomScheduled = true;
    final visit = _readingVisit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomScheduled = false;
      // Recheck after layout: a gesture or a reasoning toggle may have happened
      // after this callback was queued by a streaming delta.
      if (!mounted ||
          !widget.isVisible ||
          !_scroll.hasClients ||
          !_followOutput ||
          (_scroll.isUserScrolling && !force) ||
          visit != _controller.readingState.visit ||
          !_routeCurrent ||
          _fullscreenOpen) {
        return;
      }
      _scroll.scrollToEnd();
    });
  }

  Future<void> _send({String? suggestion, bool keepInputFocus = false}) async {
    if (!_controller.ready || _controller.busy || _sending) return;
    final submittedDraft = suggestion == null ? _input.text : null;
    final question = (suggestion ?? submittedDraft!).trim();
    if (question.isEmpty) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    final conversationId = _controller.active?.id;
    _updateUi(() => _sending = true);
    try {
      await _refresh();
      if (!mounted) return;
      if (_controller.active?.id != conversationId) {
        _notice('对话已切换，草稿已保留在原对话');
        return;
      }
      _followOutput = true;
      _awayFromBottom = false;
      final sending = _controller.send(
        question,
        submittedDraft: submittedDraft,
        onAccepted: () {
          // Pointer sends move into reading mode. Keyboard sends retain their
          // existing focus; never request it back from another control.
          if (!keepInputFocus && mounted && _inputFocus.hasFocus) {
            _inputFocus.unfocus();
          }
        },
      );
      _updateUi(() => _sending = false);
      await sending;
    } catch (error) {
      if (mounted) {
        _notice(error.toString());
      }
    } finally {
      if (mounted) _updateUi(() => _sending = false);
    }
  }

  void _notice(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  VoidCallback? _feedback(VoidCallback? action) => action == null
      ? null
      : () {
          unawaited(AppHaptics.lightTap(SettingsService()));
          action();
        };

  /// Copies without a confirmation snackbar. The bottom "已复制" bar was noisy.
  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) unawaited(AppHaptics.lightTap(SettingsService()));
  }

  void _readingSettingsChanged() {
    if (mounted) _updateUi(() {});
  }

  @override
  void dispose() {
    _quickPrompts.removeListener(_readingSettingsChanged);
    AiChatReadingSettings.instance.removeListener(_readingSettingsChanged);
    _saveReadingPosition();
    widget.onReadingPosition?.call(_scroll.bookmark, _followOutput);
    _controller.removeListener(_changed);
    _draftBinding.release();
    // Session controllers stop only when the app shuts down. An injected
    // controller belongs to the caller, so this view never disposes it.
    if (_ownsInput) _input.dispose();
    _inputFocus.dispose();
    _awayNotifier.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startNewConversation() async {
    if (!_controller.ready || _controller.managing) return;
    await _controller.createConversation();
    if (!mounted) return;
    _followOutput = true;
    _awayFromBottom = false;
  }

  Future<void> _newConversation() async {
    await _startNewConversation();
    if (!mounted) return;
    _focusComposer();
  }

  Future<void> _fullscreen() async {
    if (_fullscreenOpen) return;
    _saveReadingPosition();
    _inputFocus.unfocus();
    final following = _followOutput;
    final bookmark = _scroll.bookmark;
    _followOutput = false;
    _fullscreenOpen = true;
    try {
      await showAiChatPage(
        context,
        videoItem: widget.videoItem,
        primarySubtitles: widget.primarySubtitles,
        secondarySubtitles: widget.secondarySubtitles,
        primaryPath: widget.primaryPath,
        secondaryPath: widget.secondaryPath,
        position: widget.position,
        positionListenable: widget.positionListenable,
        onSeek: widget.onSeek,
        controller: _controller,
        inputController: _input,
        quickPromptStore: _quickPrompts,
        initialBookmark: bookmark,
        followOutput: following,
      );
    } finally {
      _fullscreenOpen = false;
      if (mounted) {
        _resumeReadingPosition();
        _updateUi(() {});
        _focusComposer();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    if (_baseTheme != baseTheme) {
      _baseTheme = baseTheme;
      _chatTheme = aiChatTheme(baseTheme);
    }
    return Theme(
      data: _chatTheme!,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final typography = AiChatTextMetrics.resolve(
            panelWidth: constraints.maxWidth,
            screen: MediaQuery.sizeOf(context),
            fullscreen: widget.isFullscreen,
            scale: AiChatReadingSettings.instance.value,
          );
          final compact =
              constraints.maxHeight < 480 || constraints.maxWidth < 600;
          final narrow = constraints.maxWidth < 280;
          _narrowMessages = narrow;
          final layout = (
            typography,
            MediaQuery.textScalerOf(context),
            compact,
            narrow,
            constraints.maxHeight >= 120,
            constraints.maxHeight >= 220,
            constraints.maxHeight >= 280,
            constraints.maxHeight >= 320,
            constraints.maxHeight >= 440,
          );
          // Keyboard animation and sidebar dragging change constraints every
          // frame. Reuse content until a responsive breakpoint changes, rather
          // than reparsing
          // the same Markdown on every animation tick.
          final theme = Theme.of(context);
          if (_cachedLayout == layout &&
              _cachedTheme == theme &&
              _cachedContent != null) {
            return _cachedContent!;
          }
          _cachedLayout = layout;
          _cachedTheme = theme;
          final colors = Theme.of(context).colorScheme;
          final active = _controller.active;
          final hasPendingReply =
              active != null &&
              active.messages.isNotEmpty &&
              active.messages.last.role == 'assistant' &&
              active.messages.last.status == 'streaming';
          final tracks =
              _controller.videoContext?.tracks ?? const <AiSubtitleTrack>[];
          final selected = tracks
              .where((t) => _controller.selectedTrackIds.contains(t.id))
              .length;
          return _cachedContent = AiChatTypography(
            metrics: typography,
            child: Builder(
              builder: (context) => Material(
                color: colors.surface,
                child: Column(
                  children: [
                    if (constraints.maxHeight >= 120)
                      ValueListenableBuilder<int>(
                        valueListenable: _controller.draftRevision,
                        builder: (context, revision, child) {
                          final active = _controller.active;
                          return AiChatToolbar(
                            availableHeight: constraints.maxHeight,
                            title: active == null
                                ? widget.videoItem.title
                                : '${active.displayTitle}${active.hasDraft ? ' · 草稿' : ''}',
                            model: _controller.settings.backend == AiBackend.api
                                ? _controller.settings.model
                                : _controller.settings.backend.label,
                            selectedSources: selected,
                            sourceCount: tracks.length,
                            sourcesLabel: _media.sources,
                            isFullscreen: widget.isFullscreen,
                            fullscreenReturnLabel: widget.fullscreenReturnLabel,
                            onBack: widget.onBack ?? widget.onBackToSubtitles,
                            backLabel: widget.onBack != null ? '返回' : '返回字幕',
                            onClose: widget.onClose,
                            onNew: _controller.ready && !_controller.managing
                                ? _feedback(() => unawaited(_newConversation()))
                                : null,
                            onHistory: _controller.ready
                                ? _feedback(() => _history(context))
                                : null,
                            onSettings: _controller.ready
                                ? _feedback(() => _settings(context))
                                : null,
                            onContext: _controller.ready
                                ? _feedback(() => _contextDialog(context))
                                : null,
                            onFullscreen: widget.isFullscreen
                                ? widget.onExitFullscreen ?? widget.onClose
                                : (_controller.ready
                                      ? _feedback(_fullscreen)
                                      : null),
                            contextMeter: (compact) => AiContextMeter(
                              controller: _controller,
                              input: _input,
                              compact: compact,
                            ),
                            menu:
                                ({
                                  required history,
                                  required settings,
                                  required fullscreen,
                                  required sources,
                                  required newConversation,
                                  required close,
                                }) => _toolbarMenu(
                                  context,
                                  history: history,
                                  settings: settings,
                                  fullscreen: fullscreen,
                                  sources: sources,
                                  newConversation: newConversation,
                                  close: close,
                                ),
                          );
                        },
                      ),
                    if (!_controller.ready)
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 3,
                        ),
                        child: Text('正在加载对话…', style: TextStyle(fontSize: 11)),
                      ),
                    if (_controller.preparationStatus != null &&
                        !hasPendingReply)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 3,
                        ),
                        child: Text(
                          _controller.preparationStatus!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    if (_controller.error != null &&
                        constraints.maxHeight >= 220)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () =>
                              _details(context, '请求失败', _controller.error!),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 16,
                                color: colors.error,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _controller.error!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (active == null || active.messages.isEmpty)
                            _welcome(context)
                          else
                            AiMessageViewport(
                              key: ValueKey((
                                _seenConversationId,
                                _readingVisit,
                              )),
                              messages: active.messages,
                              controller: _scroll,
                              initialBookmark: _entryBookmark,
                              initialAtEnd: _entryAtEnd,
                              presentationKey: (
                                _messagePresentationRevision,
                                _controller.managing,
                                widget.onSeek != null,
                                typography,
                                narrow,
                              ),
                              followOutput: _followOutput,
                              isFollowingOutput: () =>
                                  _followOutput &&
                                  widget.isVisible &&
                                  _routeCurrent &&
                                  !_fullscreenOpen,
                              itemBuilder: _message,
                              onUserScrollStart: () {
                                _restoringReading = false;
                                _followOutput = false;
                                _scrollingDown = false;
                              },
                              onUserScroll: _userScrolled,
                              onNavigate: () {
                                _restoringReading = false;
                                _followOutput = false;
                                _scrollingDown = false;
                              },
                              onReachedEnd: () {
                                _followOutput = true;
                                _scrollingDown = false;
                              },
                            ),
                          ValueListenableBuilder<bool>(
                            valueListenable: _awayNotifier,
                            builder: (context, away, _) => away
                                ? Positioned.fill(
                                    child: AiScrollToLatestButton(
                                      onPressed: _feedback(
                                        () => _bottom(force: true),
                                      )!,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                    if (_controller.responseWarning != null &&
                        constraints.maxHeight >= 280)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _controller.responseWarning!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: TextButton(
                                onPressed: _controller.busy
                                    ? null
                                    : () => _controller.send(
                                        '继续完成上一条回答，从中断处接着写，不重复已写的内容。',
                                      ),
                                child: const Text('继续生成'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    _composer(
                      context,
                      compact: compact,
                      minimal: constraints.maxHeight < 280,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _details(BuildContext context, String title, String text) =>
      showDialog<void>(
        context: context,
        builder: (context) => AiAdaptiveDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      );
  Widget _toolbarMenu(
    BuildContext context, {
    required bool history,
    required bool settings,
    required bool fullscreen,
    required bool sources,
    required bool newConversation,
    required bool close,
  }) => AiCapsuleIconMenu<String>(
    key: _toolbarMenuAnchor,
    tooltip: '更多对话操作',
    icon: Icons.more_horiz,
    enabled: _controller.ready,
    feedbackOnSelection: false,
    items: () {
      final active = _controller.active;
      return [
        if (newConversation)
          AiCapsuleChoice(
            value: 'new',
            label: '新建对话',
            enabled: !_controller.managing,
          ),
        if (history) const AiCapsuleChoice(value: 'history', label: '对话历史'),
        if (settings) const AiCapsuleChoice(value: 'settings', label: 'AI 设置'),
        const AiCapsuleChoice(value: 'prompts', label: '管理提示词'),
        const AiCapsuleChoice(value: 'reading', label: '阅读设置 · 字体大小'),
        AiCapsuleChoice(
          value: 'compact',
          label: '压缩上下文',
          enabled: !_controller.busy && active != null,
        ),
        if (_controller.contextCheckpoint != null)
          const AiCapsuleChoice(value: 'summary', label: '查看对话摘要'),
        if (sources) AiCapsuleChoice(value: 'context', label: _media.sources),
        if (fullscreen)
          const AiCapsuleChoice(value: 'fullscreen', label: '全屏对话'),
        if (close) const AiCapsuleChoice(value: 'close', label: '关闭 AI 对话'),
        if (!widget.isFullscreen &&
            widget.onBack != null &&
            widget.onBackToSubtitles != null)
          const AiCapsuleChoice(value: 'subtitles', label: '返回字幕'),
        if (_controller.lastRequest != null || _controller.lastUsage != null)
          const AiCapsuleChoice(value: 'info', label: '对话提示与用量'),
        if (_controller.error != null)
          const AiCapsuleChoice(value: 'error', label: '查看请求错误'),
        if (active?.parentConversationId != null &&
            _controller.conversations.any(
              (c) => c.id == active!.parentConversationId,
            ))
          AiCapsuleChoice(
            value: 'source',
            label: '查看源对话',
            enabled: !_controller.managing,
          ),
        const AiCapsuleChoice(value: 'developer', label: '开发者模式'),
      ];
    },
    onSelected: (value) {
      if (!mounted) return;
      // These two callbacks delegate to the player's navigation feedback.
      if (value != 'close' && value != 'subtitles') {
        unawaited(AppHaptics.lightTap(SettingsService()));
      }
      switch (value) {
        case 'new':
          unawaited(_newConversation());
        case 'history':
          unawaited(_history(context));
        case 'compact':
        case 'summary':
          unawaited(showAiCompactionDialog(context, _controller));
        case 'settings':
          unawaited(_settings(context));
        case 'prompts':
          unawaited(_manageQuickPrompts(context));
        case 'reading':
          unawaited(
            showAiChatReadingSettings(
              context,
              metrics: AiChatTypography.of(context),
              anchorContext: _toolbarMenuAnchor.currentContext,
            ),
          );
        case 'context':
          unawaited(_contextDialog(context));
        case 'fullscreen':
          unawaited(_fullscreen());
        case 'close':
          widget.onClose?.call();
        case 'subtitles':
          widget.onBackToSubtitles?.call();
        case 'info':
          unawaited(_warnings(context));
        case 'error':
          unawaited(_details(context, '请求失败', _controller.error!));
        case 'source':
          final source = _controller.active?.parentConversationId;
          if (source != null) unawaited(_controller.selectConversation(source));
        case 'developer':
          unawaited(_developer(context));
      }
    },
  );

  Widget _icon(String label, IconData icon, VoidCallback? onPressed) =>
      DesktopButtonClickRegion(
        child: IconButton(
          tooltip: label,
          icon: Icon(icon),
          iconSize: 19,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          padding: const EdgeInsets.all(6),
          onPressed: onPressed,
        ),
      );

  Future<void> _warnings(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AiAdaptiveDialog(
      title: const Text('对话提示与用量'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * .6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_controller.lastUsage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SelectableText(
                    'Token 用量：${_controller.lastUsage!['total_tokens'] ?? '—'}\n'
                    '输入：${_controller.lastUsage!['prompt_tokens'] ?? '—'} · 输出：${_controller.lastUsage!['completion_tokens'] ?? '—'}',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              for (final warning
                  in _controller.lastRequest?.warnings ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                    warning,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ),
      ],
    ),
  );

  Future<void> _manageQuickPrompts(BuildContext context) async {
    _inputFocus.unfocus();
    await showAiQuickPrompts(context, store: _quickPrompts, media: _media);
  }

  Widget _welcome(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final typography = AiChatTypography.of(context);
    return SingleChildScrollView(
      padding: typography.dense
          ? const EdgeInsets.fromLTRB(10, 10, 10, 8)
          : const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _media.askTitle,
                style: TextStyle(
                  fontSize: typography.heading2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '已按字幕选择准备资料，可以直接提问。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: DesktopButtonClickRegion(
                  child: TextButton.icon(
                    key: const ValueKey('ai-quick-prompts-manage'),
                    onPressed: _feedback(() => _manageQuickPrompts(context)),
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('管理提示词'),
                  ),
                ),
              ),
              if (_quickPrompts.entries.isEmpty)
                Text(
                  '暂无预设提示词，可在“管理提示词”中添加。',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              for (final entry in _quickPrompts.entries)
                DesktopButtonClickRegion(
                  child: TextButton(
                    key: ValueKey('ai-quick-prompt-${entry.id}'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        vertical: typography.dense ? 6 : 10,
                        horizontal: 0,
                      ),
                    ),
                    onPressed: _controller.ready
                        ? () {
                            final text = entry.textFor(_media);
                            if (_input.text != text) {
                              unawaited(
                                AppHaptics.selectionClick(SettingsService()),
                              );
                            }
                            _input.value = TextEditingValue(
                              text: text,
                              selection: TextSelection.collapsed(
                                offset: text.length,
                              ),
                            );
                            if (_desktopComposer) {
                              // Enter-to-send is handled by this field.
                              _focusComposer(untilFocused: true);
                            } else {
                              // Phones keep the soft keyboard closed.
                              _inputFocus.unfocus();
                            }
                          }
                        : null,
                    child: Row(
                      children: [
                        Icon(switch (entry.id) {
                          'summary' => Icons.notes_outlined,
                          'explain' => Icons.help_outline,
                          'key-points' => Icons.bookmark_outline,
                          'notes' => Icons.menu_book_outlined,
                          _ => Icons.chat_bubble_outline,
                        }, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.nameFor(_media),
                            style: typography.bodyStyle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                ),
              if (_controller.settings.backend == AiBackend.api &&
                  _controller.settings.apiKey.isEmpty)
                DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: _controller.ready
                        ? _feedback(() => _settings(context))
                        : null,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('设置 API 连接'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(BuildContext context, AiChatMessage message) {
    final typography = AiChatTypography.of(context);
    final user = message.role == 'user';
    final colors = Theme.of(context).colorScheme;
    final inlineActions =
        !_narrowMessages &&
        typography.dense &&
        MediaQuery.textScalerOf(context).scale(12) <= 18;
    Widget action(
      String label,
      IconData icon,
      VoidCallback? onPressed, {
      bool feedback = true,
    }) => inlineActions || !user
        ? aiToolbarIcon(
            tooltip: label,
            icon: icon,
            onPressed: feedback ? _feedback(onPressed) : onPressed,
          )
        : _icon(label, icon, feedback ? _feedback(onPressed) : onPressed);
    final actions = [
      action(
        '复制内容',
        Icons.copy_outlined,
        () => _copy(message.content),
        feedback: false,
      ),
      if (user)
        action(
          '编辑提问',
          Icons.edit_outlined,
          _controller.managing ? null : () => _edit(context, message),
        )
      else
        action(
          message.status == 'streaming' ? '停止并重新生成' : '重新生成回答',
          Icons.refresh,
          _controller.managing
              ? null
              : () => _controller.regenerate(message.id),
        ),
      action(
        '从这里创建分支',
        Icons.call_split,
        _controller.managing ? null : () => _controller.forkAt(message.id),
      ),
      if (user)
        action(
          '撤回至输入框',
          Icons.undo,
          _controller.managing ? null : () => _controller.withdraw(message.id),
        ),
    ];
    const reasoningShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: typography.dense ? 10 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                user ? Icons.person_outline : Icons.chat_bubble_outline,
                size: 16,
                color: user ? colors.onSurfaceVariant : colors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                user ? '你' : 'AI',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (message.status == 'streaming')
                Text(
                  '生成中',
                  style: TextStyle(color: colors.primary, fontSize: 11),
                ),
              if (message.status == 'cancelled')
                Text(
                  '已停止',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              if (inlineActions) ...actions,
            ],
          ),
          SizedBox(height: typography.dense ? 4 : 8),
          if (message.reasoning.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Material(
                color: Colors.transparent,
                shape: reasoningShape,
                clipBehavior: Clip.antiAlias,
                child: ListTileTheme.merge(
                  shape: reasoningShape,
                  child: ExpansionTile(
                    minTileHeight: typography.dense ? 36 : null,
                    // ExpansionTile stores a bool in PageStorage. Its selectable
                    // Markdown descendants store scroll offsets there as doubles;
                    // use our own expansion state instead of a shared storage key.
                    key: ValueKey('ai-reasoning-${message.id}'),
                    // Override the default expanded top/bottom divider borders.
                    shape: reasoningShape,
                    collapsedShape: reasoningShape,
                    clipBehavior: Clip.antiAlias,
                    initiallyExpanded: _expandedReasoning.contains(message.id),
                    onExpansionChanged: (expanded) {
                      unawaited(AppHaptics.selectionClick(SettingsService()));
                      _updateUi(() {
                        _messagePresentationRevision++;
                        if (expanded) {
                          _expandedReasoning.add(message.id);
                        } else {
                          _expandedReasoning.remove(message.id);
                        }
                        _scrollingDown = false;
                        _followOutput = false;
                      });
                    },
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      message.status == 'streaming' && message.content.isEmpty
                          ? '正在思考…'
                          : '思考过程',
                      style: const TextStyle(fontSize: 12),
                    ),
                    children: [
                      _ReasoningBody(
                        child: AiMarkdown(
                          data: message.reasoning,
                          isStreaming: message.status == 'streaming',
                          onSeek: widget.onSeek == null ? null : _seekSubtitle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Container(
            padding: user
                ? EdgeInsets.all(typography.dense ? 8 : 12)
                : EdgeInsets.zero,
            decoration: user
                ? BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  )
                : null,
            child: user
                ? AiMarkdown.containsMath(message.content)
                      ? AiMarkdown(
                          data: message.content,
                          onSeek: widget.onSeek == null ? null : _seekSubtitle,
                        )
                      : SelectableText(
                          message.content,
                          style: typography.bodyStyle,
                        )
                : message.content.isEmpty && message.status == 'streaming'
                ? Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) => Text(
                          _controller.generationStatus ??
                              _controller.preparationStatus ??
                              '正在准备回答…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  )
                : AiMarkdown(
                    data: message.content,
                    isStreaming: message.status == 'streaming',
                    onSeek: widget.onSeek == null ? null : _seekSubtitle,
                  ),
          ),
          if (!user &&
              message.status == 'streaming' &&
              message.content.isNotEmpty &&
              _controller.reconnecting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _controller.generationStatus ?? '正在自动重连…',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          if (message.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                message.error!,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
          if (user && !inlineActions) Wrap(children: actions),
          if (!user) _answerFooter(message, actions),
        ],
      ),
    );
  }

  Widget _answerFooter(AiChatMessage message, List<Widget> actions) => Padding(
    key: ValueKey('ai-answer-footer-${message.id}'),
    padding: const EdgeInsets.only(top: 2),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final buttons = Wrap(
          key: ValueKey('ai-answer-actions-${message.id}'),
          children: actions,
        );
        final usage = AiResponseUsage(message: message);
        // Share one compact line when the usage label has enough room. Narrow
        // sidebars and large text retain readable usage on the following line.
        final usageWidth = MediaQuery.textScalerOf(context).scale(11) * 12;
        if (constraints.maxWidth >= 3 * kAiToolbarExtent + 8 + usageWidth) {
          return Row(
            children: [
              buttons,
              const SizedBox(width: 8),
              Expanded(child: usage),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [buttons, usage],
        );
      },
    ),
  );

  Widget _composer(
    BuildContext context, {
    bool compact = false,
    bool minimal = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final typography = AiChatTypography.of(context);
    final composer = SafeArea(
      top: false,
      child: Padding(
        padding: typography.dense
            ? const EdgeInsets.fromLTRB(6, 4, 6, 4)
            : const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Container(
          key: const ValueKey('ai-chat-composer'),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('ai-chat-input'),
                  controller: _input,
                  focusNode: _inputFocus,
                  autofocus: _desktopComposer,
                  enabled: _controller.ready,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 1,
                  maxLines: minimal
                      ? 1
                      : compact
                      ? 3
                      : 5,
                  textAlignVertical: TextAlignVertical.center,
                  strutStyle: StrutStyle(
                    fontSize: typography.fontSize,
                    height: 1.4,
                    forceStrutHeight: true,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  style: typography.bodyStyle.copyWith(
                    height: 1.4,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                  decoration: InputDecoration(
                    hintText: _media.hint,
                    isDense: true,
                    hintStyle: TextStyle(
                      fontSize: typography.fontSize,
                      height: 1.4,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (_controller.generating)
                DesktopButtonClickRegion(
                  child: IconButton(
                    key: const ValueKey('ai-chat-stop'),
                    tooltip: '停止生成',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    onPressed: _feedback(_controller.stop),
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                )
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, child) => Tooltip(
                    message: _sendShortcutHint,
                    textStyle: TextStyle(
                      fontSize: 12,
                      color: colors.onInverseSurface,
                    ),
                    decoration: BoxDecoration(
                      color: colors.inverseSurface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DesktopButtonClickRegion(
                      child: IconButton(
                        key: const ValueKey('ai-chat-send'),
                        color: colors.primary,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        onPressed:
                            _controller.ready &&
                                !_controller.managing &&
                                !_sending &&
                                value.text.trim().isNotEmpty
                            ? () => _send()
                            : null,
                        icon: const Icon(Icons.arrow_upward, size: 22),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return TextFieldTapRegion(child: composer);
  }

  Future<void> _edit(BuildContext context, AiChatMessage message) async {
    final input = TextEditingController(text: message.content);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AiAdaptiveDialog(
        title: const Text('编辑提问'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '在当前对话中修改并重新回答，此条之后的消息会被移除。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: input,
                minLines: 3,
                maxLines: 9,
                autofocus: true,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              onPressed: () {
                if (input.text.trim().isNotEmpty) {
                  Navigator.pop(context, input.text.trim());
                }
              },
              child: const Text('保存并发送'),
            ),
          ),
        ],
      ),
    );
    if (result != null &&
        mounted &&
        (_controller.active?.messages.any((item) => item.id == message.id) ??
            false)) {
      // Sending the replacement is a new reading intent. The returning dialog
      // route must also resume at that turn, rather than restore a bookmark to
      // a removed message (which falls back to the preceding answer).
      _controller.readingState.save(
        _readingOwner,
        _readingVisit,
        AiChatReadingPosition(
          bookmark: null,
          atEnd: true,
          followOutput: true,
          expandedReasoning: _expandedReasoning,
        ),
      );
      _bottom(force: true);
      await _controller.editMessage(message.id, result);
    }
    // Dialog disposal finishes after the route animation.
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
  }

  Future<void> _history(BuildContext context) async {
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final rows = _controller.conversations
              .where(
                (c) =>
                    query.isEmpty ||
                    c.displayTitle.toLowerCase().contains(
                      query.toLowerCase(),
                    ) ||
                    c.draftText.toLowerCase().contains(query.toLowerCase()) ||
                    c.messages.any(
                      (m) =>
                          m.content.toLowerCase().contains(query.toLowerCase()),
                    ),
              )
              .toList();
          return AiAdaptiveDialog(
            title: Row(
              children: [
                const Expanded(child: Text('对话历史')),
                DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: _controller.managing
                        ? null
                        : () async {
                            unawaited(AppHaptics.lightTap(SettingsService()));
                            await _startNewConversation();
                            if (context.mounted) Navigator.pop(context);
                          },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建'),
                  ),
                ),
              ],
            ),
            content: LayoutBuilder(
              builder: (context, limits) => Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: limits.maxHeight * .5,
                    ),
                    child: SingleChildScrollView(
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: '搜索标题或对话内容',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) =>
                            setDialogState(() => query = value),
                      ),
                    ),
                  ),
                  SizedBox(height: limits.maxHeight > 100 ? 8 : 0),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(child: Text('没有匹配的对话'))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              final date = row.updatedAt.toLocal();
                              return ListTile(
                                dense: true,
                                selected: row.id == _controller.active?.id,
                                leading: Icon(
                                  row.parentConversationId == null
                                      ? Icons.chat_bubble_outline
                                      : Icons.call_split,
                                  size: 20,
                                ),
                                title: Text(
                                  row.displayTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} · ${row.messages.length} 条消息${row.hasDraft ? ' · 草稿' : ''}${row.parentConversationId == null ? '' : ' · 分支'}${_controller.isGenerating(row.id) ? ' · 生成中' : ''}',
                                ),
                                onTap: _controller.managing
                                    ? null
                                    : () async {
                                        if (row.id != _controller.active?.id) {
                                          unawaited(
                                            AppHaptics.selectionClick(
                                              SettingsService(),
                                            ),
                                          );
                                        }
                                        await _controller.selectConversation(
                                          row.id,
                                        );
                                        _awayFromBottom = false;
                                        _bottom(force: true);
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                trailing: AiCapsuleIconMenu<String>(
                                  tooltip: '对话操作',
                                  icon: Icons.more_horiz,
                                  enabled: !_controller.managing,
                                  feedbackOnSelection: false,
                                  items: () => const [
                                    AiCapsuleChoice(
                                      value: 'rename',
                                      label: '重命名',
                                    ),
                                    AiCapsuleChoice(
                                      value: 'export',
                                      label: '复制为 Markdown',
                                    ),
                                    AiCapsuleChoice(
                                      value: 'delete',
                                      label: '删除',
                                      danger: true,
                                    ),
                                  ],
                                  onSelected: (action) async {
                                    if (action != 'export') {
                                      unawaited(
                                        AppHaptics.lightTap(SettingsService()),
                                      );
                                    }
                                    if (action == 'rename') {
                                      await _rename(context, row);
                                    }
                                    if (action == 'export') {
                                      await _copy(
                                        _controller.exportMarkdown(
                                          conversationId: row.id,
                                        ),
                                      );
                                    }
                                    if (action == 'delete') {
                                      if (!context.mounted) return;
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('删除对话？'),
                                          content: Text(
                                            '“${row.displayTitle}”将从本地历史中删除。',
                                          ),
                                          actions: [
                                            DesktopButtonClickRegion(
                                              child: TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: const Text('取消'),
                                              ),
                                            ),
                                            DesktopButtonClickRegion(
                                              child: TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: const Text('删除'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true) {
                                        await _controller.deleteConversation(
                                          row.id,
                                        );
                                      }
                                    }
                                    if (context.mounted) setDialogState(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) _focusComposer();
  }

  Future<void> _rename(BuildContext context, AiConversation row) async {
    final input = TextEditingController(text: row.displayTitle);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => DialogKeyboardViewport(
        child: AlertDialog(
          title: const Text('重命名对话'),
          content: TextField(
            controller: input,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(
                onPressed: () {
                  if (input.text.trim().isNotEmpty) {
                    Navigator.pop(context, input.text.trim());
                  }
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null) await _controller.renameConversation(row.id, result);
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
  }

  Future<void> _contextDialog(BuildContext context) async {
    await _refresh();
    if (!context.mounted) return;
    final hostContext = context;
    final snapshot = _controller.videoContext;
    if (snapshot == null) return;
    final selection = await showDialog<AiContextSelection>(
      context: context,
      builder: (context) => AiContextDialog(
        videoContext: snapshot,
        copy: _media,
        selectedTrackIds: _controller.selectedTrackIds,
        selectionIsAutomatic: _controller.selectionIsAutomatic,
        generationInProgress: _controller.generating,
        onReload: () async {
          Navigator.pop(context);
          await _refresh(retryOnlineSources: true);
          if (mounted && hostContext.mounted) await _contextDialog(hostContext);
        },
        onSeek: widget.onSeek == null ? null : _seekSubtitle,
      ),
    );
    if (selection != null) {
      _controller.setSelectedTracks(
        selection.ids,
        automatic: selection.automatic,
      );
    }
  }

  Future<void> _settings(BuildContext context) async {
    _inputFocus.unfocus();
    await showDialog<AiChatSettings>(
      context: context,
      requestFocus: false,
      builder: (context) => AiSettingsDialog(
        settings: _controller.settings,
        transport: _controller.settingsTransport,
        generationInProgress: _controller.generating,
        onSave: _saveSettings,
      ),
    );
    _inputFocus.unfocus();
  }

  Future<void> _developer(BuildContext context) async {
    await _refresh();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _AiDeveloperDialog(
        settings: _controller.settings,
        copy: _media,
        question: _input.text,
        preview: _controller.preview,
        lastRequest: _controller.lastRequest,
        onSave: _saveSettings,
      ),
    );
  }

  Future<void> _saveSettings(AiChatSettings settings) async {
    await _controller.saveSettings(settings);
    (widget.sessions ?? AiChatSessions.instance).adoptSettings(settings);
  }
}

class _ReasoningBody extends StatelessWidget {
  const _ReasoningBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget collapseArea() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: ExpansibleController.of(context).collapse,
    );

    // Only the outer padding is interactive. Keep the entire Markdown box,
    // including line endings and paragraph gaps, free of collapse gestures.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: SizedBox(width: double.infinity, child: child),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 12,
          child: collapseArea(),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 12,
          child: collapseArea(),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          height: 12,
          child: collapseArea(),
        ),
      ],
    );
  }
}

class _AiDeveloperDialog extends StatefulWidget {
  const _AiDeveloperDialog({
    required this.settings,
    required this.copy,
    required this.question,
    required this.preview,
    required this.onSave,
    this.lastRequest,
  });
  final AiChatSettings settings;
  final AiChatMediaCopy copy;
  final String question;
  final AiRequestPreview Function(String) preview;
  final AiRequestPreview? lastRequest;
  final Future<void> Function(AiChatSettings) onSave;
  @override
  State<_AiDeveloperDialog> createState() => _AiDeveloperDialogState();
}

class _AiDeveloperDialogState extends State<_AiDeveloperDialog> {
  late final TextEditingController _prompt,
      _question,
      _titlePrompt,
      _cliPrompt,
      _transcriptPrompt;
  AiRequestPreview? _preview;
  String? _previewError;
  bool _saving = false;
  bool _enabled = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.settings.systemPrompt);
    _cliPrompt = TextEditingController(text: widget.settings.cliPrompt);
    _titlePrompt = TextEditingController(text: widget.settings.titlePrompt);
    _transcriptPrompt = TextEditingController(
      text: widget.settings.transcriptPrompt,
    );
    _question = TextEditingController(
      text: widget.question.isEmpty
          ? widget.copy.previewQuestion
          : widget.question,
    );
    _refreshPreview();
  }

  void _refreshPreview() {
    try {
      _preview = widget.preview(_question.text);
      _previewError = null;
    } catch (error) {
      _preview = null;
      _previewError = error.toString().replaceFirst('Bad state: ', '');
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    _question.dispose();
    _titlePrompt.dispose();
    _cliPrompt.dispose();
    _transcriptPrompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        widget.settings.copyWith(
          systemPrompt: _prompt.text,
          titlePrompt: _titlePrompt.text,
          cliPrompt: _cliPrompt.text,
          transcriptPrompt: _transcriptPrompt.text,
          developerMode: _enabled,
        ),
      );
      if (mounted) setState(_refreshPreview);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _request(AiRequestPreview request) => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '预计 ${request.estimatedTokens} Token · 裁剪 ${request.omittedMessages} 条历史 · ${request.selectedChunks.length} 个字幕片段',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        for (final warning in request.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              warning,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
          ),
        const SizedBox(height: 10),
        for (final chunk in request.selectedChunks)
          Text(
            '${chunk.label} · ${_time(chunk.start)} – ${_time(chunk.end)}',
            style: const TextStyle(fontSize: 11),
          ),
        const SizedBox(height: 12),
        if (request.requestParameters != null) ...[
          Text(
            '请求参数 · ${request.apiProtocol ?? ''}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SelectableText(
            const JsonEncoder.withIndent(
              '  ',
            ).convert(request.requestParameters),
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            const Expanded(
              child: Text('应用消息（不包含 API 密钥）', style: TextStyle(fontSize: 12)),
            ),
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '复制请求',
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent(
                      '  ',
                    ).convert(request.messages),
                  ),
                ),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ),
          ],
        ),
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(request.messages),
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
        if (request.apiProtocol == 'anthropic' ||
            request.apiProtocol == 'gemini')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '原生接口将系统提示提取到对应字段，连续的同角色消息会合并。这里保留应用构建的完整消息顺序。',
              style: TextStyle(fontSize: 11, height: 1.5),
            ),
          ),
        if (request.cliInput != null) ...[
          const SizedBox(height: 16),
          const Text(
            '应用发送给 CLI 的完整输入',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '各桌面 Agent 自身的系统提示与登录由工具管理。应用将 CLI 附加提示词和本次对话一起发送。',
              style: TextStyle(fontSize: 11, height: 1.5),
            ),
          ),
          SelectableText(
            request.cliInput!,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: request.cliInput!)),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制 CLI 输入'),
            ),
          ),
        ],
      ],
    ),
  );

  String _time(Duration time) =>
      '${time.inHours.toString().padLeft(2, '0')}:${(time.inMinutes % 60).toString().padLeft(2, '0')}:${(time.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _tabs(BuildContext context, bool short) {
    if (!short) {
      return const TabBar(
        tabs: [
          Tab(text: '提示词'),
          Tab(text: '下一次请求'),
          Tab(text: '上一次请求'),
        ],
      );
    }
    final controller = DefaultTabController.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AiCapsuleSelectField<int>(
        value: controller.index,
        choices: const [
          AiCapsuleChoice(value: 0, label: '提示词'),
          AiCapsuleChoice(value: 1, label: '下一次请求'),
          AiCapsuleChoice(value: 2, label: '上一次请求'),
        ],
        onChanged: controller.animateTo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: AiAdaptiveDialog(
      title: const Text('开发者模式'),
      content: LayoutBuilder(
        builder: (context, limits) => Column(
          children: [
            _tabs(context, limits.maxHeight < 180),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _enabled,
                          title: const Text('启用开发者模式'),
                          onChanged: (value) =>
                              setState(() => _enabled = value),
                        ),
                        Text(
                          '请求顺序：系统提示词 → ${widget.copy.sources} → 早期历史节选 → 最近完整轮次 → 当前问题。元信息、字幕名称、时间戳和覆盖范围由系统自动构建；字幕中的指令作为资料处理。',
                          style: const TextStyle(fontSize: 12, height: 1.6),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _prompt,
                          minLines: 7,
                          maxLines: 16,
                          decoration: const InputDecoration(
                            labelText: '系统提示词（可编辑）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: () => _prompt.text =
                                  AiChatSettings.defaultSystemPrompt,
                              child: const Text('恢复默认提示词'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _titlePrompt,
                          minLines: 2,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: '对话标题提示词（留空关闭自动概括）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '首轮回答后，API 会发送一次简短请求概括标题。CLI 使用问题生成本地标题。',
                            style: TextStyle(fontSize: 11, height: 1.5),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: () => _titlePrompt.text =
                                  AiChatSettings.defaultTitlePrompt,
                              child: const Text('恢复默认标题提示词'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _transcriptPrompt,
                          minLines: 3,
                          maxLines: 8,
                          decoration: const InputDecoration(
                            labelText: '全文分段与核查提示词',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const Text(
                          '长字幕逐段使用此提示词处理，随后合并记录并发送最终提问；修改后会重新生成受影响的摘要。',
                          style: TextStyle(fontSize: 11),
                        ),
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: () => _transcriptPrompt.text =
                                AiChatSettings.defaultTranscriptPrompt,
                            child: const Text('恢复默认分段提示词'),
                          ),
                        ),
                        if (widget.settings.backend != AiBackend.api) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _cliPrompt,
                            minLines: 3,
                            maxLines: 8,
                            decoration: const InputDecoration(
                              labelText: 'CLI 附加提示词（可编辑）',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: () => _cliPrompt.text =
                                  AiChatSettings.defaultCliPrompt,
                              child: const Text('恢复默认 CLI 提示词'),
                            ),
                          ),
                        ],
                        const Text(
                          '保存后再刷新请求预览，即可看到修改后的实际发送内容。',
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, previewLimits) => Column(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: previewLimits.maxHeight * .5,
                          ),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _question,
                                      decoration: const InputDecoration(
                                        labelText: '用于预览的问题',
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  DesktopButtonClickRegion(
                                    child: IconButton(
                                      tooltip: '刷新请求预览',
                                      onPressed: () =>
                                          setState(_refreshPreview),
                                      icon: const Icon(Icons.refresh),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _preview == null
                              ? SingleChildScrollView(
                                  padding: const EdgeInsets.all(12),
                                  child: SelectableText(
                                    _previewError ?? '无法构建请求',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                )
                              : _request(_preview!),
                        ),
                      ],
                    ),
                  ),
                  widget.lastRequest == null
                      ? const Center(child: Text('还没有发送请求'))
                      : _request(widget.lastRequest!),
                ],
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ),
        DesktopButtonClickRegion(
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存提示词'),
          ),
        ),
      ],
    ),
  );
}
