import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/keyboard_focus_visibility.dart';
import 'package:flutter/services.dart';

import 'capsule_option.dart';
import 'anchored_menu_layout.dart';
import '../theme/app_tokens.dart';
import '../utils/keyboard_shortcut_hints.dart';

/// Shared with the online player's quality menu.
const capsuleMenuFill = Color(0xFF222222);
const _menuBorder = Color(0x29FFFFFF);

class _Choice<T> {
  const _Choice(this.value);
  final T? value;
}

class CapsuleMenuOption<T> {
  const CapsuleMenuOption({
    this.key,
    required this.value,
    required this.child,
    this.enabled = true,
    this.selected = false,
    this.checked,
    this.onTap,
  });
  final T? value;
  final Key? key;
  final Widget child;
  final bool enabled, selected;

  /// Null for ordinary choices; checked items always show a checkbox.
  final bool? checked;
  final VoidCallback? onTap;
}

/// Constrain labels at the shared boundary, including older icon/text rows.
/// Rich model rows retain their own layout and independent download controls.
Widget _label(Widget child, {bool selected = false}) {
  if (child is Text) {
    final lines = selected ? 1 : (child.maxLines ?? 3).clamp(1, 3);
    if (child.data != null) {
      return Text(
        child.data!,
        style: child.style,
        textAlign: child.textAlign,
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        softWrap: !selected,
        semanticsLabel: child.semanticsLabel,
      );
    }
    return Text.rich(
      child.textSpan!,
      style: child.style,
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
    );
  }
  if (child is Row) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: child.crossAxisAlignment,
      children: [
        for (final item in child.children)
          if (item is Text)
            Flexible(child: _label(item, selected: selected))
          else
            item,
      ],
    );
  }
  return child;
}

Future<_Choice<T>?> _showChoices<T>({
  required BuildContext context,
  required AnchoredMenuPosition anchor,
  required List<CapsuleMenuOption<T>> options,
  List<CapsuleMenuOption<T>> Function(BuildContext)? optionsBuilder,
  String title = '选择选项',
  double? width,
  bool preferAbove = false,
  bool plain = false,
}) {
  if (options.isEmpty) return Future.value();
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  return showGeneralDialog<_Choice<T>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭$title',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    requestFocus: true,
    pageBuilder: (_, _, _) => themes.wrap(
      Builder(
        builder: (menuContext) {
          if (optionsBuilder != null) KeyboardShortcutHints.of(menuContext);
          final liveOptions = optionsBuilder?.call(menuContext) ?? options;
          if (liveOptions.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (menuContext.mounted &&
                  ModalRoute.of(menuContext)!.isCurrent) {
                Navigator.of(menuContext).pop();
              }
            });
            return const SizedBox.shrink();
          }
          return _CapsuleMenu<T>(
            anchor: anchor,
            options: liveOptions,
            title: title,
            width: width,
            preferAbove: preferAbove,
            plain: plain,
          );
        },
      ),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

class _CapsuleMenu<T> extends StatefulWidget {
  const _CapsuleMenu({
    required this.anchor,
    required this.options,
    required this.title,
    this.width,
    this.preferAbove = false,
    this.plain = false,
  });
  final AnchoredMenuPosition anchor;
  final List<CapsuleMenuOption<T>> options;
  final String title;
  final double? width;
  final bool preferAbove;
  final bool plain;
  @override
  State<_CapsuleMenu<T>> createState() => _CapsuleMenuState<T>();
}

class _CapsuleMenuState<T> extends State<_CapsuleMenu<T>> {
  final scroll = ScrollController();
  late final nodes = List.generate(widget.options.length, (_) => FocusNode());
  late int active = math.max(
    0,
    widget.options.indexWhere((e) => e.selected && e.enabled),
  );

  @override
  void didUpdateWidget(_CapsuleMenu<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadMenuFocus = nodes.any((node) => node.hasFocus);
    final previousValue = oldWidget.options[active].value;
    final matchingIndex = widget.options.indexWhere(
      (option) => option.value == previousValue,
    );
    active = matchingIndex >= 0
        ? matchingIndex
        : active.clamp(0, widget.options.length - 1);
    while (nodes.length < widget.options.length) {
      nodes.add(FocusNode());
    }
    while (nodes.length > widget.options.length) {
      nodes.removeLast().dispose();
    }
    if (hadMenuFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.options[active].enabled) {
          nodes[active].requestFocus();
        } else {
          _move(1);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.options[active].enabled) {
        _move(1);
      } else {
        nodes[active].requestFocus();
      }
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    for (final node in nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _move(int delta) {
    for (var step = 1; step <= nodes.length; step++) {
      final next = (active + step * delta) % nodes.length;
      if (widget.options[next].enabled) {
        setState(() => active = next);
        nodes[next].requestFocus();
        return;
      }
    }
  }

  void _choose(int index) {
    final option = widget.options[index];
    if (!option.enabled) return;
    // Close first so navigation or dialogs launched by actions stay on top.
    Navigator.of(context).pop(_Choice(option.value));
    option.onTap?.call();
  }

  double _contentWidth(BuildContext context, TextStyle style) {
    // Page fields expand to fill a row; their popups should fit the choices
    // instead. Include the row insets, checkmark and scroll-view padding.
    var width = 160.0;
    for (final option in widget.options) {
      final label = option.child;
      if (label is! Text) {
        width = math.max(width, 240);
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(
          style: style.merge(label.style),
          children: [label.textSpan ?? TextSpan(text: label.data)],
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      width = math.max(width, painter.width.ceilToDouble() + 64);
      painter.dispose();
    }
    return width.clamp(160, 360);
  }

  @override
  Widget build(BuildContext context) {
    final menuTextStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: Colors.white.withValues(alpha: 0.88),
      fontSize: 13,
    );
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              _choose(active),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _choose(active),
        },
        child: AnchoredMenuLayout(
          position: widget.anchor,
          width:
              (widget.width ??
                      (widget.plain
                          ? _contentWidth(context, menuTextStyle)
                          : math.max(widget.anchor.globalBounds.width, 208)))
                  .clamp(0, 480),
          preferAbove: widget.preferAbove,
          alignLeft: widget.plain,
          child: Semantics(
            namesRoute: true,
            label: widget.title,
            child: Material(
              key: const ValueKey('capsule-choice-menu'),
              color: widget.plain ? AppTokens.bgOverlay : capsuleMenuFill,
              surfaceTintColor: Colors.transparent,
              elevation: 2,
              shadowColor: Colors.black54,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(widget.plain ? 6 : 12),
                side: BorderSide(
                  color: widget.plain ? AppTokens.lineSubtle : _menuBorder,
                  width: 0.75,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: DefaultTextStyle(
                style: menuTextStyle,
                child: IconTheme(
                  data: const IconThemeData(color: Colors.white70, size: 18),
                  child: SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < widget.options.length;
                          index++
                        )
                          Padding(
                            key: widget.options[index].key,
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Semantics(
                              selected: widget.options[index].checked == null
                                  ? widget.options[index].selected
                                  : null,
                              checked: widget.options[index].checked,
                              enabled: widget.options[index].enabled,
                              child: Focus(
                                focusNode: nodes[index],
                                skipTraversal: !widget.options[index].enabled,
                                onFocusChange: (focused) {
                                  if (focused && mounted) {
                                    setState(() => active = index);
                                    final itemContext = nodes[index].context;
                                    if (itemContext != null) {
                                      Scrollable.ensureVisible(
                                        itemContext,
                                        alignment: 0.5,
                                      );
                                    }
                                  }
                                },
                                child: Builder(
                                  builder: (context) => KeyboardFocusHighlight(
                                    focused: Focus.of(context).hasFocus,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.04,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        widget.plain ? 3 : 8,
                                      ),
                                    ),
                                    child: CapsuleOption(
                                      borderRadius: BorderRadius.circular(
                                        widget.plain ? 3 : 8,
                                      ),
                                      color:
                                          !widget.plain &&
                                              widget.options[index].selected
                                          ? Colors.white.withValues(alpha: 0.07)
                                          : Colors.transparent,
                                      onTap: widget.options[index].enabled
                                          ? () => _choose(index)
                                          : null,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 8,
                                      ),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight: 24,
                                        ),
                                        child: Opacity(
                                          opacity: widget.options[index].enabled
                                              ? 1
                                              : 0.4,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child:
                                                widget.options[index].checked !=
                                                    null
                                                ? Row(
                                                    children: [
                                                      Icon(
                                                        widget
                                                                .options[index]
                                                                .checked!
                                                            ? Icons.check_box
                                                            : Icons
                                                                  .check_box_outline_blank,
                                                        size: 20,
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: _label(
                                                          widget
                                                              .options[index]
                                                              .child,
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : widget.plain
                                                ? Row(
                                                    children: [
                                                      Expanded(
                                                        child: DefaultTextStyle(
                                                          style: menuTextStyle,
                                                          child: _label(
                                                            widget
                                                                .options[index]
                                                                .child,
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      SizedBox(
                                                        width: 16,
                                                        child:
                                                            widget
                                                                .options[index]
                                                                .selected
                                                            ? const Icon(
                                                                Icons
                                                                    .check_rounded,
                                                                size: 16,
                                                                color: AppTokens
                                                                    .text1,
                                                              )
                                                            : null,
                                                      ),
                                                    ],
                                                  )
                                                : _label(
                                                    widget.options[index].child,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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
          ),
        ),
      ),
    );
  }
}

/// A compact capsule trigger; menu options may contain multiple lines/actions.
/// DropdownMenuItem remains the data format so existing typed values, disabled
/// choices and nullable options keep their behavior during the UI migration.
class CapsuleDropdownButton<T> extends DropdownButton<T> {
  CapsuleDropdownButton({
    super.key,
    required super.items,
    required super.onChanged,
    super.value,
    super.hint,
    super.disabledHint,
    super.selectedItemBuilder,
    super.isExpanded,
    super.isDense,
    super.style,
    super.icon,
    super.iconSize,
    super.iconEnabledColor,
    super.iconDisabledColor,
    super.underline,
    super.dropdownColor,
    super.itemHeight,
    super.focusNode,
    super.autofocus,
    super.onTap,
    super.alignment,
    this.embedded = false,
    this.plain = false,
    super.menuWidth,
  });
  final bool embedded;

  /// Text and chevron on the page surface, with a matching rectangular menu.
  final bool plain;

  @override
  State<DropdownButton<T>> createState() => _CapsuleDropdownState<T>();
}

class _CapsuleDropdownState<T> extends State<DropdownButton<T>> {
  bool opening = false;
  Future<void> open() async {
    if (opening ||
        widget.onChanged == null ||
        widget.items?.isNotEmpty != true) {
      return;
    }
    setState(() => opening = true);
    widget.onTap?.call();
    try {
      final choice = await _showChoices<T>(
        context: context,
        anchor: AnchoredMenuPosition.fromContext(context),
        width: widget.menuWidth,
        plain: (widget as CapsuleDropdownButton<T>).plain,
        options: [
          for (final item in widget.items!)
            CapsuleMenuOption<T>(
              key: item.key,
              value: item.value,
              child: item.child,
              enabled: item.enabled,
              selected: item.value == widget.value,
              onTap: item.onTap,
            ),
        ],
      );
      if (mounted && choice != null) widget.onChanged?.call(choice.value);
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final embedded = (widget as CapsuleDropdownButton<T>).embedded;
    final plain = (widget as CapsuleDropdownButton<T>).plain;
    final items = widget.items ?? [];
    final index = items.indexWhere((item) => item.value == widget.value);
    final enabled = widget.onChanged != null && items.isNotEmpty;
    final child = index >= 0
        ? (widget.selectedItemBuilder?.call(context)[index] ??
              items[index].child)
        : (!enabled ? widget.disabledHint ?? widget.hint : widget.hint) ??
              const Text('请选择');
    return LayoutBuilder(
      builder: (context, constraints) {
        final expand = widget.isExpanded && constraints.hasBoundedWidth;
        final basePadding = widget.isDense ? 4.0 : 8.0;
        final verticalPadding = constraints.hasBoundedHeight
            ? math.min(
                basePadding,
                math.max(0.0, (constraints.maxHeight - 24) / 2),
              )
            : basePadding;
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (expand)
              Expanded(child: _label(child, selected: true))
            else
              Flexible(child: _label(child, selected: true)),
            const SizedBox(width: 6),
            Icon(
              opening
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: math.min(widget.iconSize, 20),
            ),
          ],
        );
        return Semantics(
          button: true,
          enabled: enabled,
          child: Focus(
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            child: Opacity(
              opacity: enabled ? 1 : 0.45,
              child: DefaultTextStyle.merge(
                style:
                    widget.style ??
                    const TextStyle(fontSize: 13, color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: IconTheme(
                  data: IconThemeData(
                    color: widget.iconEnabledColor ?? Colors.white70,
                  ),
                  child: CapsuleOption(
                    borderRadius: plain ? BorderRadius.circular(4) : null,
                    color: embedded || plain
                        ? Colors.transparent
                        : capsuleMenuFill,
                    side: embedded || plain
                        ? BorderSide.none
                        : BorderSide(
                            color: opening ? Colors.white38 : _menuBorder,
                            width: 0.75,
                          ),
                    padding: embedded
                        ? EdgeInsets.zero
                        : EdgeInsets.symmetric(
                            horizontal: plain ? 0 : (widget.isDense ? 10 : 12),
                            vertical: verticalPadding,
                          ),
                    onTap: enabled ? open : null,
                    child: widget.isExpanded && constraints.hasBoundedWidth
                        ? SizedBox(width: constraints.maxWidth, child: row)
                        : row,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class CapsuleDropdownButtonFormField<T> extends FormField<T> {
  CapsuleDropdownButtonFormField({
    super.key,
    T? initialValue,
    T? value,
    required List<DropdownMenuItem<T>>? items,
    required this.onChanged,
    InputDecoration decoration = const InputDecoration(),
    bool useInputTheme = false,
    DropdownButtonBuilder? selectedItemBuilder,
    bool isExpanded = true,
    bool isDense = true,
    double? itemHeight,
    Color? dropdownColor,
    TextStyle? style,
    Color? iconEnabledColor,
    Widget? hint,
    double? menuWidth,
    super.validator,
    super.onSaved,
    super.autovalidateMode,
  }) : super(
         initialValue: initialValue ?? value,
         enabled: onChanged != null,
         builder: (field) {
           final border = OutlineInputBorder(
             borderRadius: BorderRadius.circular(24),
             borderSide: const BorderSide(color: _menuBorder, width: 0.75),
           );
           final input = useInputTheme
               ? decoration
                     .applyDefaults(
                       Theme.of(field.context).inputDecorationTheme,
                     )
                     .copyWith(
                       errorText: field.errorText ?? decoration.errorText,
                     )
               : decoration.copyWith(
                   filled: true,
                   fillColor: capsuleMenuFill,
                   labelStyle: const TextStyle(color: Colors.white70),
                   prefixIconColor:
                       decoration.prefixIconColor ?? Colors.white60,
                   suffixIconColor:
                       decoration.suffixIconColor ?? Colors.white60,
                   isDense: true,
                   contentPadding: const EdgeInsets.symmetric(
                     horizontal: 14,
                     vertical: 10,
                   ),
                   border: border,
                   enabledBorder: border,
                   disabledBorder: border,
                   focusedBorder: border.copyWith(
                     borderSide: const BorderSide(color: Colors.white54),
                   ),
                   errorText: field.errorText ?? decoration.errorText,
                 );
           return InputDecorator(
             decoration: input,
             isEmpty: field.value == null && hint == null,
             child: CapsuleDropdownButton<T>(
               value: field.value,
               items: items,
               isExpanded: isExpanded,
               isDense: isDense,
               itemHeight: itemHeight,
               selectedItemBuilder: selectedItemBuilder,
               style: style,
               iconEnabledColor: iconEnabledColor,
               hint: hint,
               embedded: true,
               menuWidth: menuWidth,
               onChanged: onChanged == null ? null : field.didChange,
             ),
           );
         },
       );
  final ValueChanged<T?>? onChanged;
  @override
  FormFieldState<T> createState() => _CapsuleFormFieldState<T>();
}

class _CapsuleFormFieldState<T> extends FormFieldState<T> {
  @override
  void didChange(T? value) {
    super.didChange(value);
    (widget as CapsuleDropdownButtonFormField<T>).onChanged?.call(value);
  }

  @override
  void reset() {
    super.reset();
    (widget as CapsuleDropdownButtonFormField<T>).onChanged?.call(value);
  }

  @override
  void didUpdateWidget(covariant FormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != oldWidget.initialValue) {
      setValue(widget.initialValue);
    }
  }
}

Future<T?> showCapsuleMenu<T>({
  required BuildContext context,
  RelativeRect? position,
  BuildContext? anchorContext,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  BoxConstraints? constraints,
  Color? color,
  Color? surfaceTintColor,
  double? elevation,
  ShapeBorder? shape,
  EdgeInsetsGeometry? menuPadding,
}) async {
  assert(position != null || anchorContext != null);
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;
  final local = position?.toRect(Offset.zero & overlay.size);
  final choice = await _showChoices<T>(
    context: context,
    anchor: anchorContext != null
        ? AnchoredMenuPosition.fromContext(anchorContext)
        : AnchoredMenuPosition.fromRect(
            // RelativeRect follows showMenu's menu-origin semantics. Callers
            // with a button use anchorContext to retain its full bounds.
            Rect.fromPoints(
              overlay.localToGlobal(local!.topLeft),
              overlay.localToGlobal(local.topRight),
            ),
          ),
    width: constraints?.maxWidth.isFinite == true
        ? constraints!.maxWidth
        : null,
    options: [
      for (final entry in items)
        if (entry is PopupMenuItem<T>)
          CapsuleMenuOption(
            key: entry.key,
            value: entry.value,
            child: entry.child ?? const SizedBox(),
            enabled: entry.enabled,
            checked: entry is CheckedPopupMenuItem<T> ? entry.checked : null,
            selected: entry is CheckedPopupMenuItem<T>
                ? entry.checked
                : initialValue != null && entry.value == initialValue,
            onTap: entry.onTap,
          )
        else if (entry is PopupMenuDivider)
          const CapsuleMenuOption(
            value: null,
            enabled: false,
            child: Divider(height: 1, color: Colors.white12),
          ),
    ],
  );
  return choice?.value;
}

/// Keeps the existing action/value semantics while sharing the quality popup.
class CapsulePopupMenuButton<T> extends PopupMenuButton<T> {
  const CapsulePopupMenuButton({
    super.key,
    required super.itemBuilder,
    super.initialValue,
    super.onSelected,
    super.onOpened,
    super.onCanceled,
    super.tooltip,
    super.child,
    super.icon,
    super.iconSize,
    super.enabled,
    super.padding,
    super.offset,
    super.position,
    super.color,
    super.shape,
    super.constraints,
    super.surfaceTintColor,
    super.useRootNavigator,
    // PopupMenuButton paints its IconButton from this. Toolbar slots under
    // Material's 40px minimum pass IconButton.styleFrom here.
    super.style,
  });
  @override
  PopupMenuButtonState<T> createState() => _CapsulePopupState<T>();
}

class _CapsulePopupState<T> extends PopupMenuButtonState<T> {
  bool _opening = false;

  List<CapsuleMenuOption<T>> _options(List<PopupMenuEntry<T>> entries) => [
    for (final entry in entries)
      if (entry is PopupMenuItem<T>)
        CapsuleMenuOption(
          key: entry.key,
          value: entry.value,
          child: entry.child ?? const SizedBox(),
          enabled: entry.enabled,
          checked: entry is CheckedPopupMenuItem<T> ? entry.checked : null,
          selected: entry is CheckedPopupMenuItem<T>
              ? entry.checked
              : widget.initialValue != null &&
                    entry.value == widget.initialValue,
          onTap: entry.onTap,
        )
      else if (entry is PopupMenuDivider)
        const CapsuleMenuOption(
          value: null,
          enabled: false,
          child: Divider(height: 1, color: Colors.white12),
        ),
  ];
  @override
  void showButtonMenu() async {
    if (_opening || !widget.enabled) return;
    final entries = widget.itemBuilder(context);
    if (entries.isEmpty) return;
    _opening = true;
    widget.onOpened?.call();
    try {
      final choice = await _showChoices<T>(
        context: context,
        anchor: AnchoredMenuPosition.fromContext(
          context,
          offset: widget.offset,
        ),
        title: widget.tooltip ?? '选择操作',
        width: widget.constraints?.maxWidth.isFinite == true
            ? widget.constraints!.maxWidth
            : null,
        options: _options(entries),
        optionsBuilder: (menuContext) =>
            _options(widget.itemBuilder(menuContext)),
      );
      if (!mounted) return;
      if (choice == null) {
        widget.onCanceled?.call();
      } else {
        widget.onSelected?.call(choice.value as T);
      }
    } finally {
      _opening = false;
    }
  }
}
