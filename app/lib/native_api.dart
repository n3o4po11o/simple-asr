// NativeApi 抽象：UI 与 Rust 后端（asr-core + audiocpp 引擎）的唯一边界。
// 实现类 FrbApi 由 flutter_rust_bridge 生成绑定；接口形状与
// rust/crates/asr-core 的 download/model/settings 模块一一对应。

/// 模型下载源。默认 ModelScope（中国境内快），HF 备选。
enum ModelSource { modelScope, huggingFace }

class DownloadProgress {
  const DownloadProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.completedBytes,
    required this.totalBytes,
    required this.currentFile,
  });

  final int completedFiles;
  final int totalFiles;
  final int completedBytes;
  final int totalBytes;
  final String currentFile;

  double get fraction => totalBytes == 0 ? 0 : completedBytes / totalBytes;
}

/// 一次转写的统计（对齐 Swift 版 tokens/s、峰值显存、识别语言）。
class TranscribeStats {
  const TranscribeStats({
    required this.tokensPerSecond,
    required this.peakMemoryGB,
    required this.language,
  });

  final double tokensPerSecond;
  final double peakMemoryGB;
  final String language;
}

/// 校对视图的带时间轴文本行（Rust TranscriptLineDto 对应）。
class TranscriptLine {
  const TranscriptLine({
    required this.startSec,
    required this.endSec,
    required this.speaker,
    required this.text,
  });

  final double startSec;
  final double endSec;
  final String? speaker;
  final String text;
}

/// 设置页展示的模型条目（路径 + 在盘状态）。
class ModelPathEntry {
  const ModelPathEntry({
    required this.label,
    required this.path,
    required this.present,
    required this.optional,
  });

  final String label;
  final String path;
  final bool present;
  final bool optional;
}

/// 模型安装进度（字节级；error 非空 = 失败终态）。
class InstallProgress {
  const InstallProgress({
    required this.completedBytes,
    required this.totalBytes,
    this.error,
  });

  final int completedBytes;
  final int totalBytes;
  final String? error;

  double get fraction => totalBytes == 0 ? 0 : completedBytes / totalBytes;
}

/// 加载项目的结果（音频存在性由 UI 处理提示与重选）。
class LoadedProject {
  const LoadedProject({
    required this.audioPath,
    required this.audioExists,
    required this.lineCount,
  });

  final String audioPath;
  final bool audioExists;
  final int lineCount;
}

/// 按播放位置找当前行（末行持续到结尾；开头前返回 -1）。
int activeLineIndex(List<TranscriptLine> lines, double posSec) {
  var idx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startSec <= posSec) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}

String fmtClock(double sec) {
  final s = sec.round();
  final m = s ~/ 60;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 与 asr-core settings.rs 对应的用户设置。
class Settings {
  const Settings({
    this.source = ModelSource.modelScope,
    this.language = 'auto',
    this.backend = 'auto',
    this.deviceOrdinal = 0,
    this.acppQ8 = false,
    this.diarization = false,
    this.diarSpeakers = 2,
    this.llmPolish = false,
    this.llmUrl = '',
    this.llmKey = '',
    this.llmModel = '',
    this.mirrorBase = '',
    this.proxy = '',
  });

  final ModelSource source;
  final String language; // 'auto' = 自动检测
  final String backend; // 'auto' | 'cpu' | 'metal' | 'vulkan'
  final int deviceOrdinal;
  final bool acppQ8; // audiocpp 引擎用 Q8 量化模型
  final bool diarization; // 说话人分离（带 [说话人] 前缀）
  final int diarSpeakers; // 已知说话人数（0 = 自动聚类）
  final bool llmPolish; // 外接 LLM 润色
  final String llmUrl; // OpenAI 兼容端点（如 https://api.deepseek.com/v1）
  final String llmKey;
  final String llmModel;
  final String mirrorBase; // HF 类下载镜像基址（空 = 按下载源默认）
  final String proxy; // http/https/socks5/socks5h（空 = 不使用）

  Settings copyWith({
    ModelSource? source,
    String? language,
    String? backend,
    int? deviceOrdinal,
    bool? acppQ8,
    bool? diarization,
    int? diarSpeakers,
    bool? llmPolish,
    String? llmUrl,
    String? llmKey,
    String? llmModel,
    String? mirrorBase,
    String? proxy,
  }) => Settings(
    source: source ?? this.source,
    language: language ?? this.language,
    backend: backend ?? this.backend,
    deviceOrdinal: deviceOrdinal ?? this.deviceOrdinal,
    acppQ8: acppQ8 ?? this.acppQ8,
    diarization: diarization ?? this.diarization,
    diarSpeakers: diarSpeakers ?? this.diarSpeakers,
    llmPolish: llmPolish ?? this.llmPolish,
    llmUrl: llmUrl ?? this.llmUrl,
    llmKey: llmKey ?? this.llmKey,
    llmModel: llmModel ?? this.llmModel,
    mirrorBase: mirrorBase ?? this.mirrorBase,
    proxy: proxy ?? this.proxy,
  );
}

/// GPU 设备（对齐 Rust GpuDeviceDto）。
class GpuDevice {
  const GpuDevice({
    required this.ordinal,
    required this.name,
    required this.memoryBytes,
  });

  final int ordinal;
  final String name;
  final int memoryBytes;
}

/// 计算后端（对齐 Rust BackendDto）。
class ComputeBackend {
  const ComputeBackend({
    required this.id,
    required this.label,
    required this.available,
    required this.note,
    required this.devices,
  });

  final String id;
  final String label;
  final bool available;
  final String note;
  final List<GpuDevice> devices;
}

/// 系统信息（对齐 Rust SystemInfoDto）。
class SystemInfo {
  const SystemInfo({
    required this.totalMemoryBytes,
    required this.cpuCount,
    required this.cpuBrand,
    required this.backends,
  });

  final int totalMemoryBytes;
  final int cpuCount;
  final String cpuBrand;
  final List<ComputeBackend> backends;
}

/// 运行时模型与下载源常量（对齐 asr_core::model）。
const kModelRepoId = 'Qwen/Qwen3-ASR-1.7B-hf';
const kModelScopeUrl =
    'https://www.modelscope.cn/models/Qwen/Qwen3-ASR-1.7B-hf';
const kHuggingFaceUrl = 'https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf';
const kModelscopeInstallCommand = 'pip install modelscope';

String modelscopeDownloadCommand(String dir) =>
    'modelscope download --model $kModelRepoId --local_dir "$dir"';

/// 拖放/导入接受的音频扩展名（对齐 Swift 版 AudioDropDelegate）。
const kAudioExtensions = {
  'm4a',
  'mp3',
  'wav',
  'aac',
  'aiff',
  'aif',
  'flac',
  'caf',
  'ogg',
  'wma',
};

bool isAudioPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return kAudioExtensions.contains(path.substring(dot + 1).toLowerCase());
}

abstract class NativeApi {
  /// 模型快照是否已完整落在本地缓存目录。
  Future<bool> modelIsOnDisk();

  /// 模型缓存目录（用于展示与 modelscope CLI 命令拼接）。
  Future<String> modelDirPath();

  /// 全部使用中的模型路径与在盘状态（设置页展示）。
  Future<List<ModelPathEntry>> modelPaths();

  /// 内置下载（asr-core download::download_model）。onProgress 同步回调，
  /// 返回 false 可取消（由 [cancelDownload] 触发）。
  Future<void> downloadModel(
    Settings s,
    void Function(DownloadProgress) onProgress,
  );

  void cancelDownload();

  /// 从磁盘加载模型进显存。
  Future<void> loadModel(Settings s);

  void cancelLoad();

  Future<void> unloadModel();

  /// Q8 模型是否已生成（设置页状态展示）。
  Future<bool> q8ModelAvailable();

  /// 一键转换 Q8（-hf → audio.cpp GGUF，约 10 秒）。
  Future<void> convertModelToQ8();

  /// 说话人分离模型是否已就绪。
  Future<bool> diarModelAvailable();

  /// 安装说话人分离模型（约 200 MB），字节级进度流。
  Stream<InstallProgress> installDiarModel();

  /// 词级对齐模型是否已安装（可选增强，约 1.1 GB）。
  Future<bool> alignerModelAvailable();

  /// 安装词级对齐模型（约 1.1 GB），字节级进度流。
  Stream<InstallProgress> installAlignerModel();

  /// 最近一次转写的 SRT 字幕（无则空串）。
  Future<String> lastSrt();

  /// 最近一次转写的 LRC 歌词（无则空串）。
  Future<String> lastLrc();

  /// 校对视图：带时间轴的文本行。
  Future<List<TranscriptLine>> transcriptLines();

  /// 校对视图：波形峰值（0..1）。
  Future<List<double>> waveformPeaks(String path, int bucketsPerSec);

  /// 校对行编辑（更新后 SRT/LRC 导出反映校对结果）。
  Future<void> updateTranscriptLine(int index, String text);

  /// 拆行（编辑模式回车）：第 index 行在 charPos（Unicode 字符数）处拆为
  /// 两行，分界时刻吸附锚点，两行保持 nextSpeaker 传入的说话人。
  Future<void> splitTranscriptLine(int index, int charPos, String? nextSpeaker);

  /// 压入当前校准行快照（修改性操作前的撤销点）。
  Future<void> pushProofSnapshot();

  /// 撤销上一次校准操作（跨行/拆行/说话人）；栈空返回 false。
  Future<bool> undoProofEdit();

  /// 行级改说话人（diar 精度人工修正；null = 无说话人）。
  Future<void> updateLineSpeaker(int index, String? speaker);

  /// 说话人重命名（全局生效，导出同步）。
  Future<void> setSpeakerName(String speaker, String name);

  /// 保存项目（.asrproj：行/逐字锚点/原行快照/说话人名/音频路径）。
  Future<void> saveProject(String path);

  /// 加载项目：恢复校准工作，返回音频路径与存在性。
  Future<LoadedProject> loadProject(String path);

  /// 项目加载后音频移动/重选时改指（保存项目记录新路径）。
  Future<void> updateProjectAudio(String path);

  /// 逐行重新对齐当前项目（锚点重建、行起止精修）；返回成功行数。
  Future<int> realignProjectLines();

  /// 说话人显示名（项目加载后 UI 同步）。
  Future<Map<String, String>> speakerNamesMap();

  /// 转写完成时的原始行快照（退出校准 diff 基准）。
  Future<List<TranscriptLine>> originalTranscriptLines();

  /// 外接 LLM 润色。
  Future<String> polishText(String text);

  /// 转写：onText 收到「累计全文」（流式每步更新，替换式上屏）；
  /// onStatus 收到过程状态（如「正在精修时间轴… 3/87」）。
  Future<void> transcribeFile(
    String path,
    Settings s,
    void Function(String text) onText, [
    void Function(String status)? onStatus,
  ]);

  void stopTranscribe();

  Future<TranscribeStats?> lastStats();

  Future<Settings> loadSettings();

  Future<void> saveSettings(Settings s);

  /// 设备与后端枚举（系统内存/CPU + 各后端 GPU 设备列表）。
  Future<SystemInfo> systemInfo();
}

/// M2 之前的桩实现：状态查询可用（让 UI 状态机可开发/可测试），
/// 涉及引擎与网络的动作用 UnimplementedError 明确报错。
class StubApi implements NativeApi {
  @override
  Future<bool> modelIsOnDisk() async => false;

  @override
  Future<String> modelDirPath() async => '';

  @override
  Future<List<ModelPathEntry>> modelPaths() async => const [];

  @override
  Future<void> downloadModel(
    Settings s,
    void Function(DownloadProgress) onProgress,
  ) async {
    throw UnimplementedError('M2：flutter_rust_bridge 接入后可用');
  }

  @override
  void cancelDownload() {}

  @override
  Future<void> loadModel(Settings s) async {
    throw UnimplementedError('M2：flutter_rust_bridge 接入后可用');
  }

  @override
  void cancelLoad() {}

  @override
  Future<void> unloadModel() async {}

  @override
  Future<bool> q8ModelAvailable() async => false;

  @override
  Future<void> convertModelToQ8() async {}

  @override
  Future<bool> diarModelAvailable() async => false;

  @override
  Stream<InstallProgress> installDiarModel() => const Stream.empty();

  @override
  Future<bool> alignerModelAvailable() async => false;

  @override
  Stream<InstallProgress> installAlignerModel() => const Stream.empty();

  @override
  Future<String> lastSrt() async => '';

  @override
  Future<String> lastLrc() async => '';

  @override
  Future<List<TranscriptLine>> transcriptLines() async => [];

  @override
  Future<List<double>> waveformPeaks(String path, int bucketsPerSec) async => [];

  @override
  Future<void> updateTranscriptLine(int index, String text) async {}

  @override
  Future<void> splitTranscriptLine(int index, int charPos, String? nextSpeaker) async {}

  @override
  Future<void> pushProofSnapshot() async {}

  @override
  Future<bool> undoProofEdit() async => false;

  @override
  Future<void> updateLineSpeaker(int index, String? speaker) async {}

  @override
  Future<void> setSpeakerName(String speaker, String name) async {}

  @override
  Future<void> saveProject(String path) async {}

  @override
  Future<LoadedProject> loadProject(String path) async =>
      const LoadedProject(audioPath: '', audioExists: false, lineCount: 0);

  @override
  Future<void> updateProjectAudio(String path) async {}

  @override
  Future<int> realignProjectLines() async => 0;

  @override
  Future<Map<String, String>> speakerNamesMap() async => {};

  @override
  Future<List<TranscriptLine>> originalTranscriptLines() async => [];

  @override
  Future<String> polishText(String text) async => text;

  @override
  Future<void> transcribeFile(
    String path,
    Settings s,
    void Function(String text) onText, [
    void Function(String status)? onStatus,
  ]) async {
    throw UnimplementedError('M2：flutter_rust_bridge 接入后可用');
  }

  @override
  void stopTranscribe() {}

  @override
  Future<TranscribeStats?> lastStats() async => null;

  @override
  Future<Settings> loadSettings() async => const Settings();

  @override
  Future<void> saveSettings(Settings s) async {}

  @override
  Future<SystemInfo> systemInfo() async => SystemInfo(
        totalMemoryBytes: 16 * 1024 * 1024 * 1024,
        cpuCount: 8,
        cpuBrand: 'CPU',
        backends: const [
          ComputeBackend(
            id: 'cpu',
            label: 'CPU',
            available: true,
            note: '',
            devices: [],
          ),
        ],
      );
}
