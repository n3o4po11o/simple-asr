// AppModel：Swift 版 TranscriptionViewModel 的移植。
// 状态机：idle（磁盘有模型未加载）/ notDownloaded / downloading /
// loadingModel / ready / failed；转写中 isTranscribing。


import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'native_api.dart';
import 'proof_diff.dart';

enum LoadState { idle, notDownloaded, downloading, loadingModel, ready, failed }

class AppModel extends ChangeNotifier {
  AppModel({NativeApi? api}) : api = api ?? StubApi();

  final NativeApi api;

  Settings settings = const Settings();
  String modelDir = '';

  LoadState loadState = LoadState.idle;
  DownloadProgress? downloadProgress;
  bool modelIsOnDisk = false;
  bool isTranscribing = false;

  String transcription = '';
  String progressText = '';
  String? errorMessage;
  String? audioFilePath;

  double tokensPerSecond = 0;
  double peakMemoryGB = 0;
  String? detectedLanguage;

  bool get isModelReady => loadState == LoadState.ready;
  bool get isBusy =>
      loadState == LoadState.downloading ||
      loadState == LoadState.loadingModel ||
      isTranscribing;

  String? get audioFileName {
    final p = audioFilePath;
    if (p == null) return null;
    final slash = p.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? p : p.substring(slash + 1);
  }

  void _notify() => notifyListeners();

  void _fail(Object e) {
    errorMessage = e.toString().replaceFirst(
      RegExp(r'^UnimplementedError[:：]\s*'),
      '',
    );
    loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
  }

  /// 启动：载入设置 → 检查模型是否在磁盘（**不自动加载**，等用户点按钮）。
  Future<void> startup() async {
    try {
      settings = await api.loadSettings();
    } catch (_) {
      /* 用默认设置 */
    }
    await checkModelOnDisk();
  }

  /// 只检查磁盘状态并刷新 UI，不触发加载。
  Future<void> checkModelOnDisk() async {
    try {
      modelIsOnDisk = await api.modelIsOnDisk();
      modelDir = await api.modelDirPath();
      loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
    } catch (e) {
      _fail(e);
    }
    _notify();
  }

  /// （重新）检查磁盘；若已就绪则自动加载。仅在用户点「我已下载，重新检查」
  /// 时调用（对齐 Swift recheckDisk 的显式动作语义）。
  Future<void> recheckDisk() async {
    await checkModelOnDisk();
    if (modelIsOnDisk && !isModelReady && !isBusy) {
      await loadModelFromDisk();
    }
  }

  /// 内置下载（asr-core 下载器，双源、断点续传）。
  Future<void> download() async {
    if (loadState == LoadState.downloading) return;
    loadState = LoadState.downloading;
    errorMessage = null;
    downloadProgress = null;
    _notify();
    try {
      await api.downloadModel(settings, (p) {
        downloadProgress = p;
        _notify();
      });
      modelIsOnDisk = await api.modelIsOnDisk();
      loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
    } catch (e) {
      if (e is! UnimplementedError) {
        modelIsOnDisk = await api.modelIsOnDisk().catchError(
          (_) => modelIsOnDisk,
        );
      }
      _fail(e);
    }
    _notify();
  }

  void cancelDownload() {
    api.cancelDownload();
    loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
    _notify();
  }

  Future<void> loadModelFromDisk() async {
    if (isBusy || isModelReady) return;
    loadState = LoadState.loadingModel;
    errorMessage = null;
    progressText = '正在加载模型…';
    _notify();
    try {
      await api.loadModel(settings);
      loadState = LoadState.ready;
      progressText = '';
    } catch (e) {
      _fail(e);
      progressText = '';
    }
    _notify();
  }

  void cancelLoad() {
    api.cancelLoad();
    loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
    progressText = '';
    _notify();
  }

  Future<void> unloadModel() async {
    stopTranscription();
    await api.unloadModel();
    loadState = modelIsOnDisk ? LoadState.idle : LoadState.notDownloaded;
    transcription = '';
    progressText = '';
    tokensPerSecond = 0;
    peakMemoryGB = 0;
    detectedLanguage = null;
    _notify();
  }

  void selectAudioFile(String path) {
    audioFilePath = path;
    transcription = '';
    errorMessage = null;
    progressText = '';
    tokensPerSecond = 0;
    peakMemoryGB = 0;
    detectedLanguage = null;
    _notify();
  }

  Future<void> transcribe() async {
    if (isTranscribing) return;
    if (audioFilePath == null) {
      errorMessage = '请先选择音频文件';
      _notify();
      return;
    }
    if (!isModelReady) {
      // 一键直达：模型在盘未加载时，先自动加载再转写
      if (!modelIsOnDisk) {
        errorMessage = '模型未下载，请先下载';
        _notify();
        return;
      }
      await loadModelFromDisk();
      if (!isModelReady) {
        _notify(); // 加载失败，错误信息已由 loadModelFromDisk 设置
        return;
      }
    }
    isTranscribing = true;
    errorMessage = null;
    transcription = '';
    tokensPerSecond = 0;
    peakMemoryGB = 0;
    detectedLanguage = null;
    progressText = '正在读取音频…';
    _notify();
    try {
      await api.transcribeFile(audioFilePath!, settings, (text) {
        if (!isTranscribing) return; // 停止后冻结已转写内容
        transcription = text; // 流式累计全文，替换式上屏
        progressText = '正在识别… ${text.length} 字';
        _notify();
      }, (status) {
        if (!isTranscribing) return;
        progressText = status; // 如「正在精修时间轴… 3/87」
        _notify();
      });
      if (!isTranscribing) {
        _notify(); // 用户已停止：保留部分文本与「已停止」状态
        return;
      }
      final stats = await api.lastStats();
      if (stats != null) {
        tokensPerSecond = stats.tokensPerSecond;
        peakMemoryGB = stats.peakMemoryGB;
        detectedLanguage = stats.language;
      }
      progressText =
          transcription.isNotEmpty ? '完成 ✓  ${transcription.length} 字' : '完成';
    } catch (e) {
      if (e is! UnimplementedError) {
        _fail(e);
      } else {
        errorMessage = e.toString().replaceFirst(
          RegExp(r'^UnimplementedError[:：]\s*'),
          '',
        );
      }
      // 外接 LLM 润色（转写完成后）：失败保留原文并提示
      if (settings.llmPolish && transcription.isNotEmpty) {
        progressText = '润色中（LLM）…';
        _notify();
        try {
          transcription = await api.polishText(transcription);
        } catch (e) {
          errorMessage = '润色失败（已保留原文）：$e';
        }
      }
      progressText = '';
    }
    isTranscribing = false;
    _notify();
  }

  void stopTranscription() {
    if (!isTranscribing) return;
    api.stopTranscribe();
    isTranscribing = false;
    progressText = '已停止';
    _notify();
  }

  void clearError() {
    errorMessage = null;
    _notify();
  }

    // ── 校对播放（media_kit）──
  Player? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _durSub;
  List<TranscriptLine> proofLines = [];
  List<double> wavePeaks = [];
  bool isPlaying = false;
  double positionSec = 0;
  double durationSec = 0;
  double playbackRate = 1.0;
  bool proofActive = false; // 手动校准模式（点按钮进入/退出）
  bool proofEditing = false; // 校准编辑态（有行聚焦；键盘快捷键让位）
  /// 说话人显示名（SPEAKER_00 → "客服"），UI 展示与 Rust 导出共用。
  final Map<String, String> speakerNames = {};
  /// 进入校准时的行原文快照（退出时 diff，行对行同源对齐）。
  List<TranscriptLine> originalProofLines = [];
  /// 退出校准后的成果（null = 从未校准过）。
  List<LineDiff>? proofDiff;
  String proofedText = '';

  bool get hasProofResult => proofDiff != null;

  /// 行 → 文本（带说话人名前缀，导出/回填同构）。
  String lineText(TranscriptLine l) {
    final spk = l.speaker == null ? '' : '[${speakerLabel(l.speaker!)}] ';
    return '$spk${l.text}';
  }

  /// 所有出现过的说话人 id（保序）。
  List<String> get speakerIds => proofLines
      .map((l) => l.speaker)
      .whereType<String>()
      .toSet()
      .toList();

  String speakerLabel(String spk) =>
      speakerNames[spk] ?? spk.replaceFirst('SPEAKER_', '说话人');

  Future<void> renameSpeaker(String spk, String name) async {
    speakerNames[spk] = name;
    await api.setSpeakerName(spk, name);
    _notify();
  }

  void setProofEditing(bool v) {
    if (proofEditing == v) return;
    proofEditing = v;
    _notify();
  }

  /// 由校准视图注册：把焦点收回快捷键层（退出编辑后空格/方向键仍有效）。
  void Function()? requestProofFocus;

  /// 丢弃校准会话（换音频前的「不保存」路径）：暂停播放、清空全部校准态，
  /// 主文本保持原转写（不回填 diff）。与 toggleProofMode 的退出（回填成果）相对。
  Future<void> discardProofSession() async {
    await _player?.pause();
    loopEnabled = false;
    loopStart = null;
    loopEnd = null;
    proofActive = false;
    proofEditing = false;
    proofLines = [];
    originalProofLines = [];
    proofDiff = null;
    proofedText = '';
    _notify();
  }

  /// 退出编辑态（波形点击/拖动等非文本交互时调用）：
  /// 让文本框失焦并把焦点送回快捷键层。
  void exitProofEditing() {
    FocusManager.instance.primaryFocus?.unfocus();
    setProofEditing(false);
    requestProofFocus?.call();
  }

  Future<void> setLineSpeaker(int idx, String? spk) async {
    if (idx < 0 || idx >= proofLines.length) return;
    final l = proofLines[idx];
    await api.pushProofSnapshot();
    proofLines[idx] = TranscriptLine(
      startSec: l.startSec,
      endSec: l.endSec,
      speaker: spk,
      text: l.text,
    );
    await api.updateLineSpeaker(idx, spk);
    _notify();
  }
  bool loopEnabled = false;
  double? loopStart;
  double? loopEnd;

  Player? get player => _player;

  int get activeLineIdx => activeLineIndex(proofLines, positionSec);

  /// 转写完成后进入校对模式：载入时间轴行 + 波形 + 打开播放器。
  Future<void> enterProofMode() async {
    if (audioFilePath == null) return;
    proofLines = await api.transcriptLines();
    if (proofLines.isEmpty) return;
    // 波形解码 = 整段音频再解码一次（长录音数十秒），给出状态避免无响应感
    setProgress('正在准备校准视图…');
    wavePeaks = await api.waveformPeaks(audioFilePath!, 20);
    _player ??= () {
      final p = Player(configuration: const PlayerConfiguration());
      _posSub = p.stream.position.listen((d) {
        positionSec = d.inMilliseconds / 1000.0;
        // 区段循环：越出终点即回跳起点（media_kit seek 异步，容忍小误差）
        final ls = loopStart, le = loopEnd;
        if (loopEnabled && ls != null && le != null && le > ls) {
          if (positionSec >= le) {
            p.seek(Duration(milliseconds: (ls * 1000).round()));
          } else if (positionSec < ls - 0.5) {
            p.seek(Duration(milliseconds: (ls * 1000).round()));
          }
        }
        _notify();
      });
      _playingSub = p.stream.playing.listen((v) {
        isPlaying = v;
        _notify();
      });
      _durSub = p.stream.duration.listen((d) {
        durationSec = d.inMilliseconds / 1000.0;
        _notify();
      });
      return p;
    }();
    await _player!.open(Media(audioFilePath!));
    await _player!.setRate(playbackRate);
    setProgress('');
    _notify();
  }

  /// 手动校准：进入（载入行/波形/播放器 + 原文快照）或退出
  ///（暂停收起 + diff 校准成果回填主文本）。
  Future<void> toggleProofMode() async {
    if (proofActive) {
      await _player?.pause();
      loopEnabled = false;
      loopStart = null;
      loopEnd = null;
      proofActive = false;
      // 校准成果：diff + 回填主文本（保存「校准后文本」可用）
      proofDiff = diffLines(
        originalProofLines.map(lineText).toList(),
        proofLines.map(lineText).toList(),
      );
      proofedText =
          proofLines.map(lineText).toList().join('\n');
      transcription = proofedText;
      _notify();
      return;
    }
    await enterProofMode();
    proofActive = proofLines.isNotEmpty;
    originalProofLines = proofLines
        .map((l) => TranscriptLine(
              startSec: l.startSec,
              endSec: l.endSec,
              speaker: l.speaker,
              text: l.text,
            ))
        .toList();
    _notify();
  }

  /// 原始转写文本（未校准；保存双选项用）。
  String get originalTranscription =>
      originalProofLines.map(lineText).toList().join('\n');

  void toggleLoop() {
    loopEnabled = !loopEnabled;
    if (!loopEnabled) {
      loopStart = null;
      loopEnd = null;
    }
    _notify();
  }

  /// 波形拖选区段（循环开启时由拖拽调用）。
  void setLoopRegion(double start, double end) {
    if (end < start) {
      final t = start;
      start = end;
      end = t;
    }
    loopStart = start;
    loopEnd = end;
    _notify();
  }

  /// 校对行编辑（防抖回写 Rust，SRT/LRC 导出同步更新）。
  /// 每个编辑会话（该行防抖静默期内的连续输入）在开始前压一次撤销快照。
  final Map<int, Timer> _lineEditTimers = {};
  void editLineText(int idx, String text) {
    if (idx < 0 || idx >= proofLines.length) return;
    proofLines[idx] = TranscriptLine(
      startSec: proofLines[idx].startSec,
      endSec: proofLines[idx].endSec,
      speaker: proofLines[idx].speaker,
      text: text,
    );
    final newSession = _lineEditTimers[idx] == null;
    _lineEditTimers[idx]?.cancel();
    _lineEditTimers[idx] = Timer(const Duration(milliseconds: 600), () {
      _lineEditTimers.remove(idx);
      api.updateTranscriptLine(idx, text).catchError((_) {});
    });
    if (newSession) {
      api.pushProofSnapshot().catchError((_) {});
    }
    // 不 _notify()：TextField 自身已显示文本，逐键全局重建会打断输入焦点
    //（模型数据仍同步，供退出校准 diff 与导出使用）。
  }

  /// 撤销纪元：每次 undo 恢复自增——视图据此强制重建行控制器
  ///（行数可能不变但内容变了，仅靠行数比较检测不到）。
  int proofEpoch = 0;

  /// 撤销上一次校准操作（Cmd/Ctrl+Z）：恢复 Rust 快照并整体重载。
  /// 挂起的防抖回写全部取消——否则会把撤销前的文本写回去。
  Future<void> undoProofEdit() async {
    for (final t in _lineEditTimers.values) {
      t.cancel();
    }
    _lineEditTimers.clear();
    final ok = await api.undoProofEdit();
    if (!ok) return;
    proofLines = await api.transcriptLines();
    proofEpoch++;
    _notify();
  }

  /// 拆行后视图应聚焦的新行（idx+1 的 TextField 光标置开头）；视图消费后清空。
  int? focusSplitLineAt;

  /// 供 UI 直接设置过程状态（如「正在重新对齐时间轴…」）。
  void setProgress(String text) {
    progressText = text;
    _notify();
  }

  /// 逐行重新对齐（锚点重建 + 行起止精修），返回成功行数。校准中刷新行。
  Future<int> realignLines() async {
    setProgress('正在重新对齐时间轴…');
    final int n;
    try {
      n = await api.realignProjectLines();
    } finally {
      setProgress('');
    }
    if (proofActive) {
      proofLines = await api.transcriptLines();
      _notify();
    }
    return n;
  }

  /// 加载项目后的落位：设音频路径 → 载行/波形/播放器（enterProofMode）→
  /// 恢复说话人名与原文快照 → 进入校准态。返回是否有行载入。
  Future<bool> applyLoadedProject(String audioPath) async {
    setProgress('正在载入项目…');
    audioFilePath = audioPath;
    errorMessage = null;
    // 模型未下载时主区是下载引导面板——加载项目不需要模型（播放器+行），
    // 切到 idle 让校准视图可见
    if (loadState == LoadState.notDownloaded) {
      loadState = LoadState.idle;
    }
    speakerNames.addAll(await api.speakerNamesMap());
    originalProofLines = await api.originalTranscriptLines();
    await enterProofMode();
    proofActive = proofLines.isNotEmpty;
    proofDiff = null;
    proofedText = '';
    transcription = proofActive ? proofLines.map(lineText).join('\n') : '';
    _notify();
    return proofActive;
  }

  /// 拆行（编辑模式回车）：第 idx 行在 charPos（Unicode 字符数）处拆为
  /// 两行——分界时刻吸附锚点，**两行保持原说话人**（断词语义；换人由
  /// 说话人菜单点选）。行结构变化走 Rust 权威路径（LAST_LINES/导出同步
  /// 重建）后整体重载。
  Future<void> splitLine(int idx, int charPos) async {
    if (idx < 0 || idx >= proofLines.length) return;
    final keep = proofLines[idx].speaker;
    try {
      await api.pushProofSnapshot();
      await api.splitTranscriptLine(idx, charPos, keep);
    } catch (_) {
      return; // 端点等无效位置：保持不动
    }
    proofLines = await api.transcriptLines();
    focusSplitLineAt = idx + 1;
    _notify();
  }

  Future<void> togglePlay() async {
    final p = _player;
    if (p == null) return;
    if (isPlaying) {
      await p.pause();
    } else {
      await p.play();
    }
  }

  Future<void> seekTo(double sec) async {
    final p = _player;
    if (p == null) return;
    await p.seek(Duration(milliseconds: (sec * 1000).round()));
  }

  Future<void> setPlaybackRate(double rate) async {
    playbackRate = rate;
    await _player?.setRate(rate);
    _notify();
  }

  @override
  void dispose() {
    for (final t in _lineEditTimers.values) {
      t.cancel();
    }
    _posSub?.cancel();
    _playingSub?.cancel();
    _durSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// 供 UI 层（如拖放校验失败）直接报错。
  void showError(String message) {
    errorMessage = message;
    _notify();
  }

  Future<void> updateSettings(Settings s) async {
    settings = s;
    try {
      await api.saveSettings(s);
    } catch (_) {
      /* 桩实现忽略 */
    }
    _notify();
  }
}
