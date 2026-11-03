import 'dart:async';

import 'package:flutter/widgets.dart';

import 'ai_chat_controller.dart';

/// One synchronizer for a shared composer, even while sidebar and fullscreen
/// views coexist. Programmatic restores never save text into the wrong task.
class AiChatDraftBinding with WidgetsBindingObserver {
  AiChatDraftBinding._(this.controller, this.input) {
    controller.addListener(_restore);
    controller.draftRevision.addListener(_restore);
    input.addListener(_edited);
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  static final _bindings = Expando<AiChatDraftBinding>();

  static AiChatDraftBinding retain(
    AiChatController controller,
    TextEditingController input,
  ) {
    final existing = _bindings[input];
    assert(existing == null || identical(existing.controller, controller));
    final binding = existing ?? AiChatDraftBinding._(controller, input);
    _bindings[input] = binding;
    binding._owners++;
    return binding;
  }

  final AiChatController controller;
  final TextEditingController input;
  int _owners = 0;
  bool _restoring = false;
  String? _conversationId;

  void _restore() {
    final current = controller.active;
    if (current == null) return;
    final switched = _conversationId != current.id;
    _conversationId = current.id;
    if (!switched && input.text == current.draftText) return;
    _restoring = true;
    try {
      input.value = TextEditingValue(
        text: current.draftText,
        selection: TextSelection.collapsed(offset: current.draftText.length),
      );
    } finally {
      _restoring = false;
    }
  }

  void _edited() {
    if (_restoring || _conversationId == null) return;
    controller.updateDraft(input.text, conversationId: _conversationId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(controller.flushDrafts());
    }
  }

  void release() {
    unawaited(controller.flushDrafts());
    if (--_owners > 0) return;
    controller.removeListener(_restore);
    controller.draftRevision.removeListener(_restore);
    input.removeListener(_edited);
    WidgetsBinding.instance.removeObserver(this);
    _bindings[input] = null;
  }
}
