import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/subtitle_parser.dart';
import '../models/subtitle_model.dart';
import '../widgets/media_library_page_shortcuts.dart';

class SubtitlePreviewScreen extends StatefulWidget {
  final String subtitlePath;

  const SubtitlePreviewScreen({super.key, required this.subtitlePath});

  @override
  State<SubtitlePreviewScreen> createState() => _SubtitlePreviewScreenState();
}

class _SubtitlePreviewScreenState extends State<SubtitlePreviewScreen> {
  List<SubtitleItem> _subtitles = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSubtitle();
  }

  Future<void> _loadSubtitle() async {
    try {
      final file = File(widget.subtitlePath);
      if (!await file.exists()) {
        throw Exception("File not found");
      }

      List<int> bytes = await file.readAsBytes();
      String content = SubtitleParser.decodeBytes(bytes);
      if (content.isEmpty) {
        throw Exception("Decoding failed");
      }

      final parsed = SubtitleParser.parse(content);
      parsed.sort((a, b) => a.startTime.compareTo(b.startTime));

      if (mounted) {
        setState(() {
          _subtitles = parsed;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      MediaLibraryPageShortcuts(child: _buildPreview());

  Widget _buildPreview() {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("字幕预览"),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Text(
                  "加载失败: $_error",
                  style: const TextStyle(color: Colors.red),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _subtitles.length,
                separatorBuilder: (ctx, i) =>
                    const Divider(color: Colors.white12),
                itemBuilder: (context, index) {
                  final item = _subtitles[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "${_formatDuration(item.startTime)} --> ${_formatDuration(item.endTime)}",
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return "$h:$m:$s,$ms";
  }
}
