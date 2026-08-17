//! asr-core: engine-independent plumbing for simple-asr.
//!
//! - model repos / cache layout / completeness check
//! - dual-source (ModelScope / Hugging Face) downloader with progress + cancel
//! - audio decode (any container symphonia reads) → mono f32 → resample 16 kHz
//! - persisted settings

pub mod audio;
pub mod download;
pub mod languages;
pub mod llm;
pub mod model;
pub mod settings;
pub mod srt;
