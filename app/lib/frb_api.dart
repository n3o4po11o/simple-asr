// FrbApi：NativeApi 的 flutter_rust_bridge 实现（Rust 侧 = app/rust asr_bridge，
// 下游接 asr-core）。下载/设置/模型检查为真实实现；引擎调用在 M1 前由 Rust 侧
// 返回明确错误。

import 'dart:async';

import 'native_api.dart';
import 'src/rust/api/devices.dart' as rust_devices;
import 'src/rust/api/download.dart' as rust_dl;
import 'src/rust/api/engine.dart' as rust_engine;
import 'src/rust/api/model.dart' as rust_model;
import 'src/rust/api/settings.dart' as rust_settings;

String _sourceStr(ModelSource s) =>
    s == ModelSource.huggingFace ? 'huggingFace' : 'modelScope';

class FrbApi implements NativeApi {
  @override
  Future<bool> modelIsOnDisk() => rust_model.modelIsOnDisk();

  @override
  Future<String> modelDirPath() => rust_model.modelDirPath();

  @override
  Future<List<ModelPathEntry>> modelPaths() async {
    final dtos = await rust_model.modelPaths();
    return dtos
        .map((d) => ModelPathEntry(
              label: d.label,
              path: d.path,
              present: d.present,
              optional: d.optional,
            ))
        .toList();
  }

  @override
  Future<void> downloadModel(
    Settings s,
    void Function(DownloadProgress) onProgress,
  ) {
    final completer = Completer<void>();
    var settled = false;

    final sub = rust_dl.downloadModel(source: _sourceStr(s.source)).listen(
      (e) {
        final p = e.progress;
        if (p != null) {
          onProgress(DownloadProgress(
            completedFiles: p.completedFiles,
            totalFiles: p.totalFiles,
            completedBytes: p.completedBytes.toInt(),
            totalBytes: p.totalBytes.toInt(),
            currentFile: p.currentFile,
          ));
        } else if (e.error != null && !settled) {
          settled = true;
          completer.completeError(StateError(e.error!));
        }
        // cancelled / 正常结束终态：无需处理，onDone 收尾。
      },
      onError: (Object err) {
        if (!settled) {
          settled = true;
          completer.completeError(err);
        }
      },
      onDone: () {
        if (!settled) {
          settled = true;
          completer.complete();
        }
      },
      cancelOnError: false,
    );
    // 兜底：外部取消订阅时不要悬挂 future。
    return completer.future.whenComplete(sub.cancel);
  }

  @override
  void cancelDownload() => rust_dl.cancelDownload();

  @override
  Future<void> loadModel(Settings s) => rust_engine.loadModel(
        backend: s.backend,
        deviceOrdinal: s.deviceOrdinal,
      );

  @override
  void cancelLoad() => rust_engine.cancelLoad();

  @override
  Future<bool> q8ModelAvailable() => rust_engine.q8ModelAvailable();

  @override
  Future<void> convertModelToQ8() => rust_engine.convertModelToQ8();

  @override
  Future<bool> diarModelAvailable() => rust_engine.diarModelAvailable();

  @override
  Stream<InstallProgress> installDiarModel() => rust_engine
      .installDiarModel()
      .map((e) => InstallProgress(
            completedBytes: e.completedBytes.toInt(),
            totalBytes: e.totalBytes.toInt(),
            error: e.error,
          ));

  @override
  Future<bool> alignerModelAvailable() => rust_engine.alignerModelAvailable();

  @override
  Stream<InstallProgress> installAlignerModel() => rust_engine
      .installAlignerModel()
      .map((e) => InstallProgress(
            completedBytes: e.completedBytes.toInt(),
            totalBytes: e.totalBytes.toInt(),
            error: e.error,
          ));

  @override
  Future<String> lastSrt() => rust_engine.lastSrt();

  @override
  Future<String> lastLrc() => rust_engine.lastLrc();

  @override
  Future<List<TranscriptLine>> transcriptLines() async {
    final dtos = await rust_engine.transcriptLines();
    return dtos
        .map((d) => TranscriptLine(
              startSec: d.startSec,
              endSec: d.endSec,
              speaker: d.speaker == '' ? null : d.speaker,
              text: d.text,
            ))
        .toList();
  }

  @override
  Future<void> updateTranscriptLine(int index, String text) =>
      rust_engine.updateTranscriptLine(index: index, text: text);

  @override
  Future<void> splitTranscriptLine(int index, int charPos, String? nextSpeaker) =>
      rust_engine.splitTranscriptLine(
          index: index, charPos: charPos, secondSpeaker: nextSpeaker);

  @override
  Future<void> pushProofSnapshot() => rust_engine.pushProofSnapshot();

  @override
  Future<bool> undoProofEdit() => rust_engine.undoProofEdit();

  @override
  Future<void> updateLineSpeaker(int index, String? speaker) =>
      rust_engine.updateLineSpeaker(index: index, speaker: speaker);

  @override
  Future<void> setSpeakerName(String speaker, String name) =>
      rust_engine.setSpeakerName(speaker: speaker, name: name);

  @override
  Future<List<double>> waveformPeaks(String path, int bucketsPerSec) async {
    final v = await rust_engine.waveformPeaks(path: path, bucketsPerSec: bucketsPerSec);
    return v.map((e) => e.toDouble()).toList();
  }

  @override
  Future<void> saveProject(String path) => rust_engine.saveProject(path: path);

  @override
  Future<LoadedProject> loadProject(String path) async {
    final d = await rust_engine.loadProject(path: path);
    return LoadedProject(
      audioPath: d.audioPath,
      audioExists: d.audioExists,
      lineCount: d.lineCount,
    );
  }

  @override
  Future<void> updateProjectAudio(String path) =>
      rust_engine.updateProjectAudio(path: path);

  @override
  Future<int> realignProjectLines() => rust_engine.realignProjectLines();

  @override
  Future<Map<String, String>> speakerNamesMap() =>
      rust_engine.speakerNamesMap();

  @override
  Future<List<TranscriptLine>> originalTranscriptLines() async {
    final dtos = await rust_engine.originalTranscriptLines();
    return dtos
        .map((d) => TranscriptLine(
              startSec: d.startSec,
              endSec: d.endSec,
              speaker: d.speaker == '' ? null : d.speaker,
              text: d.text,
            ))
        .toList();
  }

  @override
  Future<String> polishText(String text) => rust_engine.polishText(text: text);

  @override
  Future<void> unloadModel() => rust_engine.unloadModel();

  TranscribeStats? _lastStats;

  @override
  Future<void> transcribeFile(
    String path,
    Settings s,
    void Function(String text) onText, [
    void Function(String status)? onStatus,
  ]) {
    final completer = Completer<void>();
    var settled = false;

    final sub = rust_engine
        .transcribeFile(
      path: path,
      language: s.language,
    )
        .listen(
      (e) {
        if (e.status != null) {
          onStatus?.call(e.status!);
        } else if (e.text != null && e.text!.isNotEmpty) {
          onText(e.text!);
        } else if (e.error != null && !settled) {
          settled = true;
          completer.completeError(StateError(e.error!));
        } else if (e.done) {
          _lastStats = TranscribeStats(
            tokensPerSecond: 0, // 引擎未上报 token 数
            peakMemoryGB: 0,
            language: e.language,
          );
        }
      },
      onError: (Object err) {
        if (!settled) {
          settled = true;
          completer.completeError(err);
        }
      },
      onDone: () {
        if (!settled) {
          settled = true;
          completer.complete();
        }
      },
      cancelOnError: false,
    );
    return completer.future.whenComplete(sub.cancel);
  }

  @override
  void stopTranscribe() => rust_engine.stopTranscribe();

  @override
  Future<TranscribeStats?> lastStats() async => _lastStats;

  @override
  Future<Settings> loadSettings() async {
    final dto = await rust_settings.loadSettings();
    return Settings(
      source: dto.source == 'huggingFace'
          ? ModelSource.huggingFace
          : ModelSource.modelScope,
      language: dto.language,
      backend: dto.backend,
      deviceOrdinal: dto.deviceOrdinal,
      acppQ8: dto.acppQ8,
      diarization: dto.diarization,
      diarSpeakers: dto.diarSpeakers,
      llmPolish: dto.llmPolish,
      llmUrl: dto.llmUrl,
      llmKey: dto.llmKey,
      llmModel: dto.llmModel,
      mirrorBase: dto.mirrorBase,
      proxy: dto.proxy,
    );
  }

  @override
  Future<void> saveSettings(Settings s) => rust_settings.saveSettings(
        dto: rust_settings.SettingsDto(
          source: _sourceStr(s.source),
          language: s.language,
          backend: s.backend,
          deviceOrdinal: s.deviceOrdinal,
          acppQ8: s.acppQ8,
          diarization: s.diarization,
          diarSpeakers: s.diarSpeakers,
          llmPolish: s.llmPolish,
          llmUrl: s.llmUrl,
          llmKey: s.llmKey,
          llmModel: s.llmModel,
          mirrorBase: s.mirrorBase,
          proxy: s.proxy,
        ),
      );

  @override
  Future<SystemInfo> systemInfo() async {
    final dto = await rust_devices.systemInfo();
    return SystemInfo(
      totalMemoryBytes: dto.totalMemoryBytes.toInt(),
      cpuCount: dto.cpuCount,
      cpuBrand: dto.cpuBrand,
      backends: [
        for (final b in dto.backends)
          ComputeBackend(
            id: b.id,
            label: b.label,
            available: b.available,
            note: b.note,
            devices: [
              for (final d in b.devices)
                GpuDevice(
                  ordinal: d.ordinal,
                  name: d.name,
                  memoryBytes: d.memoryBytes.toInt(),
                ),
            ],
          ),
      ],
    );
  }
}
