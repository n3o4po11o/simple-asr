//! 内置下载（asr-core 双源下载器）经 frb Stream 暴露。
//! 事件流：若干 progress 事件 + 终态（error / cancelled / 正常结束）。

use asr_core::download::download_model as core_download;
use asr_core::model::ModelSource;
use std::sync::atomic::{AtomicBool, Ordering};

// frb 2.12：StreamSink 由生成代码在本 crate 内定义。
use crate::frb_generated::StreamSink;

static CANCEL: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Debug)]
pub struct DownloadProgressDto {
    pub completed_files: u32,
    pub total_files: u32,
    pub completed_bytes: u64,
    pub total_bytes: u64,
    pub current_file: String,
}

#[derive(Clone, Debug)]
pub struct DownloadEventDto {
    /// 进行中事件。
    pub progress: Option<DownloadProgressDto>,
    /// 终态：失败信息。
    pub error: Option<String>,
    /// 终态：用户取消。
    pub cancelled: bool,
}

fn parse_source(s: &str) -> ModelSource {
    if s == "huggingFace" {
        ModelSource::HuggingFace
    } else {
        ModelSource::ModelScope
    }
}

/// 启动下载（后台线程），进度与终态经 `sink` 推送。
pub fn download_model(
    source: String,
    sink: StreamSink<DownloadEventDto>,
) -> anyhow::Result<()> {
    let src = parse_source(&source);
    CANCEL.store(false, Ordering::SeqCst);

    std::thread::spawn(move || {
        let result = core_download(src, |p| {
            if CANCEL.load(Ordering::SeqCst) {
                return false;
            }
            let _ = sink.add(DownloadEventDto {
                progress: Some(DownloadProgressDto {
                    completed_files: p.completed_files,
                    total_files: p.total_files,
                    completed_bytes: p.completed_bytes,
                    total_bytes: p.total_bytes,
                    current_file: p.current_file.clone(),
                }),
                error: None,
                cancelled: false,
            });
            true
        });

        let terminal = match result {
            Ok(_) => DownloadEventDto { progress: None, error: None, cancelled: false },
            Err(asr_core::download::DownloadError::Cancelled) => {
                DownloadEventDto { progress: None, error: None, cancelled: true }
            }
            Err(e) => DownloadEventDto { progress: None, error: Some(e.to_string()), cancelled: false },
        };
        let _ = sink.add(terminal);
    });
    Ok(())
}

pub fn cancel_download() {
    CANCEL.store(true, Ordering::SeqCst);
}
