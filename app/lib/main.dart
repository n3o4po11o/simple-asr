// simple-asr — Flutter UI（SwiftUI 参考项目 QwenASR 的跨平台移植）。
// 布局对齐 ContentView：顶栏（状态胶囊+加载按钮+设置）/ 主区（下载引导或
// 拖放区+转写结果）/ 底部状态栏；全窗口拖放带覆盖层反馈。
// 后端经 NativeApi 抽象接入 Rust（frb 生成绑定，FrbApi 实现）。

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'frb_api.dart';
import 'native_api.dart';
import 'src/rust/frb_generated.dart';
import 'widgets/download_guidance.dart';
import 'widgets/drop_zone.dart';
import 'widgets/header_bar.dart';
import 'widgets/player_bar.dart';
import 'widgets/speaker_bar.dart';
import 'widgets/timed_transcript_view.dart';
import 'widgets/settings_sheet.dart';
import 'widgets/status_bar.dart';
import 'widgets/transcript_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await RustLib.init();
  runApp(const SimpleAsrApp());
}

class SimpleAsrApp extends StatelessWidget {
  const SimpleAsrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'simple-asr',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  /// widget 测试可注入 StubApi；缺省用真实 Rust 后端（FrbApi）。
  const HomePage({super.key, this.api});

  final NativeApi? api;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final model = AppModel(api: widget.api ?? FrbApi());
  bool isDropTargeted = false;

  @override
  void initState() {
    super.initState();
    model.startup();
  }

  Future<void> _openImporter() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '音频', extensions: kAudioExtensions.toList()),
      ],
    );
    if (file != null) await _guardedSelect(file.path);
  }

  /// 校准中换音频的守卫：询问保存进度。保存=留在当前（不加载）；
  /// 放弃=先干净退出校准会话再加载（避免 UI 状态混乱）。
  Future<void> _guardedSelect(String path) async {
    if (model.proofActive) {
      final ctx = context;
      final keep = await showDialog<bool>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('正在手动校准中'),
          content: const Text(
            '拉入了新的音频文件。是否保存当前校准进度？\n\n'
            '「保存进度」留在当前校准，不加载新文件；\n'
            '「放弃校准」丢弃修改，加载新文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('保存进度（不加载）'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('放弃校准，加载新文件'),
            ),
          ],
        ),
      );
      // keep == null（点外部关闭）按「保存进度」处理，最保守
      if (keep == null || keep) return;
      await model.discardProofSession();
    }
    model.selectAudioFile(path);
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    final path = details.files.firstOrNull?.path;
    if (path == null) return;
    if (!isAudioPath(path)) {
      model.showError('不支持的文件类型：$path（仅支持音频文件）');
      return;
    }
    await _guardedSelect(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => setState(() => isDropTargeted = true),
        onDragExited: (_) => setState(() => isDropTargeted = false),
        onDragDone: _handleDrop,
        child: Stack(
          children: [
            ListenableBuilder(
              listenable: model,
              builder: (context, _) {
                return Column(
                  children: [
                    HeaderBar(
                      model: model,
                      onSettings: () => showSettingsSheet(context, model),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          children: [
                            if (model.loadState == LoadState.notDownloaded) ...[
                              // 窗口过小时引导面板可滚动
                              Expanded(
                                child: SingleChildScrollView(
                                  child: DownloadGuidance(
                                    modelDir: model.modelDir,
                                    source: model.settings.source,
                                    onSourceChanged: (s) => model.updateSettings(
                                        model.settings.copyWith(source: s)),
                                    onDownload: model.download,
                                    onRecheck: model.recheckDisk,
                                    busy: model.isBusy,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 140,
                                child: TranscriptView(text: model.transcription),
                              ),
                            ] else ...[
                              DropZone(
                                fileName: model.audioFileName,
                                onImport: _openImporter,
                                busy: model.isBusy,
                                highlight: isDropTargeted,
                              ),
                              const SizedBox(height: 12),
                              // 校对模式（转写完成且有播放器）：播放栏 + 歌词式行
                              if (model.proofActive) ...[
                                SpeakerBar(model: model),
                                PlayerBar(model: model),
                                const SizedBox(height: 8),
                                Expanded(child: TimedTranscriptView(model: model)),
                              ] else
                                Expanded(
                                    child: TranscriptView(
                                  text: model.transcription,
                                  diff: model.proofDiff,
                                )),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    StatusBar(model: model),
                  ],
                );
              },
            ),

            // 全窗口拖放覆盖层（对齐 Swift 的 onDrop overlay）
            if (isDropTargeted)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.input,
                              size: 44,
                              color: theme.colorScheme.primary,
                              weight: 600),
                          const SizedBox(height: 8),
                          Text(
                            '松开以加载音频文件',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
