//! Persisted user settings (JSON in the config dir).

use crate::languages::AUTO;
use crate::model::ModelSource;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub source: ModelSource,
    /// Language id; "auto" = detect.
    pub language: String,
    /// 计算后端："auto" | "cpu" | "metal" | "vulkan"。
    #[serde(default = "default_backend")]
    pub backend: String,
    /// 后端的设备序号（GPU 多卡时选择）。
    #[serde(default)]
    pub device_ordinal: u32,
    /// 转写引擎：仅 "audiocpp"（candle 已移除，历史值在 load() 迁移）。
    #[serde(default = "default_engine")]
    pub engine: String,
    /// audiocpp 引擎用 Q8 量化模型（需先经「一键转换」生成 model.q8_0.gguf）。
    #[serde(default)]
    pub acpp_q8: bool,
    /// 说话人分离（需 sherpa 模型，输出带 [说话人] 前缀）。
    #[serde(default)]
    pub diarization: bool,
    /// 已知说话人数（0=按阈值自动聚类；客服双人通话场景默认 2）。
    #[serde(default = "default_diar_speakers")]
    pub diar_speakers: u32,
    /// 外接 LLM 润色（OpenAI 兼容端点，用户自备）。
    #[serde(default)]
    pub llm_polish: bool,
    #[serde(default)]
    pub llm_url: String,
    #[serde(default)]
    pub llm_key: String,
    #[serde(default)]
    pub llm_model: String,
    /// HF 类下载的镜像基址（空 = 按下载源默认：境内 hf-mirror / 境外 HF
    /// 主站）。用户可填自建反代或其他加速域名，覆盖主模型 HF 侧与
    /// sortformer/对齐模型 gguf 下载。
    #[serde(default)]
    pub mirror_base: String,
    /// 网络代理（http/https/socks5/socks5h，如 http://127.0.0.1:7890；
    /// 空 = 不使用）。作用于全部模型下载与 LLM 润色请求。
    #[serde(default)]
    pub proxy: String,
}

fn default_engine() -> String {
    "audiocpp".to_string()
}

fn default_backend() -> String {
    "auto".to_string()
}

fn default_diar_speakers() -> u32 {
    2
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            source: ModelSource::ModelScope,
            language: AUTO.to_string(),
            backend: default_backend(),
            device_ordinal: 0,
            engine: default_engine(),
            acpp_q8: false,
            diarization: false,
            diar_speakers: default_diar_speakers(),
            llm_polish: false,
            llm_url: String::new(),
            llm_key: String::new(),
            llm_model: String::new(),
            mirror_base: String::new(),
            proxy: String::new(),
        }
    }
}

pub fn settings_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("simple-asr")
        .join("settings.json")
}

pub fn load() -> Settings {
    let mut s: Settings = std::fs::read_to_string(settings_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    // candle 引擎已移除（2026-08-15）：历史设置迁移到 audiocpp
    if s.engine != "audiocpp" {
        s.engine = default_engine();
    }
    s
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let path = settings_path();
    std::fs::create_dir_all(path.parent().expect("settings dir parent"))?;
    std::fs::write(path, serde_json::to_string_pretty(settings).expect("serialize settings"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_through_json() {
        let s = Settings { language: "Japanese".into(), ..Default::default() };
        let json = serde_json::to_string(&s).unwrap();
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.language, "Japanese");
        assert_eq!(back.source, ModelSource::ModelScope);
    }
}
