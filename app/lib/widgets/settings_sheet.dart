// 设置弹窗（对齐 Swift SettingsSheet）：下载源、识别语言、计算后端、
// 模型目录。语言表与 asr-core languages.rs 一一对应。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../native_api.dart';

String _fmtBytes(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return '${gb.toStringAsFixed(gb >= 16 ? 0 : 1)} GB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

const _languages = <(String, String)>[
  ('auto', '自动检测 (Auto)'),
  ('Chinese', '中文 (Chinese)'),
  ('Cantonese', '粤语 (Cantonese)'),
  ('English', 'English'),
  ('Japanese', '日本語 (Japanese)'),
  ('Korean', '한국어 (Korean)'),
  ('French', 'Français (French)'),
  ('German', 'Deutsch (German)'),
  ('Spanish', 'Español (Spanish)'),
  ('Portuguese', 'Português'),
  ('Italian', 'Italiano'),
  ('Russian', 'Русский (Russian)'),
  ('Arabic', 'العربية (Arabic)'),
  ('Thai', 'ภาษาไทย (Thai)'),
  ('Vietnamese', 'Tiếng Việt (Vietnamese)'),
  ('Indonesian', 'Bahasa Indonesia'),
];

Future<void> showSettingsSheet(BuildContext context, AppModel model) {
  return showDialog(
    context: context,
    builder: (_) => _SettingsDialog(model: model),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.model});

  final AppModel model;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late ModelSource _source = widget.model.settings.source;
  late String _language = widget.model.settings.language;
  late String _backend = widget.model.settings.backend;
  late int _deviceOrdinal = widget.model.settings.deviceOrdinal;
  late bool _acppQ8 = widget.model.settings.acppQ8;
  bool _q8Ready = false;
  bool _converting = false;
  late bool _diarization = widget.model.settings.diarization;
  late int _diarSpeakers = widget.model.settings.diarSpeakers;
  bool _diarReady = false;
  bool _installingDiar = false;
  String? _diarInstallText;
  bool _alignerReady = false;
  bool _installingAligner = false;
  String? _alignerInstallText;
  late bool _llmPolish = widget.model.settings.llmPolish;
  late String _llmUrl = widget.model.settings.llmUrl;
  late String _llmKey = widget.model.settings.llmKey;
  late String _llmModel = widget.model.settings.llmModel;
  late String _mirrorBase = widget.model.settings.mirrorBase;
  late String _proxy = widget.model.settings.proxy;
  SystemInfo? _sys;
  List<ModelPathEntry> _modelPaths = const [];

  @override
  void initState() {
    super.initState();
    widget.model.api.systemInfo().then((info) {
      if (mounted) setState(() => _sys = info);
    });
    widget.model.api.q8ModelAvailable().then((ok) {
      if (mounted) setState(() => _q8Ready = ok);
    });
    widget.model.api.diarModelAvailable().then((ok) {
      if (mounted) setState(() => _diarReady = ok);
    });
    widget.model.api.alignerModelAvailable().then((ok) {
      if (mounted) setState(() => _alignerReady = ok);
    });
    widget.model.api.modelPaths().then((list) {
      if (mounted) setState(() => _modelPaths = list);
    });
  }

  Future<void> _installAligner() => _runInstall(
        installing: (v) => _installingAligner = v,
        text: (t) => _alignerInstallText = t,
        stream: widget.model.api.installAlignerModel,
        onDone: () async {
          _alignerReady = await widget.model.api.alignerModelAvailable();
          return _alignerReady;
        },
        failLabel: '对齐模型安装失败',
      );

  Future<void> _installDiar() => _runInstall(
        installing: (v) => _installingDiar = v,
        text: (t) => _diarInstallText = t,
        stream: widget.model.api.installDiarModel,
        onDone: () async {
          final ok = await widget.model.api.diarModelAvailable();
          if (ok) {
            _diarReady = true;
            _diarization = true;
          }
          return ok;
        },
        failLabel: '分离模型安装失败',
      );

  /// 通用安装流程：字节级进度文案（如「45 MB / 200 MB」），完成刷新可用性。
  Future<void> _runInstall({
    required void Function(bool) installing,
    required void Function(String?) text,
    required Stream<InstallProgress> Function() stream,
    required Future<bool> Function() onDone,
    required String failLabel,
  }) async {
    setState(() {
      installing(true);
      text(null);
    });
    var failed = false;
    try {
      await for (final p in stream()) {
        if (p.error != null) {
          failed = true;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$failLabel：${p.error}')),
            );
          }
          break;
        }
        if (mounted) {
          setState(() => text(_fmtInstall(p)));
        }
      }
      if (!failed) {
        final ok = await onDone();
        if (mounted && ok) setState(() {});
      }
    } finally {
      if (mounted) {
        setState(() {
          installing(false);
          text(null);
        });
      }
    }
  }

  String _fmtInstall(InstallProgress p) {
    String mb(int bytes) => (bytes / 1048576).toStringAsFixed(0);
    return '${mb(p.completedBytes)} MB / ${mb(p.totalBytes)} MB';
  }

  Future<void> _convertQ8() async {
    setState(() => _converting = true);
    try {
      await widget.model.api.convertModelToQ8();
      final ok = await widget.model.api.q8ModelAvailable();
      if (mounted) {
        setState(() {
          _q8Ready = ok;
          if (ok) _acppQ8 = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Q8 转换失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  String get _cpuLabel =>
      _sys == null ? '' : '${_sys!.cpuBrand} × ${_sys!.cpuCount} 线程';

  List<GpuDevice> get _selectedDevices {
    if (_backend == 'auto' || _backend == 'cpu') return const [];
    final b = _sys?.backends.where((x) => x.id == _backend).firstOrNull;
    return b?.devices ?? const [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置', style: theme.textTheme.titleMedium),
                const SizedBox(height: 18),

                // 下载源
                const Text('下载源'),
                const SizedBox(height: 6),
                SegmentedButton<ModelSource>(
                  segments: const [
                    ButtonSegment(
                      value: ModelSource.modelScope,
                      label: Text('ModelScope（境内快）'),
                      icon: Icon(Icons.bolt, size: 16),
                    ),
                    ButtonSegment(
                      value: ModelSource.huggingFace,
                      label: Text('Hugging Face'),
                      icon: Icon(Icons.public, size: 16),
                    ),
                  ],
                  selected: {_source},
                  onSelectionChanged: (s) => setState(() => _source = s.first),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: TextEditingController(text: _mirrorBase)
                    ..selection = TextSelection.collapsed(offset: _mirrorBase.length),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '镜像加速地址（可选）',
                    hintText: 'https://hf-mirror.com（留空按下载源默认）',
                  ),
                  onChanged: (v) => _mirrorBase = v,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: TextEditingController(text: _proxy)
                    ..selection = TextSelection.collapsed(offset: _proxy.length),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '网络代理（可选）',
                    hintText: 'http://127.0.0.1:7890 或 socks5://…',
                  ),
                  onChanged: (v) => _proxy = v,
                ),
                const SizedBox(height: 6),
                Text(
                  '镜像覆盖 HuggingFace 类下载域名（主模型 HF 侧、分离/对齐模型）；'
                  '代理作用于全部模型下载与 LLM 润色，支持 http/https/socks5/socks5h。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 14),

                // 模型清单（全部使用中的模型：路径 + 在盘状态）
                const Text('模型'),
                const SizedBox(height: 6),
                for (final m in _modelPaths)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(
                          m.present ? Icons.check_circle : Icons.circle_outlined,
                          size: 14,
                          color: m.present
                              ? Colors.green.shade600
                              : (m.optional
                                  ? theme.colorScheme.outline
                                  : Colors.orange.shade800),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.optional
                                    ? '${m.label} · ${m.present ? "已安装" : "未安装"}'
                                    : m.label,
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                m.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 14),
                          tooltip: '复制路径',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: m.path)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),

                // 语言
                DropdownButtonFormField<String>(
                  initialValue: _language,
                  decoration: const InputDecoration(
                    labelText: '识别语言',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final (id, label) in _languages)
                      DropdownMenuItem(value: id, child: Text(label)),
                  ],
                  onChanged: (v) => setState(() => _language = v!),
                ),
                const SizedBox(height: 18),

                // 本机信息（LM Studio 式设备展示）
                if (_sys != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本机：内存 ${_fmtBytes(_sys!.totalMemoryBytes)} · $_cpuLabel',
                          style: theme.textTheme.bodySmall,
                        ),
                        for (final b in _sys!.backends)
                          for (final d in b.devices)
                            Text(
                              'GPU [${d.ordinal}] ${d.name} · ${_fmtBytes(d.memoryBytes)}'
                              '${b.id == 'metal' ? '（统一内存）' : ''}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // audiocpp Q8：一键转换（-hf bf16 → Q8 GGUF，约 10 秒，更快更省显存）
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用 Q8 量化模型'),
                  subtitle: Text(
                    _q8Ready ? 'model.q8_0.gguf 已就绪（~2.3 GB，更快）' : '需先转换（bf16 → Q8，约 10 秒）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  value: _acppQ8,
                  onChanged: _q8Ready ? (v) => setState(() => _acppQ8 = v) : null,
                ),
                const SizedBox(height: 10),

                // 说话人分离（sherpa：pyannote 分割 + CAM++ 声纹聚类）
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('说话人分离'),
                  subtitle: Text(
                    _diarReady
                        ? '分段+声纹聚类，输出 [说话人] 前缀'
                        : '需安装分离模型（分段+声纹，约 200 MB）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  value: _diarization,
                  onChanged: _diarReady ? (v) => setState(() => _diarization = v) : null,
                ),
                if (_diarReady)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Row(
                      children: [
                        const Text('说话人数'),
                        const SizedBox(width: 12),
                        DropdownButton<int>(
                          value: _diarSpeakers,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('自动')),
                            DropdownMenuItem(value: 2, child: Text('2 人')),
                            DropdownMenuItem(value: 3, child: Text('3 人')),
                            DropdownMenuItem(value: 4, child: Text('4 人')),
                          ],
                          onChanged: (v) => setState(() => _diarSpeakers = v!),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '已知人数时聚类更准（客服通话选 2 人）',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!_diarReady)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: OutlinedButton.icon(
                      onPressed: _installingDiar ? null : _installDiar,
                      icon: _installingDiar
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 16),
                      label: Text(_installingDiar
                          ? (_diarInstallText ?? '安装中…')
                          : '安装分离模型（200 MB）'),
                    ),
                  ),
                if (_diarReady && !_alignerReady)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: OutlinedButton.icon(
                      onPressed: _installingAligner ? null : _installAligner,
                      icon: _installingAligner
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.straighten, size: 16),
                      label: Text(
                        _installingAligner
                            ? (_alignerInstallText ?? '安装中…')
                            : '安装词级对齐模型（1.1 GB，可选）',
                      ),
                    ),
                  ),
                if (_diarReady && _alignerReady)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      '词级对齐已就绪：说话人归属精确到字',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),

                // LLM 润色（外接 OpenAI 兼容 API）
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('LLM 润色'),
                  subtitle: Text(
                    '转写后去除语气词/口癖/结巴重复（需自备 API）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  value: _llmPolish,
                  onChanged: (v) => setState(() => _llmPolish = v),
                ),
                if (_llmPolish) ...[
                  TextField(
                    controller: TextEditingController(text: _llmUrl)
                      ..selection = TextSelection.collapsed(offset: _llmUrl.length),
                    decoration: const InputDecoration(
                      labelText: 'API 地址（OpenAI 兼容）',
                      hintText: 'https://api.deepseek.com/v1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => _llmUrl = v,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: TextEditingController(text: _llmModel)
                      ..selection = TextSelection.collapsed(offset: _llmModel.length),
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: 'deepseek-chat',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => _llmModel = v,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: TextEditingController(text: _llmKey)
                      ..selection = TextSelection.collapsed(offset: _llmKey.length),
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => _llmKey = v,
                  ),
                ],
                if (!_q8Ready)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : _convertQ8,
                      icon: _converting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.compress, size: 16),
                      label: Text(_converting ? '转换中…' : '一键转换 Q8'),
                    ),
                  ),
                const SizedBox(height: 18),

                // 计算后端与设备
                DropdownButtonFormField<String>(
                  initialValue: _backend,
                  decoration: const InputDecoration(
                    labelText: '计算后端',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'auto',
                      child: Text('自动（推荐）'),
                    ),
                    for (final b in _sys?.backends ?? const <ComputeBackend>[])
                      DropdownMenuItem(
                        value: b.id,
                        enabled: b.available,
                        child: Text(
                          b.available ? b.label : '${b.label} — ${b.note}',
                          style: TextStyle(
                            fontSize: 13,
                            color: b.available
                                ? null
                                : theme.colorScheme.outline,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _backend = v!;
                    _deviceOrdinal = 0;
                  }),
                ),
                if (_selectedDevices.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: _deviceOrdinal,
                    decoration: const InputDecoration(
                      labelText: 'GPU 设备',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final d in _selectedDevices)
                        DropdownMenuItem(
                          value: d.ordinal,
                          child: Text(
                            '[${d.ordinal}] ${d.name} · ${_fmtBytes(d.memoryBytes)}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _deviceOrdinal = v!),
                  ),
                ],
                const SizedBox(height: 18),

                Text(
                  '提示：首次运行需下载约 4 GB 模型；Q8 量化版约 2.3 GB（设置页可一键转换），'
                  '更省显存且更快。音频分块与显存预算由引擎内部管理。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 18),

                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () {
                      widget.model.updateSettings(
                        Settings(
                          source: _source,
                          language: _language,
                          backend: _backend,
                          deviceOrdinal: _deviceOrdinal,
                          acppQ8: _acppQ8,
                          diarization: _diarization,
                          diarSpeakers: _diarSpeakers,
                          llmPolish: _llmPolish,
                          llmUrl: _llmUrl,
                          llmKey: _llmKey,
                          llmModel: _llmModel,
                          mirrorBase: _mirrorBase,
                          proxy: _proxy,
                        ),
                      );
                      Navigator.of(context).pop();
                    },
                    child: const Text('完成'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
