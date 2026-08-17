//! audio.cpp 的 Rust FFI 绑定（自维护 C shim，直连 C ABI）。
//!
//! 上游是纯 C++ 库（Registry/Model/Session 类体系），无官方 C 接口；
//! `cshim/` 提供最小转写面。构建依赖预构建的引擎静态库
//! （`AUDIOCPP_SRC` / `AUDIOCPP_BUILD`，见 build.rs），缺省编译为桩。
//!
//! 输入约定：16kHz 单声道 f32 PCM——与 asr-core 音频管线的产物一致，
//! 可直接把解码重采样后的样本喂进来，无需落盘临时 wav。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

mod sys {
    use std::ffi::{c_char, c_float, c_int, c_void};

    extern "C" {
        pub fn acpp_last_error() -> *const c_char;
        pub fn acpp_model_load(
            model_path: *const c_char,
            family_hint: *const c_char,
        ) -> *mut c_void;
        pub fn acpp_model_free(model: *mut c_void);
        #[allow(clippy::too_many_arguments)]
        pub fn acpp_transcribe(
            model: *mut c_void,
            samples: *const c_float,
            sample_count: usize,
            backend: *const c_char,
            device: c_int,
            threads: c_int,
            language: *const c_char,
            out_text: *mut *mut c_char,
            out_lang: *mut *mut c_char,
        ) -> c_int;
        pub fn acpp_free_string(s: *mut c_char);
        pub fn acpp_stream_start(
            model: *mut c_void,
            backend: *const c_char,
            device: c_int,
            threads: c_int,
            language: *const c_char,
            chunk_seconds: f64,
            total_samples: i64,
        ) -> *mut c_void;
        pub fn acpp_stream_push(
            stream: *mut c_void,
            samples: *const c_float,
            sample_count: usize,
            out_text: *mut *mut c_char,
            has_text: *mut c_int,
            is_final: *mut c_int,
        ) -> c_int;
        pub fn acpp_stream_finish(
            stream: *mut c_void,
            out_text: *mut *mut c_char,
            out_lang: *mut *mut c_char,
        ) -> c_int;
        pub fn acpp_stream_free(stream: *mut c_void);
        pub fn acpp_diarize(
            model: *mut c_void,
            samples: *const c_float,
            sample_count: usize,
            backend: *const c_char,
            device: c_int,
            threads: c_int,
            out_json: *mut *mut c_char,
        ) -> c_int;
        pub fn acpp_align(
            model: *mut c_void,
            samples: *const c_float,
            sample_count: usize,
            text: *const c_char,
            language: *const c_char,
            backend: *const c_char,
            device: c_int,
            threads: c_int,
            out_json: *mut *mut c_char,
        ) -> c_int;
    }
}

fn last_error() -> String {
    unsafe {
        let ptr = sys::acpp_last_error();
        if ptr.is_null() {
            String::new()
        } else {
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }
}

/// 取走 shim 分配的 C 字符串（拷贝后释放原串）。
unsafe fn take_string(p: *mut c_char) -> String {
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    sys::acpp_free_string(p);
    s
}

/// 已加载的 audio.cpp 模型（-hf 目录或单文件 GGUF）。
pub struct AcppModel {
    ptr: *mut c_void,
}

// 句柄由 Registry（进程内单例）分发，上游引擎自身多线程使用；
// 转写调用方自行串行化（与 asr_bridge 的引擎互斥一致）。裸指针仅是
// C++ 对象地址，无线程亲和性，Sync 声明与 candle Device 的做法一致。
unsafe impl Send for AcppModel {}
unsafe impl Sync for AcppModel {}

impl AcppModel {
    /// 加载模型。`family_hint` 通常传 `"qwen3_asr"`。
    pub fn load(model_path: &Path, family_hint: &str) -> Result<Self, String> {
        let path = CString::new(model_path.to_string_lossy().as_bytes())
            .map_err(|e| format!("模型路径含内部 NUL：{e}"))?;
        let family = CString::new(family_hint).map_err(|e| format!("family 非法：{e}"))?;
        let ptr = unsafe { sys::acpp_model_load(path.as_ptr(), family.as_ptr()) };
        if ptr.is_null() {
            Err(format!("audio.cpp 模型加载失败：{}", last_error()))
        } else {
            Ok(Self { ptr })
        }
    }

    /// 离线转写一段 16kHz 单声道 f32 PCM。
    ///
    /// `backend`：`cpu` / `cuda` / `hip` / `vulkan` / `metal`；
    /// `language` 传空串表示自动检测。返回 `(文本, 检测语言)`。
    pub fn transcribe(
        &self,
        pcm: &[f32],
        backend: &str,
        device: u32,
        threads: u32,
        language: &str,
    ) -> Result<(String, String), String> {
        let backend = CString::new(backend).map_err(|e| format!("backend 非法：{e}"))?;
        let language = CString::new(language).map_err(|e| format!("language 非法：{e}"))?;
        let mut out_text: *mut c_char = std::ptr::null_mut();
        let mut out_lang: *mut c_char = std::ptr::null_mut();
        let rc = unsafe {
            sys::acpp_transcribe(
                self.ptr,
                pcm.as_ptr(),
                pcm.len(),
                backend.as_ptr(),
                device as c_int,
                threads as c_int,
                language.as_ptr(),
                &mut out_text,
                &mut out_lang,
            )
        };
        if rc != 0 {
            return Err(format!("audio.cpp 转写失败：{}", last_error()));
        }
        Ok((unsafe { take_string(out_text) }, unsafe { take_string(out_lang) }))
    }
}

/// 流式转写会话：push 增量音频拿增量文本，finish 得权威全文。
pub struct AcppStream {
    ptr: *mut c_void,
}

unsafe impl Send for AcppStream {}

/// push 返回的流式事件。
pub struct StreamEvent {
    /// 本次增量文本（可能为空）。
    pub text: Option<String>,
    pub is_final: bool,
}

impl AcppModel {
    /// 开始流式转写会话。`chunk_seconds` 为引擎内部吐增量的节奏（秒，
    /// 如 5.0）；`total_samples` 为预期音频总长（音频契约容量，按实际传入）。
    pub fn start_stream(
        &self,
        backend: &str,
        device: u32,
        threads: u32,
        language: &str,
        chunk_seconds: f64,
        total_samples: usize,
    ) -> Result<AcppStream, String> {
        let backend = CString::new(backend).map_err(|e| format!("backend 非法：{e}"))?;
        let language = CString::new(language).map_err(|e| format!("language 非法：{e}"))?;
        let ptr = unsafe {
            sys::acpp_stream_start(
                self.ptr,
                backend.as_ptr(),
                device as c_int,
                threads as c_int,
                language.as_ptr(),
                chunk_seconds,
                total_samples as i64,
            )
        };
        if ptr.is_null() {
            Err(format!("流式会话创建失败：{}", last_error()))
        } else {
            Ok(AcppStream { ptr })
        }
    }
}

impl AcppStream {
    /// 推送一段 16kHz 单声道 f32 PCM，取回本次事件（增量文本）。
    pub fn push(&self, pcm: &[f32]) -> Result<StreamEvent, String> {
        let mut out_text: *mut c_char = std::ptr::null_mut();
        let mut has_text: c_int = 0;
        let mut is_final: c_int = 0;
        let rc = unsafe {
            sys::acpp_stream_push(
                self.ptr,
                pcm.as_ptr(),
                pcm.len(),
                &mut out_text,
                &mut has_text,
                &mut is_final,
            )
        };
        if rc != 0 {
            return Err(format!("流式推送失败：{}", last_error()));
        }
        let text = if has_text != 0 && !out_text.is_null() {
            unsafe { take_string(out_text) }
        } else {
            String::new()
        };
        Ok(StreamEvent {
            text: if text.is_empty() { None } else { Some(text) },
            is_final: is_final != 0,
        })
    }

    /// 结束会话：返回（权威全文, 检测语言）。
    pub fn finish(&self) -> Result<(String, String), String> {
        let mut out_text: *mut c_char = std::ptr::null_mut();
        let mut out_lang: *mut c_char = std::ptr::null_mut();
        let rc =
            unsafe { sys::acpp_stream_finish(self.ptr, &mut out_text, &mut out_lang) };
        if rc != 0 {
            return Err(format!("流式收尾失败：{}", last_error()));
        }
        Ok((unsafe { take_string(out_text) }, unsafe { take_string(out_lang) }))
    }
}

impl Drop for AcppStream {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { sys::acpp_stream_free(self.ptr) };
        }
    }
}

/// 说话人分段（秒）。
pub struct SpeakerSegment {
    pub start_sec: f64,
    pub end_sec: f64,
    pub speaker: String,
}

/// 强制对齐的单词时间戳（秒）。
pub struct AlignedWord {
    pub start_sec: f64,
    pub end_sec: f64,
    pub word: String,
    pub confidence: f32,
}

impl AcppModel {
    /// 说话人分离（sortformer_diar 模型句柄）。内部按 20s 固定窗口分窗推理，
    /// 时间偏移并合并相邻同说话人段。注意：跨窗说话人编号可能重标。
    pub fn diarize(
        &self,
        pcm: &[f32],
        backend: &str,
        device: u32,
        threads: u32,
    ) -> Result<Vec<SpeakerSegment>, String> {
        let backend = CString::new(backend).map_err(|e| format!("backend 非法：{e}"))?;
        let mut out_json: *mut c_char = std::ptr::null_mut();
        let rc = unsafe {
            sys::acpp_diarize(
                self.ptr,
                pcm.as_ptr(),
                pcm.len(),
                backend.as_ptr(),
                device as c_int,
                threads as c_int,
                &mut out_json,
            )
        };
        if rc != 0 {
            return Err(format!("说话人分离失败：{}", last_error()));
        }
        let json = unsafe { take_string(out_json) };
        let raw: Vec<serde_json::Value> = serde_json::from_str(&json)
            .map_err(|e| format!("分离结果解析失败：{e}"))?;
        Ok(raw
            .into_iter()
            .map(|v| SpeakerSegment {
                start_sec: v["start_sec"].as_f64().unwrap_or(0.0),
                end_sec: v["end_sec"].as_f64().unwrap_or(0.0),
                speaker: v["speaker"].as_str().unwrap_or("?").to_string(),
            })
            .collect())
    }

    /// 词级强制对齐（qwen3_forced_aligner 句柄）：给定音频与其转写文本，
    /// 返回逐词时间戳。language 建议 FromString 显式传（如 "Chinese"）。
    pub fn align(
        &self,
        pcm: &[f32],
        text: &str,
        language: &str,
        backend: &str,
        device: u32,
        threads: u32,
    ) -> Result<Vec<AlignedWord>, String> {
        let text_c = CString::new(text).map_err(|e| format!("text 非法：{e}"))?;
        let language_c = CString::new(language).map_err(|e| format!("language 非法：{e}"))?;
        let backend_c = CString::new(backend).map_err(|e| format!("backend 非法：{e}"))?;
        let mut out_json: *mut c_char = std::ptr::null_mut();
        let rc = unsafe {
            sys::acpp_align(
                self.ptr,
                pcm.as_ptr(),
                pcm.len(),
                text_c.as_ptr(),
                language_c.as_ptr(),
                backend_c.as_ptr(),
                device as c_int,
                threads as c_int,
                &mut out_json,
            )
        };
        if rc != 0 {
            return Err(format!("强制对齐失败：{}", last_error()));
        }
        let json = unsafe { take_string(out_json) };
        let raw: Vec<serde_json::Value> = serde_json::from_str(&json)
            .map_err(|e| format!("对齐结果解析失败：{e}"))?;
        Ok(raw
            .into_iter()
            .map(|v| AlignedWord {
                start_sec: v["start_sec"].as_f64().unwrap_or(0.0),
                end_sec: v["end_sec"].as_f64().unwrap_or(0.0),
                word: v["word"].as_str().unwrap_or("").to_string(),
                confidence: v["confidence"].as_f64().unwrap_or(0.0) as f32,
            })
            .collect())
    }
}

impl Drop for AcppModel {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { sys::acpp_model_free(self.ptr) };
        }
    }
}
