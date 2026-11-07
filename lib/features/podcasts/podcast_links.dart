import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_web_navigation.dart';
import '../../theme/app_tokens.dart';
import 'podcast_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class PodcastLink {
  const PodcastLink(this.label, this.url);
  final String label, url;
}

Future<void> showPodcastLinks(
  BuildContext context, {
  required String title,
  required List<PodcastLink> links,
}) => showDialog<void>(
  context: context,
  builder: (_) => PodcastTypography(
    child: _PodcastLinksDialog(
      title: title,
      links: links.where((link) {
        final uri = Uri.tryParse(link.url);
        return uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty;
      }).toList(),
    ),
  ),
);

class _PodcastLinksDialog extends StatefulWidget {
  const _PodcastLinksDialog({required this.title, required this.links});
  final String title;
  final List<PodcastLink> links;
  @override
  State<_PodcastLinksDialog> createState() => _PodcastLinksDialogState();
}

class _PodcastLinksDialogState extends State<_PodcastLinksDialog> {
  String? _copied, _error;
  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppTokens.bgCard,
    title: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final link in widget.links)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      link.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      link.url,
                      style: const TextStyle(
                        color: AppTokens.text2,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        DesktopButtonClickRegion(
                          child: TextButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text(_copied == link.url ? '已复制' : '复制链接'),
                            onPressed: () async {
                              try {
                                await Clipboard.setData(
                                  ClipboardData(text: link.url),
                                );
                                if (mounted) {
                                  setState(() {
                                    _copied = link.url;
                                    _error = null;
                                  });
                                }
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => _error = '复制失败，可以长按或选中上方链接复制。',
                                  );
                                }
                              }
                            },
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: TextButton.icon(
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 16,
                            ),
                            label: const Text('打开'),
                            onPressed: () async {
                              try {
                                await AppWebNavigation.open(
                                  context,
                                  Uri.parse(link.url),
                                  title: link.label,
                                );
                              } catch (_) {
                                if (mounted) {
                                  setState(() => _error = '无法打开链接，可复制后在浏览器查看。');
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (widget.links.isEmpty) const Text('来源没有提供公开链接。'),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AppTokens.text2)),
          ],
        ),
      ),
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}
