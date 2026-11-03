import 'package:flutter/material.dart';

import '../utils/select_all_on_acquire.dart';
import 'dialog_autofocus.dart';
import 'dialog_keyboard_viewport.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class OcrTimeRangeDialog extends StatefulWidget {
  const OcrTimeRangeDialog({
    super.key,
    required this.duration,
    required this.values,
  });

  final Duration duration;
  final RangeValues values;

  @override
  State<OcrTimeRangeDialog> createState() => _OcrTimeRangeDialogState();
}

class _OcrTimeRangeDialogState extends State<OcrTimeRangeDialog> {
  late final _start = TextEditingController(text: _format(widget.values.start));
  late final _end = TextEditingController(text: _format(widget.values.end));
  final _startFocus = FocusNode();
  final _endFocus = FocusNode();
  final _form = GlobalKey<FormState>();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    selectEntireValue(_start);
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    super.dispose();
  }

  String _format(double milliseconds) {
    final value = Duration(milliseconds: milliseconds.round());
    final seconds = '${value.inSeconds % 60}'.padLeft(2, '0');
    final minutes = '${value.inMinutes % 60}'.padLeft(2, '0');
    final whole = value.inHours > 0
        ? '${value.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
    final fraction = value.inMilliseconds % 1000;
    return fraction == 0
        ? whole
        : '$whole.${'$fraction'.padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
  }

  int? _parse(String text) {
    final normalized = text.trim().replaceAll('：', ':');
    if (!RegExp(r'^\d+(?::\d{1,2}){0,2}(?:\.\d{1,3})?$').hasMatch(normalized)) {
      return null;
    }
    final decimal = normalized.split('.');
    final parts = decimal.first.split(':');
    var seconds = 0;
    for (var index = 0; index < parts.length; index++) {
      final part = int.tryParse(parts[index]);
      if (part == null ||
          (index > 0 && part >= 60) ||
          seconds > (0x7FFFFFFFFFFFFFFF - part) ~/ 60) {
        return null;
      }
      seconds = seconds * 60 + part;
    }
    final fraction = decimal.length == 1
        ? 0
        : int.parse(decimal.last.padRight(3, '0'));
    if (seconds > (0x7FFFFFFFFFFFFFFF - fraction) ~/ 1000) return null;
    return seconds * 1000 + fraction;
  }

  String? _validate(String? text, {required bool start}) {
    final value = _parse(text ?? '');
    if (value == null) return '请输入有效时间';
    if (value > widget.duration.inMilliseconds) return '不能超过视频时长';
    final other = _parse(start ? _end.text : _start.text);
    if (!start && other != null && value <= other) {
      return '结束时间需晚于开始时间';
    }
    return null;
  }

  void _confirm() {
    setState(() => _submitted = true);
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(
      RangeValues(
        _parse(_start.text)!.toDouble(),
        _parse(_end.text)!.toDouble(),
      ),
    );
  }

  Widget _field({required bool start}) {
    final controller = start ? _start : _end;
    final focus = start ? _startFocus : _endFocus;
    return SelectAllOnAcquire(
      controller: controller,
      focusNode: focus,
      builder: (context, onTap) => TextFormField(
        key: ValueKey(start ? 'ocr-range-start' : 'ocr-range-end'),
        controller: controller,
        focusNode: focus,
        selectAllOnFocus: true,
        onTap: onTap,
        keyboardType: TextInputType.datetime,
        textInputAction: start ? TextInputAction.next : TextInputAction.done,
        decoration: InputDecoration(
          labelText: start ? '开始时间' : '结束时间',
          hintText: widget.duration.inHours > 0 ? '时:分:秒' : '分:秒',
          border: const OutlineInputBorder(),
          isDense: true,
          errorMaxLines: 2,
        ),
        validator: (text) => _validate(text, start: start),
        onChanged: (_) {
          if (_submitted) _form.currentState!.validate();
        },
        onFieldSubmitted: (_) {
          if (start) {
            _endFocus.requestFocus();
          } else {
            _confirm();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF65A2FF),
        brightness: Brightness.dark,
      ),
    ),
    child: DialogAutofocus(
      focusNode: _startFocus,
      child: DialogKeyboardViewport(
        child: AlertDialog(
          key: const ValueKey('ocr-time-range-dialog'),
          backgroundColor: const Color(0xFF20242A),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 16,
          ),
          title: const Text('时间范围'),
          content: SizedBox(
            width: 280,
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _field(start: true),
                  const SizedBox(height: 16),
                  _field(start: false),
                ],
              ),
            ),
          ),
          scrollable: true,
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
            DesktopButtonClickRegion(
              child: FilledButton(onPressed: _confirm, child: const Text('确定')),
            ),
          ],
        ),
      ),
    ),
  );
}
