import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/subtitle_font.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<bool> confirmSubtitleFontLicenses(
  BuildContext context,
  List<SubtitleFontAsset> fonts,
) async {
  final restricted = fonts
      .where((f) => f.license != SubtitleFontLicense.commercial)
      .toList();
  if (restricted.isEmpty) return true;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('检查字体授权'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '以下字体的授权需要确认。用于商业发布前，请确认已获得相应用途的许可。',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  for (final font in restricted)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  font.name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                Text(
                                  font.license.label,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.orangeAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (font.licenseUrl.isNotEmpty ||
                              font.sourceUrl.isNotEmpty)
                            DesktopButtonClickRegion(
                              child: TextButton(
                                onPressed: () async {
                                  final uri = Uri.parse(
                                    font.licenseUrl.isNotEmpty
                                        ? font.licenseUrl
                                        : font.sourceUrl,
                                  );
                                  await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                },
                                child: const Text('查看授权'),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回调整'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续合成'),
              ),
            ),
          ],
        ),
      ) ??
      false;
}
