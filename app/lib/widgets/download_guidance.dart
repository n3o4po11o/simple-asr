// 下载引导面板（模型未就绪时替换拖放区显示）。
// 对齐 Swift ContentView.downloadGuidance / commandRow，并新增「内置下载」
// 主按钮（本项目 asr-core 自带双源下载器，与 CLI 方式二选一）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../native_api.dart';

class DownloadGuidance extends StatelessWidget {
  const DownloadGuidance({
    super.key,
    required this.modelDir,
    required this.source,
    required this.onSourceChanged,
    required this.onDownload,
    required this.onRecheck,
    required this.busy,
  });

  final String modelDir;
  final ModelSource source;
  final ValueChanged<ModelSource> onSourceChanged;
  final VoidCallback onDownload;
  final VoidCallback onRecheck;
  final bool busy;

  void _copyWithToast(BuildContext context, String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(toast), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.download_for_offline_outlined,
                size: 34,
                color: Colors.orange,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '需要先下载模型',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '首次使用需下载 Qwen3-ASR-1.7B-hf（约 4 GB）。推荐用内置下载器，'
                      '或用 modelscope 命令行下载（境内更稳定、可断点续传）。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 内置下载（首选）：源选择 + 下载 + 重新检查
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : onDownload,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: Text(source == ModelSource.modelScope
                    ? '内置下载（ModelScope 源）'
                    : '内置下载（Hugging Face 源）'),
              ),
              SegmentedButton<ModelSource>(
                segments: const [
                  ButtonSegment(
                    value: ModelSource.modelScope,
                    label: Text('ModelScope'),
                    tooltip: '中国境内快（默认）',
                  ),
                  ButtonSegment(
                    value: ModelSource.huggingFace,
                    label: Text('Hugging Face'),
                    tooltip: '境外网络适用',
                  ),
                ],
                selected: {source},
                onSelectionChanged:
                    busy ? null : (s) => onSourceChanged(s.first),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onRecheck,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('我已下载，重新检查'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),

          // 模型目录
          Text(
            '模型应放在以下目录：',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  modelDir.isEmpty ? '（M2 接入后端后显示）' : modelDir,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: '复制路径',
                onPressed: modelDir.isEmpty
                    ? null
                    : () => _copyWithToast(context, modelDir, '路径已复制'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // modelscope CLI 命令
          Text(
            '或在终端中依次执行：',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _CommandRow(
            hint: '1) 安装 modelscope（已安装可跳过）',
            command: kModelscopeInstallCommand,
          ),
          const SizedBox(height: 6),
          _CommandRow(
            hint: '2) 下载模型到上面的目录',
            command: modelscopeDownloadCommand(modelDir),
          ),
          const SizedBox(height: 14),
          Text(
            '下载完成后点「我已下载，重新检查」即可自动加载。目录需包含 config.json、'
            'model.safetensors、tokenizer.json 等文件（modelscope 会一并下载）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(kModelScopeUrl)),
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('打开 ModelScope 页面'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 终端风格命令行（绿色 $ 前缀 + 等宽字体 + 复制按钮）。
class _CommandRow extends StatelessWidget {
  const _CommandRow({this.hint, required this.command});

  final String? hint;
  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Text(
                r'$ ',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.green,
                  fontSize: 13,
                ),
              ),
              Expanded(
                child: SelectableText(
                  command,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: '复制命令',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: command));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text('命令已复制'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
