// 底部状态栏：下载进度条、错误、进度文本、统计（tok/s、显存、语言）、
// 复制/保存、主操作按钮（停止/开始识别/重新检查）。
// 对齐 Swift ContentView.statusAndControls / controlBar。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../native_api.dart';

class StatusBar extends StatefulWidget {
  const StatusBar({super.key, required this.model});

  final AppModel model;

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  String? _savedMessage;

  void _flashSaved(String msg) {
    setState(() => _savedMessage = msg);
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _savedMessage = null);
    });
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: widget.model.transcription));
    _flashSaved('已复制到剪贴板');
  }

  Future<void> _exportSubtitle(BuildContext context, bool lrc) async {
    final content = lrc
        ? await widget.model.api.lastLrc()
        : await widget.model.api.lastSrt();
    if (content.isEmpty) {
      widget.model.showError('暂无可导出的字幕（先完成一次识别）');
      return;
    }
    final name = (widget.model.audioFileName ?? 'transcription');
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final loc = await getSaveLocation(
      suggestedName: lrc ? '$base.lrc' : '$base.srt',
    );
    if (loc == null) return;
    try {
      await File(loc.path).writeAsString(content, flush: true);
      _flashSaved(lrc ? '歌词已保存' : '字幕已保存');
    } catch (e) {
      widget.model.errorMessage = '导出失败：$e';
    }
  }

  /// 逐行重新对齐：修存量项目的空锚点/编辑后的行（需对齐模型与音频）。
  Future<void> _realign() async {
    final m = widget.model;
    try {
      final n = await m.realignLines();
      _flashSaved('已重新对齐 $n 行');
    } catch (e) {
      m.showError('重新对齐失败：$e');
    }
  }

  Future<void> _saveProject() async {
    final m = widget.model;
    final name = m.audioFileName;
    if (name == null) {
      m.showError('先完成一次识别或加载项目，再保存项目');
      return;
    }
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final loc = await getSaveLocation(suggestedName: '$base.asrproj');
    if (loc == null) return;
    try {
      await m.api.saveProject(loc.path);
      _flashSaved('项目已保存');
    } catch (e) {
      m.errorMessage = '保存项目失败：$e';
    }
  }

  /// 加载项目：音频路径失效时提示 + 手动选择（取消则中止，不进校准）。
  Future<void> _loadProject(BuildContext context) async {
    final m = widget.model;
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '校准项目', extensions: ['asrproj']),
      ],
    );
    if (file == null) return;
    if (!context.mounted) return;
    final LoadedProject info;
    try {
      info = await m.api.loadProject(file.path);
    } catch (e) {
      m.showError('加载项目失败：$e');
      return;
    }
    String? audio = info.audioPath;
    if (!info.audioExists) {
      if (!context.mounted) return;
      audio = await _pickMissingAudio(context, info.audioPath);
      if (audio == null) {
        m.showError('未选择音频文件，项目未载入校准');
        return;
      }
      await m.api.updateProjectAudio(audio);
    }
    final ok = await m.applyLoadedProject(audio);
    if (ok) {
      _flashSaved('项目已载入（${info.lineCount} 行）');
    } else {
      m.showError('项目为空，未载入校准');
    }
  }

  /// 原音频不在原路径：提示后手动选择新位置（null = 用户取消）。
  Future<String?> _pickMissingAudio(
    BuildContext context,
    String missingPath,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('找不到原始音频'),
        content: Text(
          '项目记录的音频文件不存在：\n'
          '$missingPath\n\n'
          '请手动选择该音频文件的新位置（校准播放与波形需要它）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('选择音频…'),
          ),
        ],
      ),
    );
    if (!context.mounted) return null;
    final f = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '音频', extensions: kAudioExtensions.toList()),
      ],
    );
    return f?.path;
  }

  Future<void> _save(BuildContext context) async {
    final m = widget.model;
    // 有校准成果：双选项（原始 / 校准后）；否则直接保存
    if (m.hasProofResult) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('保存文本'),
          content: const Text('保存哪个版本？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'original'),
              child: const Text('原始文本'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'proofed'),
              child: const Text('校准后文本'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      if (!mounted) return;
      await _saveText(
          choice == 'original' ? m.originalTranscription : m.proofedText);
      return;
    }
    await _saveText(m.transcription);
  }

  Future<void> _saveText(String content) async {
    final name = (widget.model.audioFileName ?? 'transcription');
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final loc = await getSaveLocation(suggestedName: '$base.txt');
    if (loc == null) return;
    try {
      await File(loc.path).writeAsString(content, flush: true);
      _flashSaved('已保存');
    } catch (e) {
      widget.model.errorMessage = '保存失败：$e';
    }
  }

  String _bytes(int v) {
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (v >= 1024 * 1024) return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '$v B';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.model;
    final p = m.downloadProgress;

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.only(top: 8, left: 16, right: 16, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 下载进度
          if (m.loadState == LoadState.downloading && p != null) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在下载 ${p.currentFile}  ·  ${p.completedFiles}/${p.totalFiles} 文件',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: p.fraction),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_bytes(p.completedBytes)} / ${_bytes(p.totalBytes)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: m.cancelDownload,
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],

          // 错误
          if (m.errorMessage != null)
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m.errorMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  tooltip: '关闭',
                  onPressed: m.clearError,
                ),
              ],
            ),

          // 进度文本
          if (m.progressText.isNotEmpty)
            Row(
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Text(
                  m.progressText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),

          // 保存成功提示
          if (_savedMessage != null)
            Row(
              children: [
                const Icon(Icons.check_circle, size: 14, color: Colors.green),
                const SizedBox(width: 6),
                Text(
                  _savedMessage!,
                  style: const TextStyle(fontSize: 12, color: Colors.green),
                ),
              ],
            ),

          const SizedBox(height: 6),
          _ControlBar(
            model: m,
            onCopy: () => _copy(context),
            onSave: () => _save(context),
            onSaveSubtitle: (lrc) => _exportSubtitle(context, lrc),
            onSaveProject: _saveProject,
            onLoadProject: () => _loadProject(context),
            onRealign: _realign,
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.model,
    required this.onCopy,
    required this.onSave,
    required this.onSaveSubtitle,
    required this.onSaveProject,
    required this.onLoadProject,
    required this.onRealign,
  });

  final AppModel model;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final void Function(bool lrc) onSaveSubtitle;
  final VoidCallback onSaveProject;
  final VoidCallback onLoadProject;
  final VoidCallback onRealign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = model;
    return Row(
      children: [
        // 统计
        if (m.tokensPerSecond > 0)
          _stat(
            theme,
            Icons.speed,
            '${m.tokensPerSecond.toStringAsFixed(1)} tok/s',
          ),
        if (m.tokensPerSecond > 0) const SizedBox(width: 10),
        if (m.peakMemoryGB > 0)
          _stat(theme, Icons.memory, '${m.peakMemoryGB.toStringAsFixed(1)} GB'),
        if (m.peakMemoryGB > 0) const SizedBox(width: 10),
        if (m.detectedLanguage != null)
          _stat(theme, Icons.public, m.detectedLanguage!),
        const Spacer(),

          // 项目（校准工作保存/续作；.asrproj 含逐字锚点与原文快照）——
          // 常显：打开 App 即可加载项目续作，无需先识别
          Builder(
            builder: (btnCtx) => OutlinedButton.icon(
              onPressed: () async {
                final box = btnCtx.findRenderObject() as RenderBox;
                final pos = box.localToGlobal(Offset(0, box.size.height));
                final size = MediaQuery.of(btnCtx).size;
                final v = await showMenu<String>(
                  context: btnCtx,
                  position: RelativeRect.fromLTRB(
                    pos.dx, pos.dy,
                    size.width - pos.dx - box.size.width,
                    size.height - pos.dy,
                  ),
                  items: const [
                    PopupMenuItem(value: 'save', child: Text('保存项目…')),
                    PopupMenuItem(value: 'load', child: Text('加载项目…')),
                    PopupMenuItem(value: 'realign', child: Text('重新对齐时间轴…')),
                  ],
                );
                if (v == 'save') onSaveProject();
                if (v == 'load') onLoadProject();
                if (v == 'realign') onRealign();
              },
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('项目'),
                  Icon(Icons.arrow_drop_down, size: 16),
                ],
              ),
            ),
          ),

        // 输出操作
        if (m.transcription.isNotEmpty) ...[
          OutlinedButton.icon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('保存…'),
          ),
          const SizedBox(width: 8),
          // 与复制/保存同形态的菜单按钮（曾用 PopupMenuButton 包禁用按钮，
          // 灰色外观让用户以为不可点击）
          Builder(
            builder: (btnCtx) => OutlinedButton.icon(
              onPressed: () async {
                final box = btnCtx.findRenderObject() as RenderBox;
                final pos = box.localToGlobal(Offset(0, box.size.height));
                final size = MediaQuery.of(btnCtx).size;
                final v = await showMenu<String>(
                  context: btnCtx,
                  position: RelativeRect.fromLTRB(
                    pos.dx, pos.dy,
                    size.width - pos.dx - box.size.width,
                    size.height - pos.dy,
                  ),
                  items: const [
                    PopupMenuItem(value: 'srt', child: Text('导出 SRT 字幕…')),
                    PopupMenuItem(value: 'lrc', child: Text('导出 LRC 歌词…')),
                  ],
                );
                if (v != null) onSaveSubtitle(v == 'lrc');
              },
              icon: const Icon(Icons.subtitles_outlined, size: 16),
              label: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('字幕'),
                  Icon(Icons.arrow_drop_down, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],

        // 手动校准（转写完成后出现；校对中显示为退出）
        if (!m.isTranscribing && m.transcription.isNotEmpty) ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: m.proofActive
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            onPressed: m.toggleProofMode,
            icon: Icon(
              m.proofActive ? Icons.close : Icons.fact_check_outlined,
              size: 16,
            ),
            label: Text(m.proofActive ? '退出校准' : '手动校准'),
          ),
          const SizedBox(width: 8),
        ],

        // 主操作
        if (m.isTranscribing)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: m.stopTranscription,
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('停止'),
          )
        else if (m.loadState == LoadState.notDownloaded)
          FilledButton.icon(
            onPressed: m.recheckDisk,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('我已下载，重新检查'),
          )
        else if (m.isModelReady || m.modelIsOnDisk)
          FilledButton.icon(
            onPressed: (m.audioFilePath == null || m.isBusy)
                ? null
                : m.transcribe,
            icon: const Icon(Icons.graphic_eq, size: 16),
            label: Text(m.isModelReady ? '开始识别' : '加载模型并识别'),
          ),
      ],
    );
  }

  Widget _stat(ThemeData theme, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.outline),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
