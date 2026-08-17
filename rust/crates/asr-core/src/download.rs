//! Dual-source (ModelScope / Hugging Face) model snapshot downloader.
//!
//! Downloads the Transformers-native Qwen3-ASR-1.7B-hf repo (safetensors +
//! tokenizer/config) directly — no GGUF, no conversion.
//!
//! Behavior ported from the reference app's ModelDownloader.swift:
//! - ModelScope rejects requests without a browser-like User-Agent (404).
//! - Files whose on-disk size matches the manifest are skipped (resume).
//! - Downloads go to `<dest>.part` and are atomically renamed on completion.
//! - Progress is reported per file and per ~4 MiB of bytes.

use crate::model::{self, ModelSource};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) simple-asr";
const REPORT_STEP: u64 = 4 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum DownloadError {
    #[error("HTTP {status}: {url}")]
    Http { status: u16, url: String },
    #[error("could not decode {what} from the model repository")]
    Decode { what: &'static str },
    #[error("no downloadable files in repo")]
    NoFiles,
    #[error("cancelled")]
    Cancelled,
    #[error("invalid proxy setting: {0}")]
    Proxy(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("network: {0}")]
    Network(#[from] reqwest::Error),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFile {
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DownloadProgress {
    pub completed_files: u32,
    pub total_files: u32,
    pub completed_bytes: u64,
    pub total_bytes: u64,
    pub current_file: String,
}

impl DownloadProgress {
    pub fn fraction(&self) -> f64 {
        if self.total_bytes == 0 {
            0.0
        } else {
            self.completed_bytes as f64 / self.total_bytes as f64
        }
    }
}

/// Download the full model snapshot into the cache dir. `on_progress` returns
/// false to cancel. Idempotent: complete files are skipped. Returns the
/// snapshot dir. Partial files stay as .part and are resumed next run.
pub fn download_model(
    source: ModelSource,
    mut on_progress: impl FnMut(DownloadProgress) -> bool,
) -> Result<PathBuf, DownloadError> {
    let cfg = crate::settings::load();
    let hf_base = model::hf_base(source, &cfg.mirror_base);
    let repo = model::MODEL_REPO;
    let files = list_repo_files(source, repo, hf_base)?;
    let dir = model::model_dir();

    let total_bytes: u64 = files.iter().map(|f| f.size).sum();
    let total_files = files.len() as u32;
    let mut completed_bytes = 0u64;

    for (i, file) in files.iter().enumerate() {
        let report = |completed_bytes: u64| DownloadProgress {
            completed_files: i as u32,
            total_files,
            completed_bytes,
            total_bytes,
            current_file: file.path.clone(),
        };
        let done = |completed_bytes: u64| DownloadProgress {
            completed_files: i as u32 + 1,
            total_files,
            completed_bytes,
            total_bytes,
            current_file: file.path.clone(),
        };

        let dest = dir.join(&file.path);
        if matches!(std::fs::metadata(&dest), Ok(m) if m.len() == file.size) {
            completed_bytes += file.size;
            if !on_progress(done(completed_bytes)) {
                return Err(DownloadError::Cancelled);
            }
            continue;
        }

        if !on_progress(report(completed_bytes)) {
            return Err(DownloadError::Cancelled);
        }

        let url = file_url(source, repo, &file.path, hf_base);
        let before = completed_bytes;
        fetch_file(&url, &dest, file.size, |delta| on_progress(report(before + delta)))?;
        completed_bytes += file.size;
        if !on_progress(done(completed_bytes)) {
            return Err(DownloadError::Cancelled);
        }
    }
    Ok(dir)
}

/// List downloadable files in the repo via the host's file-list API,
/// excluding SKIPPED_FILES and zero-size entries. HF 侧基址可被镜像设置覆盖。
pub fn list_repo_files(
    source: ModelSource,
    repo: &str,
    hf_base: &str,
) -> Result<Vec<RemoteFile>, DownloadError> {
    let url = match source {
        ModelSource::ModelScope => format!(
            "https://www.modelscope.cn/api/v1/models/{repo}/repo/files?Revision=master"
        ),
        ModelSource::HuggingFace => {
            format!("{hf_base}/api/models/{repo}/tree/main?recursive=true")
        }
    };
    let body = http_get_body(&url)?;
    let files = match source {
        ModelSource::ModelScope => parse_modelscope_manifest(&body)?,
        ModelSource::HuggingFace => parse_hf_manifest(&body)?,
    };
    let files: Vec<_> = files
        .into_iter()
        .filter(|f| !model::SKIPPED_FILES.contains(&f.path.as_str()) && f.size > 0)
        .collect();
    if files.is_empty() {
        return Err(DownloadError::NoFiles);
    }
    Ok(files)
}

// ---- URL building (pure, unit-tested) ----

pub fn file_url(source: ModelSource, repo: &str, path: &str, hf_base: &str) -> String {
    match source {
        ModelSource::ModelScope => format!(
            "https://www.modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={path}"
        ),
        ModelSource::HuggingFace => {
            format!("{hf_base}/{repo}/resolve/main/{path}")
        }
    }
}

// ---- Manifest parsing (pure, unit-tested) ----

fn parse_modelscope_manifest(body: &str) -> Result<Vec<RemoteFile>, DownloadError> {
    #[derive(serde::Deserialize)]
    struct Resp {
        #[serde(rename = "Code")]
        code: i64,
        #[serde(rename = "Data")]
        data: Data,
    }
    #[derive(serde::Deserialize)]
    struct Data {
        #[serde(rename = "Files")]
        files: Vec<File>,
    }
    #[derive(serde::Deserialize)]
    struct File {
        #[serde(rename = "Path")]
        path: String,
        #[serde(rename = "Size")]
        size: u64,
        #[serde(rename = "Type")]
        ty: String,
    }

    let resp: Resp = serde_json::from_str(body)
        .map_err(|_| DownloadError::Decode { what: "ModelScope file list" })?;
    if resp.code != 200 {
        return Err(DownloadError::Decode { what: "ModelScope file list (bad code)" });
    }
    Ok(resp
        .data
        .files
        .into_iter()
        .filter(|f| f.ty == "blob")
        .map(|f| RemoteFile { path: f.path, size: f.size })
        .collect())
}

fn parse_hf_manifest(body: &str) -> Result<Vec<RemoteFile>, DownloadError> {
    #[derive(serde::Deserialize)]
    struct Entry {
        #[serde(rename = "type")]
        ty: String,
        path: String,
        size: Option<u64>,
    }
    let entries: Vec<Entry> =
        serde_json::from_str(body).map_err(|_| DownloadError::Decode { what: "HF file tree" })?;
    Ok(entries
        .into_iter()
        .filter(|e| e.ty == "file")
        .map(|e| RemoteFile { path: e.path, size: e.size.unwrap_or(0) })
        .collect())
}

// ---- HTTP ----

/// 带用户代理的客户端；设置里的代理（http/https/socks5/socks5h）生效。
fn client() -> Result<reqwest::blocking::Client, DownloadError> {
    let mut builder = reqwest::blocking::Client::builder()
        .user_agent(UA)
        .connect_timeout(Duration::from_secs(30));
    let proxy = crate::settings::load().proxy;
    let proxy = proxy.trim();
    if !proxy.is_empty() {
        let parsed = reqwest::Proxy::all(proxy)
            .map_err(|e| DownloadError::Proxy(format!("{proxy}: {e}")))?;
        builder = builder.proxy(parsed);
    }
    builder.build().map_err(|e| DownloadError::Proxy(e.to_string()))
}

fn http_get_body(url: &str) -> Result<String, DownloadError> {
    let resp = client()?.get(url).send()?;
    let status = resp.status();
    if !status.is_success() {
        return Err(DownloadError::Http { status: status.as_u16(), url: url.to_string() });
    }
    Ok(resp.text()?)
}

/// 下载说话人分离模型（gguf 直链，hf-mirror ↔ HF 主站随下载源/镜像设置
/// 切换，复用断点续传与 UA 约定）。`on_bytes(累计)` 返回 false 取消。
pub fn download_diar_model(
    mut on_bytes: impl FnMut(u64) -> bool,
) -> Result<std::path::PathBuf, DownloadError> {
    let cfg = crate::settings::load();
    let url = model::diar_url(cfg.source, &cfg.mirror_base);
    let dest = model::diar_model_path();
    if dest.exists() {
        return Ok(dest);
    }
    // 期望大小取 Content-Length（上游更新即失效会显式报错而非装坏）
    let expected = expected_size(&url)?;
    fetch_file(&url, &dest, expected, &mut on_bytes)?;
    Ok(dest)
}

/// 下载 sherpa-onnx 分离模型（pyannote 分割 tar.bz2 + CAM++ 声纹 onnx，
/// 合计 ~34MB）。`on_bytes(两文件累计字节)` 返回 false 取消。幂等：两文件
/// 都在时直接返回。
pub fn download_sherpa_diar(
    mut on_bytes: impl FnMut(u64) -> bool,
) -> Result<std::path::PathBuf, DownloadError> {
    use std::io::Read;

    let dir = model::sherpa_diar_dir();
    let seg_dest = dir.join(model::SHERPA_SEGMENTATION_REL);
    let emb_dest = dir.join(model::SHERPA_EMBEDDING_FILE);
    if model::sherpa_diar_ready() {
        return Ok(dir);
    }
    std::fs::create_dir_all(seg_dest.parent().expect("segmentation parent"))?;

    // 1) CAM++ 声纹模型（裸 onnx 直存）
    let emb_size = expected_size(model::SHERPA_EMBEDDING_URL)?;
    if !emb_dest.is_file() {
        let done = 0u64;
        fetch_file(model::SHERPA_EMBEDDING_URL, &emb_dest, emb_size, |n| {
            on_bytes(done + n)
        })?;
    }

    // 2) pyannote 分割模型（tar.bz2 → 只取 model.onnx）
    if !seg_dest.is_file() {
        let tar_size = expected_size(model::SHERPA_SEGMENTATION_URL)?;
        let tmp_tar = dir.join("pyannote.tar.bz2.part");
        let done = emb_size;
        fetch_file(model::SHERPA_SEGMENTATION_URL, &tmp_tar, tar_size, |n| {
            on_bytes(done + n)
        })?;
        let f = std::fs::File::open(&tmp_tar)?;
        let bz = bzip2_rs::DecoderReader::new(f);
        let mut archive = tar::Archive::new(bz);
        let mut found = false;
        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?;
            if path.file_name().is_some_and(|n| n == "model.onnx") {
                let mut buf = Vec::new();
                entry.read_to_end(&mut buf)?;
                std::fs::write(&seg_dest, &buf)?;
                found = true;
            }
        }
        let _ = std::fs::remove_file(&tmp_tar);
        if !found {
            return Err(DownloadError::Decode { what: "pyannote tar.bz2 中的 model.onnx" });
        }
    }
    Ok(dir)
}

/// 下载 App 用分离模型组合：sortformer gguf（分段，~175MB，双源）+
/// CAM++ 声纹 onnx（~27MB，GitHub——随包分发后通常跳过；老包无随包时
/// 仍需下载）。`on_bytes(两文件累计)` 取消，幂等。
///
/// （pyannote 分割模型仅 engine-smoke 实验用，不在 App 组合内。）
pub fn download_diar_bundle(
    mut on_bytes: impl FnMut(u64) -> bool,
) -> Result<std::path::PathBuf, DownloadError> {
    let cfg = crate::settings::load();
    // 1) sortformer（hf-mirror ↔ HF 主站随下载源/镜像设置）
    let sf_url = model::diar_url(cfg.source, &cfg.mirror_base);
    let sf_dest = model::diar_model_path();
    let sf_size = expected_size(&sf_url)?;
    if !sf_dest.is_file() {
        fetch_file(&sf_url, &sf_dest, sf_size, &mut on_bytes)?;
    }
    // 2) CAM++（裸 onnx；随包已含则跳过）
    if model::embedding_bundled() {
        return Ok(sf_dest);
    }
    let dir = model::sherpa_diar_dir();
    std::fs::create_dir_all(&dir)?;
    let emb_dest = dir.join(model::SHERPA_EMBEDDING_FILE);
    let emb_size = expected_size(model::SHERPA_EMBEDDING_URL)?;
    if !emb_dest.is_file() {
        let done = sf_size;
        fetch_file(model::SHERPA_EMBEDDING_URL, &emb_dest, emb_size, |n| {
            on_bytes(done + n)
        })?;
    }
    Ok(sf_dest)
}

/// 下载词级对齐模型（qwen3_forced_aligner Q8，~1.1GB，双源）。
pub fn download_aligner_model(
    mut on_bytes: impl FnMut(u64) -> bool,
) -> Result<std::path::PathBuf, DownloadError> {
    let dest = model::aligner_model_path();
    if dest.is_file() {
        return Ok(dest);
    }
    let cfg = crate::settings::load();
    let url = model::aligner_url(cfg.source, &cfg.mirror_base);
    let expected = expected_size(&url)?;
    fetch_file(&url, &dest, expected, &mut on_bytes)?;
    Ok(dest)
}

/// URL 内容长度（HEAD；供安装进度条算总大小）。
pub fn url_size(url: &str) -> Result<u64, DownloadError> {
    expected_size(url)
}

fn expected_size(url: &str) -> Result<u64, DownloadError> {
    let head = client()?.head(url).send()?;
    head.headers()
        .get(reqwest::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .ok_or_else(|| DownloadError::Http { status: head.status().as_u16(), url: url.to_string() })
}

fn fetch_file(
    url: &str,
    dest: &Path,
    expected_size: u64,
    mut on_bytes: impl FnMut(u64) -> bool,
) -> Result<(), DownloadError> {
    let mut resp = client()?.get(url).send()?;
    let status = resp.status();
    if !status.is_success() {
        return Err(DownloadError::Http { status: status.as_u16(), url: url.to_string() });
    }

    let tmp = dest.with_extension("part");
    if let Some(parent) = tmp.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::File::create(&tmp)?;

    let mut buf = [0u8; 1024 * 256];
    let mut count = 0u64;
    let mut last_report = 0u64;
    loop {
        let n = resp.read(&mut buf)?;
        if n == 0 {
            break;
        }
        std::io::Write::write_all(&mut file, &buf[..n])?;
        count += n as u64;
        if count - last_report >= REPORT_STEP {
            if !on_bytes(count) {
                return Err(DownloadError::Cancelled);
            }
            last_report = count;
        }
    }
    drop(file);
    if count != expected_size {
        let _ = std::fs::remove_file(&tmp);
        return Err(DownloadError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            format!("{url}: got {count} bytes, expected {expected_size}"),
        )));
    }
    std::fs::rename(&tmp, dest)?; // same-dir rename = atomic
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_urls_match_reference_downloader() {
        assert_eq!(
            file_url(
                ModelSource::ModelScope,
                "Qwen/Qwen3-ASR-1.7B-hf",
                "model.safetensors",
                "https://huggingface.co"
            ),
            "https://www.modelscope.cn/api/v1/models/Qwen/Qwen3-ASR-1.7B-hf/repo?Revision=master&FilePath=model.safetensors"
        );
        assert_eq!(
            file_url(
                ModelSource::HuggingFace,
                "Qwen/Qwen3-ASR-1.7B-hf",
                "model.safetensors",
                "https://huggingface.co"
            ),
            "https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf/resolve/main/model.safetensors"
        );
        // 镜像基址覆盖 HF 侧主机
        assert_eq!(
            file_url(
                ModelSource::HuggingFace,
                "Qwen/Qwen3-ASR-1.7B-hf",
                "model.safetensors",
                "https://my.proxy"
            ),
            "https://my.proxy/Qwen/Qwen3-ASR-1.7B-hf/resolve/main/model.safetensors"
        );
    }

    #[test]
    fn parses_modelscope_manifest() {
        let body = r#"{"Code":200,"Data":{"Files":[
            {"Path":".gitattributes","Size":100,"Type":"blob"},
            {"Path":"README.md","Size":2000,"Type":"blob"},
            {"Path":"model.safetensors","Size":4069674944,"Type":"blob"},
            {"Path":"docs","Size":0,"Type":"tree"}
        ]}}"#;
        let files = parse_modelscope_manifest(body).unwrap();
        assert_eq!(files.len(), 3); // skip-filter happens in list_repo_files
        assert_eq!(files[2], RemoteFile { path: "model.safetensors".into(), size: 4069674944 });
    }

    #[test]
    fn parses_hf_manifest() {
        let body = r#"[
            {"type":"file","path":".gitattributes","size":100},
            {"type":"file","path":"model.safetensors","size":4069674944},
            {"type":"directory","path":"sub","size":null}
        ]"#;
        let files = parse_hf_manifest(body).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[1].path, "model.safetensors");
    }
}
