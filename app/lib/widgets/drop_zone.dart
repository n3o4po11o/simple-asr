// 拖放区 + 导入按钮（对齐 Swift ContentView.dropZone）。
// 全窗口拖放由 HomePage 的 desktop_drop DropTarget 负责，这里只是常显的
// 提示区域；拖入悬停时整个窗口会显示覆盖层。

import 'package:flutter/material.dart';

class DropZone extends StatelessWidget {
  const DropZone({
    super.key,
    required this.fileName,
    required this.onImport,
    required this.busy,
    this.highlight = false,
  });

  final String? fileName;
  final VoidCallback onImport;
  final bool busy;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = highlight ? theme.colorScheme.primary : Colors.grey;
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlight ? border : border.withValues(alpha: 0.3),
          width: highlight ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.library_music_outlined,
            size: 22,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (fileName != null) ...[
                  Text(
                    fileName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    '拖入新文件或点按「导入」替换',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ] else ...[
                  const Text('拖入音频文件或点按「导入」', style: TextStyle(fontSize: 14)),
                  Text(
                    '支持 m4a / mp3 / wav / aac / aiff / flac / ogg',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          OutlinedButton(
            onPressed: busy ? null : onImport,
            child: const Text('导入…'),
          ),
        ],
      ),
    );
  }
}
