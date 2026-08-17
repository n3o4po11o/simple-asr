// 顶栏：标题 + 模型仓库 id + 加载状态胶囊 + 加载/卸载/取消按钮 + 设置。
// 对齐 Swift ContentView.headerBar / loadStatusPill / loadToggleButton。

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../native_api.dart';

class HeaderBar extends StatelessWidget {
  const HeaderBar({super.key, required this.model, required this.onSettings});

  final AppModel model;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 24, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Qwen3-ASR 语音转文字',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                kModelRepoId,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          const Spacer(),
          _StatusPill(state: model.loadState, progress: model.downloadProgress),
          const SizedBox(width: 8),
          _LoadButton(model: model),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: model.isBusy ? null : onSettings,
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('设置'),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state, this.progress});

  final LoadState state;
  final DownloadProgress? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget content;
    Color? color;
    switch (state) {
      case LoadState.idle:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '未加载',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        );
      case LoadState.notDownloaded:
        color = Colors.orange;
        content = _pillRow(
          Icons.download_outlined,
          '未下载模型',
          Colors.orange.shade800,
        );
      case LoadState.downloading:
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Text(
              '下载中 ${((progress?.fraction ?? 0) * 100).toInt()}%',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      case LoadState.loadingModel:
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Text('加载中…', style: theme.textTheme.bodySmall),
          ],
        );
      case LoadState.ready:
        color = Colors.green;
        content = _pillRow(Icons.check_circle, '模型就绪', Colors.green.shade700);
      case LoadState.failed:
        color = Colors.red;
        content = _pillRow(
          Icons.warning_amber_rounded,
          '加载失败',
          Colors.red.shade700,
        );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:
            color?.withValues(alpha: 0.12) ??
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: content,
    );
  }

  Widget _pillRow(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

/// 加载/卸载/取消三态按钮（对齐 loadToggleButton）。
class _LoadButton extends StatelessWidget {
  const _LoadButton({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    switch (model.loadState) {
      case LoadState.ready:
        return Tooltip(
          message: '从内存卸载模型以释放显存',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: model.isTranscribing ? null : model.unloadModel,
            icon: const Icon(Icons.eject, size: 18),
            label: const Text('卸载模型'),
          ),
        );
      case LoadState.loadingModel:
        return OutlinedButton.icon(
          onPressed: model.cancelLoad,
          icon: const Icon(Icons.close, size: 18),
          label: const Text('取消'),
        );
      case LoadState.idle:
      case LoadState.downloading:
        return Tooltip(
          message: model.modelIsOnDisk ? '把模型加载进内存' : '本地未找到模型，请先下载',
          child: FilledButton.icon(
            onPressed: (model.modelIsOnDisk && !model.isBusy)
                ? model.loadModelFromDisk
                : null,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('加载模型'),
          ),
        );
      case LoadState.notDownloaded:
      case LoadState.failed:
        return const SizedBox.shrink();
    }
  }
}
