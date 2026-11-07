import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'external_ai_controller.dart';

const externalAiVerifiedColor = Color(0xFF72B58A);

String externalAiCallTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// HTTP requests prove a completed read, not that an idle Agent stays online.
class ExternalAiConnectionStatus extends StatelessWidget {
  const ExternalAiConnectionStatus({super.key, required this.controller});

  final ExternalAiController controller;

  @override
  Widget build(BuildContext context) {
    final lastCall = controller.lastExternalToolCallAt;
    final verified = lastCall != null;
    final label = !controller.running
        ? '外部 AI 读取已关闭'
        : verified
        ? '已收到 Agent 调用 · ${externalAiCallTime(lastCall)}'
        : '等待 Agent 调用';
    return Tooltip(
      message: verified
          ? '本次开启后已成功响应 ${controller.externalToolCallCount} 次外部工具调用。\n'
                '这是最近一次调用记录，不代表 Agent 持续在线。'
          : 'Agent 成功调用播放器工具后，这里会自动更新；播放器自身检测不计入。',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            verified ? Icons.check_circle_outline : Icons.hub_outlined,
            size: 14,
            color: verified ? externalAiVerifiedColor : AppTokens.text2,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              key: const ValueKey('external-ai-call-status'),
              style: TextStyle(
                fontSize: 12,
                color: verified ? externalAiVerifiedColor : AppTokens.text2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
