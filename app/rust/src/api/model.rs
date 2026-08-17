//! 模型目录与就绪检查（离线判断，不走网络）。

/// 模型快照缓存目录（跨平台，见 asr_core::model::models_root）。
pub fn model_dir_path() -> String {
    asr_core::model::model_dir().display().to_string()
}

/// 目录是否已有完整可加载的快照：config.json + tokenizer.json + 非空
/// model.safetensors。镜像 Swift 版 ModelDownloader.isCached 的判定。
pub fn model_is_on_disk() -> bool {
    let dir = asr_core::model::model_dir();
    let non_empty = |name: &str| {
        matches!(std::fs::metadata(dir.join(name)), Ok(m) if m.len() > 0)
    };
    non_empty("config.json") && non_empty("tokenizer.json") && non_empty("model.safetensors")
}

/// 设置页展示用的模型条目（路径 + 在盘状态）。
pub struct ModelPathDto {
    pub label: String,
    pub path: String,
    pub present: bool,
    /// 可选组件（未安装不算异常，仅提示）
    pub optional: bool,
}

/// 全部使用中的模型路径（ASR 主体 + Q8 + 说话人分离两件 + 词级对齐）。
pub fn model_paths() -> Vec<ModelPathDto> {
    use asr_core::model as m;
    let dir = m::model_dir();
    let non_empty = |p: &std::path::Path| {
        matches!(std::fs::metadata(p), Ok(meta) if meta.len() > 0)
    };
    let entry = |label: &str, path: std::path::PathBuf, optional: bool| ModelPathDto {
        label: label.to_string(),
        path: path.display().to_string(),
        present: non_empty(&path),
        optional,
    };
    vec![
        entry("ASR 模型（Qwen3-ASR-1.7B）", dir.clone(), false),
        entry(
            "Q8 量化（更快更省显存，可选）",
            dir.join("model.q8_0.gguf"),
            true,
        ),
        entry("说话人分离·分段（sortformer）", m::diar_model_path(), false),
        entry(
            "说话人分离·声纹（CAM++）",
            m::sherpa_diar_dir().join(m::SHERPA_EMBEDDING_FILE),
            false,
        ),
        entry(
            "词级对齐（时间轴精确到字，可选）",
            m::aligner_model_path(),
            true,
        ),
    ]
}
