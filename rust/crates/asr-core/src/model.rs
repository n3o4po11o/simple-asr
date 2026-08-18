//! Model repo, cache layout, completeness check.
//!
//! The model is the Transformers-native Qwen3-ASR checkpoint, consumed
//! directly as safetensors (no GGUF conversion). Same repo id works on
//! both download hosts.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Canonical model repo (HF layout, mirrored on ModelScope).
pub const MODEL_REPO: &str = "Qwen/Qwen3-ASR-1.7B-hf";

/// 说话人分离（旧 sortformer，已被 sherpa 方案取代；保留路径常量供
/// engine-smoke A/B 复现历史测试）。
pub const DIAR_REPO: &str = "audio-cpp/audio.cpp-gguf";
pub const DIAR_FILE: &str = "Sortformer-Diar-4spk-v1-GGUF/sortformer-diar-4spk-v1-q8_0.gguf";

pub fn diar_model_path() -> PathBuf {
    model_dir().parent().unwrap_or(&model_dir()).join("sortformer-diar-4spk-v1-q8_0.gguf")
}

/// ── sherpa-onnx 说话人分离（现行方案）──
/// pyannote 分割 + CAM++ 声纹 + 聚类（全局一致 ID），模型合计 ~34MB。
pub const SHERPA_SEGMENTATION_REL: &str =
    "sherpa-onnx-pyannote-segmentation-3-0/model.onnx";
pub const SHERPA_EMBEDDING_FILE: &str = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx";
pub const SHERPA_SEGMENTATION_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";
pub const SHERPA_EMBEDDING_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx";

pub fn sherpa_diar_dir() -> PathBuf {
    models_root().join("sherpa-diar")
}

/// sherpa 分离模型是否就绪（分割 + 声纹两文件都在）。
pub fn sherpa_diar_ready() -> bool {
    sherpa_diar_dir().join(SHERPA_SEGMENTATION_REL).is_file()
        && sherpa_diar_dir().join(SHERPA_EMBEDDING_FILE).is_file()
}

/// ── 词级对齐模型（qwen3_forced_aligner，说话人归属精修用，可选）──
pub const ALIGNER_FILE: &str = "qwen3-forced-aligner-0.6b-q8_0.gguf";
pub const ALIGNER_URL: &str = "https://hf-mirror.com/audio-cpp/audio.cpp-gguf/resolve/main/Qwen3-ForcedAligner-0.6B-GGUF/qwen3-forced-aligner-0.6b-q8_0.gguf";

/// HF 类下载的基址：镜像设置 > 下载源默认（境内 hf-mirror / 境外 HF 主站）。
/// audio.cpp-gguf 系（sortformer/对齐模型）不在 ModelScope，境内走 hf-mirror。
pub fn hf_base(source: ModelSource, mirror_base: &str) -> &str {
    let custom = mirror_base.trim().trim_end_matches('/');
    if !custom.is_empty() {
        return custom;
    }
    match source {
        ModelSource::ModelScope => "https://hf-mirror.com",
        ModelSource::HuggingFace => "https://huggingface.co",
    }
}

/// sortformer 分离模型下载 URL（hf-mirror ↔ HF 主站随下载源/镜像设置切换）。
pub fn diar_url(source: ModelSource, mirror_base: &str) -> String {
    format!("{}/{}/resolve/main/{}", hf_base(source, mirror_base), DIAR_REPO, DIAR_FILE)
}

/// 词级对齐模型下载 URL。
pub fn aligner_url(source: ModelSource, mirror_base: &str) -> String {
    format!(
        "{}/audio-cpp/audio.cpp-gguf/resolve/main/Qwen3-ForcedAligner-0.6B-GGUF/{}",
        hf_base(source, mirror_base),
        ALIGNER_FILE
    )
}

pub fn aligner_model_path() -> PathBuf {
    models_root().join(ALIGNER_FILE)
}

/// 随包模型目录（安装包内置模型；开发直跑时不存在，一律回落缓存目录）。
/// Linux AppImage：exe 同级 models/；macOS：Contents/Resources/models/
/// （codesign 不允许 MacOS/ 下放数据文件）。CAM++ 声纹模型（~27MB）随包
/// 分发，境内用户无需再直连 GitHub 下载。
pub fn bundled_models_dir() -> PathBuf {
    if let Some(exe) = std::env::current_exe().ok().and_then(|p| p.parent().map(|p| p.to_path_buf())) {
        let linux_layout = exe.join("models");
        if linux_layout.is_dir() {
            return linux_layout;
        }
        let mac_layout = exe.join("../Resources/models");
        if mac_layout.is_dir() {
            return mac_layout;
        }
        return linux_layout;
    }
    PathBuf::from("models")
}

/// 声纹模型实际路径：随包优先，其次缓存目录（老版本安装包无随包模型）。
pub fn embedding_model_path() -> PathBuf {
    embedding_path_in(&bundled_models_dir())
}

/// 纯函数版（测试用）：随包目录有则用，否则缓存目录。
pub fn embedding_path_in(bundled_dir: &std::path::Path) -> PathBuf {
    let bundled = bundled_dir.join(SHERPA_EMBEDDING_FILE);
    if bundled.is_file() {
        bundled
    } else {
        sherpa_diar_dir().join(SHERPA_EMBEDDING_FILE)
    }
}

/// 随包是否已含声纹模型（下载安装进度据此跳过 CAM++）。
pub fn embedding_bundled() -> bool {
    bundled_models_dir().join(SHERPA_EMBEDDING_FILE).is_file()
}

/// Files never needed to load the model (mirrors the reference app's list).
pub const SKIPPED_FILES: &[&str] = &[".gitattributes", "README.md", "configuration.json"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ModelSource {
    /// Default: faster in mainland China.
    #[default]
    ModelScope,
    HuggingFace,
}

/// Cache root, e.g. `~/Library/Caches/simple-asr/models` on macOS.
pub fn models_root() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("simple-asr")
        .join("models")
}

/// On-disk dir for a repo id, mirroring the reference app's naming:
/// `Qwen/Qwen3-ASR-1.7B-hf` → `Qwen_Qwen3-ASR-1.7B-hf`.
pub fn repo_dir(repo: &str) -> PathBuf {
    models_root().join(repo.replace('/', "_"))
}

/// The local snapshot dir for MODEL_REPO.
pub fn model_dir() -> PathBuf {
    repo_dir(MODEL_REPO)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_dir_slashes_become_underscores() {
        assert_eq!(repo_dir(MODEL_REPO), models_root().join("Qwen_Qwen3-ASR-1.7B-hf"));
    }

    #[test]
    fn hf_base_follows_mirror_then_source() {
        // 默认：境内源 → hf-mirror，境外源 → HF 主站
        assert_eq!(hf_base(ModelSource::ModelScope, ""), "https://hf-mirror.com");
        assert_eq!(hf_base(ModelSource::HuggingFace, ""), "https://huggingface.co");
        // 镜像设置优先于下载源；容忍空白与结尾斜杠
        assert_eq!(hf_base(ModelSource::HuggingFace, "https://my.proxy/ "), "https://my.proxy");
    }

    #[test]
    fn gguf_urls_switch_with_source_and_mirror() {
        assert_eq!(
            diar_url(ModelSource::ModelScope, ""),
            format!("https://hf-mirror.com/{DIAR_REPO}/resolve/main/{DIAR_FILE}")
        );
        assert_eq!(
            diar_url(ModelSource::HuggingFace, ""),
            format!("https://huggingface.co/{DIAR_REPO}/resolve/main/{DIAR_FILE}")
        );
        assert!(aligner_url(ModelSource::ModelScope, "").starts_with("https://hf-mirror.com/audio-cpp/"));
        assert!(aligner_url(ModelSource::ModelScope, "https://my.proxy")
            .starts_with("https://my.proxy/audio-cpp/"));
    }

    #[test]
    fn embedding_path_prefers_bundled_when_present() {
        let tmp = std::env::temp_dir().join(format!("asr-emb-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        // 随包不存在 → 缓存目录
        assert_eq!(embedding_path_in(&tmp), sherpa_diar_dir().join(SHERPA_EMBEDDING_FILE));
        // 随包存在 → 随包优先
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join(SHERPA_EMBEDDING_FILE), b"x").unwrap();
        assert_eq!(embedding_path_in(&tmp), tmp.join(SHERPA_EMBEDDING_FILE));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
