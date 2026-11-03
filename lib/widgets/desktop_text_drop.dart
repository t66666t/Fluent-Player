import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../utils/desktop_text_drop_edit.dart';
import 'clipboard_detection_scope.dart';

export '../utils/desktop_text_drop_edit.dart' show DesktopTextDropInsertion;

bool get supportsDesktopTextDrop =>
    !kIsWeb &&
    const {
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

/// Opts a field's full decorated area into a particular insertion policy.
/// Other editable fields retain ordinary insertion through the app host.
class DesktopTextDropTarget extends SingleChildRenderObjectWidget {
  const DesktopTextDropTarget({
    super.key,
    required super.child,
    this.insertion = DesktopTextDropInsertion.insert,
    this.preferUrl = false,
    this.enabled = true,
  });

  final DesktopTextDropInsertion insertion;
  final bool preferUrl, enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _TextDropBoundary(insertion, preferUrl, enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _TextDropBoundary)
      ..insertion = insertion
      ..preferUrl = preferUrl
      ..enabled = enabled;
  }
}

class _TextDropBoundary extends RenderProxyBox {
  _TextDropBoundary(this.insertion, this.preferUrl, this.enabled);
  DesktopTextDropInsertion insertion;
  bool preferUrl, enabled;

  @override
  bool hitTestSelf(Offset position) => enabled;
}

class _DropField {
  const _DropField(this.editor, this.box, this.insertion, this.preferUrl);
  final EditableTextState editor;
  final RenderBox box;
  final DesktopTextDropInsertion insertion;
  final bool preferUrl;
}

/// Shares desktop_drop's native receiver with existing file imports. Text events
/// are hit-tested against the live scene, so covered/hidden fields cannot edit.
class DesktopTextDropHost extends StatefulWidget {
  const DesktopTextDropHost({super.key, required this.child});
  final Widget child;

  @override
  State<DesktopTextDropHost> createState() => _DesktopTextDropHostState();
}

class _DesktopTextDropHostState extends State<DesktopTextDropHost> {
  bool _listening = false;
  bool _dragging = false;
  ClipboardDetectionScope? _linkScope;
  Rect? _highlight;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _linkScope = ClipboardDetectionScope.maybeOf(context);
    if (supportsDesktopTextDrop == _listening) return;
    _listening = supportsDesktopTextDrop;
    if (_listening) {
      DesktopDrop.instance.addRawTextDropEventListener(_onDrop);
      DesktopDrop.instance.addRawDropEventListener(_onNativeMotion);
    } else {
      DesktopDrop.instance.removeRawTextDropEventListener(_onDrop);
      DesktopDrop.instance.removeRawDropEventListener(_onNativeMotion);
    }
  }

  @override
  void dispose() {
    if (_dragging) _linkScope?.textDragChanged?.call(false);
    if (_listening) {
      DesktopDrop.instance.removeRawTextDropEventListener(_onDrop);
      DesktopDrop.instance.removeRawDropEventListener(_onNativeMotion);
    }
    super.dispose();
  }

  EditableTextState? _editor(RenderObject object) {
    if (object is RenderEditable &&
        object.textSelectionDelegate is EditableTextState) {
      return object.textSelectionDelegate as EditableTextState;
    }
    EditableTextState? found;
    object.visitChildren((child) => found ??= _editor(child));
    return found;
  }

  bool _canEdit(EditableTextState editor) {
    final field = editor.widget;
    if (!editor.mounted || field.readOnly || field.obscureText) return false;
    return !{
      TextInputType.number.index,
      TextInputType.datetime.index,
      TextInputType.phone.index,
      TextInputType.visiblePassword.index,
    }.contains(field.keyboardType.index);
  }

  _DropField? _fieldAt(HitTestResult result) {
    EditableTextState? editor;
    _TextDropBoundary? boundary;
    for (final entry in result.path) {
      final object = entry.target;
      if (object is _TextDropBoundary) {
        boundary = object;
        editor ??= _editor(object);
        break;
      }
      if (object is RenderEditable) editor ??= _editor(object);
    }
    if (editor == null || !_canEdit(editor) || boundary?.enabled == false) {
      return null;
    }
    final url = editor.widget.keyboardType == TextInputType.url;
    return _DropField(
      editor,
      boundary ?? editor.renderEditable,
      boundary?.insertion ??
          (url
              ? DesktopTextDropInsertion.replaceAll
              : DesktopTextDropInsertion.insert),
      boundary?.preferUrl ?? url,
    );
  }

  bool _isInputArea(HitTestResult result, Offset point) {
    final objects = result.path.map((entry) => entry.target).toSet();
    if (objects.any(
      (object) => object is _TextDropBoundary || object is RenderEditable,
    )) {
      return true;
    }
    // Inspect only on release outside an editable hit. The outer render box
    // covers field decoration, icons and disabled fields as well as the text.
    // Requiring a live hit keeps obscured/offstage fields out of this decision.
    var found = false;
    void visit(Element element) {
      if (found) return;
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is TextField ||
          widget is CupertinoTextField ||
          widget is EditableText) {
        final object = element.findRenderObject();
        found = objects.contains(object);
        if (!found &&
            object is RenderBox &&
            object.attached &&
            object.hasSize &&
            (Offset.zero & object.size).contains(object.globalToLocal(point))) {
          // A disabled Cupertino field uses IgnorePointer without an opaque
          // mouse region. In that case the live hit stops at its ancestor.
          final first = result.path
              .map((entry) => entry.target)
              .whereType<RenderObject>()
              .firstOrNull;
          for (
            RenderObject? ancestor = object;
            ancestor != null;
            ancestor = ancestor.parent
          ) {
            if (identical(first, ancestor)) {
              found = true;
              break;
            }
          }
        }
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  void _setDragging(bool active, {bool suppressClipboard = false}) {
    if (_dragging == active && !suppressClipboard) return;
    _dragging = active;
    _linkScope?.textDragChanged?.call(
      active,
      suppressClipboard: suppressClipboard,
    );
  }

  void _onNativeMotion(DropEvent event) {
    if (!mounted || !_listening) return;
    // GTK negotiates URI data after release, so URL drags initially share
    // the file motion channel. Observe its timing without consuming imports.
    if (event is DropEnterEvent || event is DropUpdateEvent) {
      _setDragging(true);
    } else if (event is DropExitEvent || event is DropDoneEvent) {
      _setDragging(false, suppressClipboard: event is DropDoneEvent);
    }
  }

  bool _onDrop(TextDropEvent event) {
    if (!mounted || !_listening) return false;
    if (event.phase == TextDropPhase.exited) {
      _setHighlight(null);
      _setDragging(false);
      return false;
    }
    _setDragging(true);
    // Windows OLE uses physical pixels; AppKit/GTK already use logical units.
    final point = defaultTargetPlatform == TargetPlatform.windows
        ? event.location / View.of(context).devicePixelRatio
        : event.location;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      point,
      View.of(context).viewId,
    );
    final field = _fieldAt(result);
    if (event.phase != TextDropPhase.dropped) {
      final host = context.findRenderObject() as RenderBox?;
      _setHighlight(
        field == null || host == null
            ? null
            : host.globalToLocal(field.box.localToGlobal(Offset.zero)) &
                  field.box.size,
      );
      return field != null;
    }
    _setHighlight(null);
    _setDragging(false, suppressClipboard: true);
    if (field == null) {
      if (_linkScope?.acceptDroppedLinks == null) return false;
      if (_isInputArea(result, point)) return false;
      return _linkScope?.acceptDroppedLinks?.call(event.text, event.urls) ??
          false;
    }
    final urls = event.urls.where((url) => url.trim().isNotEmpty).join('\n');
    final plain = event.text ?? '';
    final text = field.preferUrl && urls.isNotEmpty
        ? urls
        : plain.trim().isNotEmpty
        ? plain
        : urls;
    if (text.trim().isEmpty || text.length > 1024 * 1024) return false;
    final editor = field.editor;
    final next = insertDesktopDroppedText(
      editor.textEditingValue,
      text,
      insertion: field.insertion,
      singleLine: editor.widget.maxLines == 1,
    );
    if (next == editor.textEditingValue) return false;
    // The public user-edit path applies formatters, onChanged and undo history.
    // requestKeyboard marks this as internal focus, preserving the last range
    // instead of selecting the whole value again on every browser-to-field drop.
    editor.requestKeyboard();
    editor.userUpdateTextEditingValue(next, SelectionChangedCause.drag);
    return true;
  }

  void _setHighlight(Rect? rect) {
    if (_highlight != rect) setState(() => _highlight = rect);
  }

  @override
  Widget build(BuildContext context) {
    if (!_listening) return widget.child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_highlight case final rect?)
          Positioned.fromRect(
            rect: rect.inflate(2),
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('desktop-text-drop-highlight'),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
