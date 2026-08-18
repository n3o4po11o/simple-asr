//! 设置持久化（asr-core settings.rs 的 JSON 存取）。

#[derive(Clone, Debug)]
pub struct SettingsDto {
    /// "modelScope" | "huggingFace"
    pub source: String,
    /// 语言 id，"auto" = 自动检测
    pub language: String,
    /// "auto" | "cpu" | "metal" | "vulkan"
    pub backend: String,
    pub device_ordinal: u32,
    /// audiocpp 引擎是否用 Q8 量化模型
    pub acpp_q8: bool,
    /// 说话人分离（需 sherpa 模型）
    pub diarization: bool,
    /// 已知说话人数（0=自动聚类）
    pub diar_speakers: u32,
    /// 外接 LLM 润色（OpenAI 兼容端点）
    pub llm_polish: bool,
    pub llm_url: String,
    pub llm_key: String,
    pub llm_model: String,
    /// HF 类下载镜像基址（空 = 按下载源默认）
    pub mirror_base: String,
    /// 网络代理 http/https/socks5/socks5h（空 = 不使用）
    pub proxy: String,
}

pub fn load_settings() -> SettingsDto {
    let s = asr_core::settings::load();
    SettingsDto {
        source: match s.source {
            asr_core::model::ModelSource::ModelScope => "modelScope".to_string(),
            asr_core::model::ModelSource::HuggingFace => "huggingFace".to_string(),
        },
        language: s.language,
        backend: s.backend,
        device_ordinal: s.device_ordinal,
        acpp_q8: s.acpp_q8,
        diarization: s.diarization,
        diar_speakers: s.diar_speakers,
        llm_polish: s.llm_polish,
        llm_url: s.llm_url,
        llm_key: s.llm_key,
        llm_model: s.llm_model,
        mirror_base: s.mirror_base,
        proxy: s.proxy,
    }
}

pub fn save_settings(dto: SettingsDto) -> anyhow::Result<()> {
    let s = asr_core::settings::Settings {
        source: if dto.source == "huggingFace" {
            asr_core::model::ModelSource::HuggingFace
        } else {
            asr_core::model::ModelSource::ModelScope
        },
        language: dto.language,
        backend: dto.backend,
        device_ordinal: dto.device_ordinal,
        acpp_q8: dto.acpp_q8,
        diarization: dto.diarization,
        diar_speakers: dto.diar_speakers,
        llm_polish: dto.llm_polish,
        llm_url: dto.llm_url,
        llm_key: dto.llm_key,
        llm_model: dto.llm_model,
        mirror_base: dto.mirror_base,
        proxy: dto.proxy,
        engine: "audiocpp".to_string(),
    };
    asr_core::settings::save(&s).map_err(|e| anyhow::anyhow!("{e}"))
}
