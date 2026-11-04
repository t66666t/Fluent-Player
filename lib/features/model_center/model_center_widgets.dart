import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class ModelCenterProgress extends StatelessWidget {
  const ModelCenterProgress({super.key, this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LinearProgressIndicator(
      value: value,
      color: colors.primary,
      backgroundColor: colors.onSurface.withValues(alpha: .12),
    );
  }
}

/// Shared surfaces for the model center and its configuration subpages.
class ModelCenterPanel extends StatelessWidget {
  const ModelCenterPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle = '',
    this.trailing,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (children.isNotEmpty) const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class ModelCenterSetting extends StatelessWidget {
  const ModelCenterSetting({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
    this.subtitle,
  });

  final String label;
  final String value;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(value, style: theme.textTheme.bodyMedium),
                      if (subtitle case final text?)
                        Text(text, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                ?trailing,
                if (onTap != null)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.expand_more_rounded, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ModelCenterStatus extends StatelessWidget {
  const ModelCenterStatus(this.label, {super.key, this.error = false});
  final String label;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = error ? colors.error : colors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class ModelCenterChoice<T> {
  const ModelCenterChoice({
    required this.value,
    required this.title,
    required this.group,
    this.subtitle = '',
    this.detail = '',
    this.actionLabel,
    this.actionIcon = Icons.download_outlined,
    this.actionKey,
  });

  final T value;
  final String title, group, subtitle, detail;
  final String? actionLabel;
  final IconData actionIcon;
  final Key? actionKey;
}

class ModelCenterPick<T> {
  const ModelCenterPick(this.value, {this.action = false});
  final T value;
  final bool action;
}

Future<ModelCenterPick<T>?> showModelCenterPicker<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required List<ModelCenterChoice<T>> choices,
  bool searchable = true,
}) {
  final picker = ModelCenterPicker<T>(
    title: title,
    selected: selected,
    choices: choices,
    searchable: searchable,
  );
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 600) {
    return showDialog<ModelCenterPick<T>>(
      context: context,
      builder: (context) => Dialog(
        insetAnimationDuration: Duration.zero,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: picker,
        ),
      ),
    );
  }
  return showModalBottomSheet<ModelCenterPick<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    clipBehavior: Clip.antiAlias,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              ((MediaQuery.sizeOf(context).height -
                          MediaQuery.viewInsetsOf(context).bottom) *
                      .9)
                  .clamp(0.0, double.infinity),
        ),
        child: picker,
      ),
    ),
  );
}

class ModelCenterPicker<T> extends StatefulWidget {
  const ModelCenterPicker({
    super.key,
    required this.title,
    required this.selected,
    required this.choices,
    this.searchable = true,
  });
  final String title;
  final T selected;
  final List<ModelCenterChoice<T>> choices;
  final bool searchable;

  @override
  State<ModelCenterPicker<T>> createState() => _ModelCenterPickerState<T>();
}

class _ModelCenterPickerState<T> extends State<ModelCenterPicker<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choices = widget.choices.where((choice) {
      final text = '${choice.title} ${choice.subtitle} ${choice.detail}';
      return text.toLowerCase().contains(_query.toLowerCase());
    }).toList();

    return SafeArea(
      top: false,
      child: CustomScrollView(
        shrinkWrap: true,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: IconButton(
                      tooltip: '关闭选择',
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.searchable)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: TextField(
                  key: const ValueKey('model-center-picker-search'),
                  decoration: const InputDecoration(
                    hintText: '搜索名称或语言',
                    prefixIcon: Icon(Icons.search_rounded),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            sliver: SliverList.list(
              children: [
                if (choices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没有符合条件的选项'),
                  ),
                for (var index = 0; index < choices.length; index++) ...[
                  if (choices[index].group.isNotEmpty &&
                      (index == 0 ||
                          choices[index - 1].group != choices[index].group))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: Text(
                        choices[index].group,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  _choice(choices[index]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _choice(ModelCenterChoice<T> choice) {
    final selected = choice.value == widget.selected;
    final theme = Theme.of(context);
    return Semantics(
      key: ValueKey('model-center-choice-${choice.value}'),
      selected: selected,
      child: Material(
        borderRadius: BorderRadius.circular(10),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: .08)
            : Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.pop(context, ModelCenterPick(choice.value)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        choice.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (choice.subtitle.isNotEmpty)
                        Text(choice.subtitle, style: theme.textTheme.bodySmall),
                      if (choice.detail.isNotEmpty)
                        Text(
                          choice.detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (choice.actionLabel case final label?)
                  DesktopButtonClickRegion(
                    child: IconButton(
                      key: choice.actionKey,
                      tooltip: label,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => Navigator.pop(
                        context,
                        ModelCenterPick(choice.value, action: true),
                      ),
                      icon: Icon(choice.actionIcon),
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
