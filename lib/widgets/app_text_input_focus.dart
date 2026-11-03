import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'desktop_text_drop.dart';

/// Gives editable app fields a consistent outside-touch dismissal on phones.
///
/// This changes Flutter's default action instead of intercepting page gestures:
/// field decorations, selection menus and TextFieldTapRegion accessories keep
/// their normal behavior, as do fields with an explicit onTapOutside callback.
/// Read-only text keeps its selection and the platform's original focus rules.
class AppTextInputFocus extends StatelessWidget {
  const AppTextInputFocus({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DesktopTextDropHost(
    child: Actions(
      actions: <Type, Action<Intent>>{
        EditableTextTapOutsideIntent: _OutsideTouchAction(),
      },
      child: child,
    ),
  );
}

class _OutsideTouchAction extends Action<EditableTextTapOutsideIntent> {
  @override
  Object? invoke(EditableTextTapOutsideIntent intent) {
    final mobile = switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => true,
      _ => false,
    };
    if (kIsWeb ||
        !mobile ||
        intent.pointerDownEvent.kind != PointerDeviceKind.touch) {
      return callingAction?.invoke(intent);
    }

    final node = intent.focusNode;
    final context = node.context;
    if (!node.hasFocus || context == null || !context.mounted) return null;
    final widget = context.widget;
    final editable = widget is EditableText
        ? widget
        : context.findAncestorWidgetOfExactType<EditableText>();
    if (editable == null || editable.readOnly) {
      return callingAction?.invoke(intent);
    }
    // Dismiss only the field that received this intent. Unfocusing its entire
    // scope could steal focus from a different field or a newly opened route.
    node.unfocus();
    return null;
  }
}
