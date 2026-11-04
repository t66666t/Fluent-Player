import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'folder_transfer_models.dart';
import 'progress_sync_screen.dart';
import 'progress_sync_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// One in-app hint per incoming folder request.
///
/// The sync page already shows the request, so the hint stays quiet there.
/// No extra notification permission is required.
class FolderSyncRequestPrompt extends StatefulWidget {
  const FolderSyncRequestPrompt({super.key, required this.child});

  final Widget child;

  @override
  State<FolderSyncRequestPrompt> createState() =>
      _FolderSyncRequestPromptState();
}

class _FolderSyncRequestPromptState extends State<FolderSyncRequestPrompt> {
  ProgressSyncService? _service;
  final Set<String> _shown = {};
  FolderTransferTask? _banner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ProgressSyncService? next;
    try {
      next = context.read<ProgressSyncService>();
    } on ProviderNotFoundException {
      next = null;
    }
    if (!identical(next, _service)) {
      _service?.removeListener(_onSync);
      _service = next;
      _service?.addListener(_onSync);
      _shown.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onSync();
      });
    }
  }

  @override
  void dispose() {
    _service?.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    final service = _service;
    if (!mounted || service == null) return;
    final offered = service.folderTransfers.where(
      (task) => task.incoming && task.phase == FolderTransferPhase.offered,
    );
    final pending = ProgressSyncScreen.isOpen
        ? null
        : offered.where((task) => task.id == _banner?.id).firstOrNull ??
              offered.where((task) => !_shown.contains(task.id)).firstOrNull;
    if (!identical(pending, _banner)) setState(() => _banner = pending);
  }

  Future<void> _open(FolderTransferTask task) async {
    final service = _service;
    if (service == null) return;
    _shown.add(task.id);
    setState(() => _banner = null);
    await openProgressSync(context, service);
    if (mounted) _onSync();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return Stack(
      children: [
        widget.child,
        if (banner != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF2A2A2A),
              child: ListTile(
                title: Text('${banner.peerName}想与你同步「${banner.folderName}」'),
                subtitle: const Text('点开后选择关联已有文件夹，或接收为新文件夹。'),
                trailing: DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => _open(banner),
                    child: const Text('查看'),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
