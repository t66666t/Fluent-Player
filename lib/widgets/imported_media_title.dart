import 'package:flutter/material.dart';

import '../services/imported_media_navigation.dart';

/// A task title becomes a library-card link only after an import succeeds.
/// Preview buttons remain separate and do not alter the playback queue.
class ImportedMediaTitle extends StatefulWidget {
  const ImportedMediaTitle({
    super.key,
    required this.title,
    this.libraryId,
    this.resolveLibraryId,
    this.beforeOpen,
    this.style,
    this.maxLines = 2,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
    this.textKey,
  });

  final String title;
  final String? libraryId;
  final Future<String?> Function()? resolveLibraryId;
  final Future<void> Function()? beforeOpen;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;
  final Key? textKey;

  @override
  State<ImportedMediaTitle> createState() => _ImportedMediaTitleState();
}

class _ImportedMediaTitleState extends State<ImportedMediaTitle> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final id = widget.libraryId ?? await widget.resolveLibraryId?.call();
      if (!mounted) return;
      await openImportedLibraryMedia(
        context,
        id,
        beforeOpen: widget.beforeOpen,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('暂时无法打开此媒体，请重试')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final linked =
        widget.libraryId?.isNotEmpty == true || widget.resolveLibraryId != null;
    final style = widget.style ?? DefaultTextStyle.of(context).style;
    final text = Text(
      widget.title,
      key: widget.textKey,
      style: linked
          ? style.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: style.color,
            )
          : style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
    if (!linked) return text;
    return Tooltip(
      message: '打开媒体库中的此媒体',
      child: Semantics(
        link: true,
        child: InkWell(onTap: _opening ? null : _open, child: text),
      ),
    );
  }
}
