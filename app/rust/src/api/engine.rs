//! 转写引擎（audio.cpp 经 audiocpp-ffi 直连；audiocpp 为唯一引擎，
//! Linux=Vulkan、macOS=Metal）。模型实例全局单例；转写在独立线程执行
//! 会话），事件为「累计全文」替换式上屏，块间可取消。

use crate::align::refine_lines_with_aligner;
use crate::frb_generated::StreamSink;
use asr_core::model;
use audiocpp_ffi::AcppModel;
use sherpa_ffi::{SpeakerEmbedder, cluster_embeddings};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

static ENGINE: OnceLock<Mutex<Option<Arc<AcppModel>>>> = OnceLock::new();
/// sortformer 分段引擎（说话人分离第一步，GPU，懒加载缓存）。
static SORTFORMER_ENGINE: OnceLock<Mutex<Option<Arc<AcppModel>>>> = OnceLock::new();
/// CAM++ 声纹提取器（说话人分离第二步，CPU，懒加载缓存）。
static EMBEDDER: OnceLock<Mutex<Option<Arc<SpeakerEmbedder>>>> = OnceLock::new();
/// 词级对齐引擎（qwen3_forced_aligner，可选安装，懒加载缓存）。
static ALIGNER_ENGINE: OnceLock<Mutex<Option<Arc<AcppModel>>>> = OnceLock::new();
/// 转写检测到的语言（对齐必需；项目文件随存随载）。
static LAST_LANG: Mutex<String> = Mutex::new(String::new());
/// 最近一次转写的 SRT 字幕（导出用）。
static LAST_SRT: Mutex<String> = Mutex::new(String::new());
/// 最近一次转写的 LRC 歌词（导出用）。
static LAST_LRC: Mutex<String> = Mutex::new(String::new());

/// 转写增量素材（说话人与文本分离，导出/校对两用）。
struct LinePiece {
    start_sec: f64,
    end_sec: f64,
    speaker: Option<String>,
    text: String,
    /// 行内逐字锚点（词级对齐路径填充；块级路径为空）
    anchors: Vec<asr_core::srt::WordAnchor>,
}

/// 校对视图的带时间轴文本行（SRT/LRC 同源切分）。
#[derive(Clone, Debug)]
pub struct TranscriptLineDto {
    pub start_sec: f64,
    pub end_sec: f64,
    /// 说话人（diar 开启时），如 "SPEAKER_00"
    pub speaker: Option<String>,
    pub text: String,
}

static LAST_LINES: Mutex<Vec<TranscriptLineDto>> = Mutex::new(Vec::new());
/// 校对行完整形态（含逐字锚点）——**单一数据源**，LAST_LINES 是它的 DTO
/// 投影（frb 不暴露锚点，拆分吸附/项目存取在 Rust 侧完成）。
static LAST_PROOF: Mutex<Vec<asr_core::srt::ProofLine>> = Mutex::new(Vec::new());
/// 转写完成时的行快照（进入校准的 diff 基准；项目文件随存随载）。
static LAST_ORIGINAL_LINES: Mutex<Vec<asr_core::srt::ProofLine>> = Mutex::new(Vec::new());
/// 转写音频的完整路径（项目文件记录；加载时校验存在性，移动后可改指）。
static LAST_AUDIO_PATH: Mutex<String> = Mutex::new(String::new());
/// 转写音频的文件名（LRC [ti:] 头，行编辑后重建时复用）。
static LAST_AUDIO_TITLE: Mutex<String> = Mutex::new(String::new());
/// 说话人显示名（SPEAKER_00 → "客服"），导出与 UI 共用。
static SPEAKER_NAMES: OnceLock<Mutex<std::collections::HashMap<String, String>>> = OnceLock::new();

fn speaker_names() -> &'static Mutex<std::collections::HashMap<String, String>> {
    SPEAKER_NAMES.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn speaker_label(spk: &str) -> String {
    speaker_names()
        .lock()
        .unwrap()
        .get(spk)
        .cloned()
        .unwrap_or_else(|| spk.to_string())
}

/// 校对行全量落盘（转写完成/项目加载时调用）：设主数据 + 投影 DTO。
fn set_proof_lines(lines: Vec<asr_core::srt::ProofLine>) {
    *LAST_LINES.lock().unwrap() = lines
        .iter()
        .map(|l| TranscriptLineDto {
            start_sec: l.start_sec,
            end_sec: l.end_sec,
            speaker: l.speaker.clone(),
            text: l.text.clone(),
        })
        .collect();
    *LAST_PROOF.lock().unwrap() = lines;
}

/// LAST_PROOF 已改动 → 投影到 LAST_LINES（编辑/拆分/换说话人后调用）。
fn sync_lines_from_proof() {
    let proof = LAST_PROOF.lock().unwrap();
    *LAST_LINES.lock().unwrap() = proof
        .iter()
        .map(|l| TranscriptLineDto {
            start_sec: l.start_sec,
            end_sec: l.end_sec,
            speaker: l.speaker.clone(),
            text: l.text.clone(),
        })
        .collect();
}

/// 由 LAST_LINES 重建 SRT/LRC（编辑行/改说话人/重命名后调用）。
fn rebuild_exports_from_lines() {
    let lines = LAST_LINES.lock().unwrap();
    let cues: Vec<asr_core::srt::Cue> = lines
        .iter()
        .map(|l| asr_core::srt::Cue {
            start_sec: l.start_sec,
            end_sec: l.end_sec,
            text: match &l.speaker {
                Some(spk) => format!("[{}] {}", speaker_label(spk), l.text),
                None => l.text.clone(),
            },
        })
        .collect();
    let title = LAST_AUDIO_TITLE.lock().unwrap().clone();
    *LAST_SRT.lock().unwrap() = asr_core::srt::build_srt(&cues);
    *LAST_LRC.lock().unwrap() = asr_core::srt::build_lrc(&cues, Some(&title));
}

/// 校对视图波形（按路径缓存，避免重复解码整段音频）。
static WAVE_CACHE: Mutex<(String, Vec<f32>)> = Mutex::new((String::new(), Vec::new()));
static TRANSCRIBE_CANCEL: AtomicBool = AtomicBool::new(false);
/// 加载模型时记录的设备序号（audiocpp 转写时使用）。
static DEVICE_ORDINAL: AtomicU32 = AtomicU32::new(0);

fn engine() -> &'static Mutex<Option<Arc<AcppModel>>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

#[derive(Clone, Debug)]
pub struct TranscribeEventDto {
    /// 当前累计转写全文（流式每步更新，替换式）。
    pub text: Option<String>,
    /// 过程状态（如「正在精修时间轴… 3/87」）；UI 进度文案用。
    pub status: Option<String>,
    /// 终态：失败信息。
    pub error: Option<String>,
    /// 终态：用户取消（text 事件已含部分结果）。
    pub cancelled: bool,
    /// 终态：正常完成。
    pub done: bool,
    pub language: String,
    pub elapsed_sec: f64,
}

pub fn load_model(backend: String, device_ordinal: u32) -> anyhow::Result<()> {
    let _ = backend; // 后端在转写时按设置解析（模型懒加载，与后端无关）
    DEVICE_ORDINAL.store(device_ordinal, Ordering::SeqCst);
    let settings = asr_core::settings::load();
    let dir = model::model_dir();
    let q8_path = dir.join("model.q8_0.gguf");
    let model_path = if settings.acpp_q8 {
        if !q8_path.exists() {
            return Err(anyhow::anyhow!(
                "Q8 模型未生成（model.q8_0.gguf），请先在设置中执行一键转换"
            ));
        }
        q8_path
    } else {
        if !dir.join("model.safetensors").exists() {
            return Err(anyhow::anyhow!("本地未找到模型，请先下载"));
        }
        dir
    };
    let m = AcppModel::load(&model_path, "qwen3_asr")
        .map_err(|e| anyhow::anyhow!("audio.cpp 加载失败：{e}"))?;
    *engine().lock().unwrap() = Some(Arc::new(m));
    Ok(())
}

pub fn cancel_load() {
    // 加载过程不可中断（懒加载，亚秒级）。
}

pub fn unload_model() {
    *engine().lock().unwrap() = None;
}

pub fn is_model_loaded() -> bool {
    engine().lock().unwrap().is_some()
}

/// audiocpp 后端名映射：auto→平台默认（macOS=metal，Linux=vulkan）。
/// 后端面只保留 cpu/metal/vulkan（cuda/rocm 已随 candle 移除；历史设置值
/// 一律回落平台默认）。
fn acpp_backend_name(backend: &str) -> &str {
    match backend {
        "cpu" | "vulkan" | "metal" | "best" => backend,
        _ => {
            if cfg!(target_os = "macos") {
                "metal"
            } else {
                "vulkan"
            }
        }
    }
}

pub fn transcribe_file(
    path: String,
    language: String,
    sink: StreamSink<TranscribeEventDto>,
) -> anyhow::Result<()> {
    let m = engine()
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow::anyhow!("模型未加载"))?;
    TRANSCRIBE_CANCEL.store(false, Ordering::SeqCst);
    let backend = asr_core::settings::load().backend;
    std::thread::spawn(move || acpp_transcribe_thread(m, &path, &language, &backend, sink));
    Ok(())
}

/// audiocpp 转写线程：5 分钟大块会话（audio.cpp 内部自带 VAD 智能分块，
/// 大块=边界更少、覆盖率更高；显存由其内部分块约束，实测 19 分钟峰值 ~7.6G）。
/// 事件契约：累计全文替换式上屏，块间可取消。
fn acpp_transcribe_thread(
    m: Arc<AcppModel>,
    path: &str,
    language: &str,
    backend: &str,
    sink: StreamSink<TranscribeEventDto>,
) {
    let started = Instant::now();
    let device = DEVICE_ORDINAL.load(Ordering::SeqCst);
    let backend_name = acpp_backend_name(backend);
    let result = (|| -> Result<(String, String), String> {
        let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(path))
            .map_err(|e| format!("读取音频失败：{e}"))?;

        // 说话人分离（可选）：混合流水线（sortformer 分段 + CAM++ 声纹聚类）。
        // **并行执行**——与流式转写同时跑（分段走 GPU、声纹走 CPU，互不抢核），
        // 文本即刻开始上屏，不再有「转写前 CPU 拉满干等」的阶段；说话人归属
        // 在收尾统一回填（词级对齐或块级重叠）。
        let settings_now = asr_core::settings::load();
        let diar_handle = if settings_now.diarization {
            let pcm2 = pcm.clone();
            let k = settings_now.diar_speakers;
            let backend2 = backend_name.to_string();
            let sink2 = sink.clone();
            Some(std::thread::spawn(move || {
                // 分离与流式并行（GPU/CPU 互不抢核），此状态先显示、随后被
                // 识别增量覆盖；若分离比识别慢，收尾 join 前还有汇总提示
                let _ = sink2.add(TranscribeEventDto {
                    text: None,
                    status: Some("正在分离说话人…".to_string()),
                    error: None,
                    cancelled: false,
                    done: false,
                    language: String::new(),
                    elapsed_sec: 0.0,
                });
                hybrid_diarize(&pcm2, k, &backend2, device)
            }))
        } else {
            None
        };

        // 流式转写：每秒 push 一次音频，引擎按 5 秒节奏吐增量文本（实测
        // Mac Metal 9 增量/45s 音频）。显示层用增量累计；收尾以 finish 的
        // 权威全文为准（流式边界可能有细微切分噪声）。
        const DELTA_SEC: f64 = 5.0;
        let stream = m
            .start_stream(backend_name, device, 4, language, DELTA_SEC, pcm.len())
            .map_err(|e| format!("转写失败：{e}"))?;
        let mut accumulated = String::new();
        let mut detected_lang = String::new();
        // 增量时间区间追踪（diar 对齐 + SRT 字幕用）：每 push 1 秒音频推进
        let mut t_pos = 0.0f64;
        let mut t_text_end = 0.0f64;
        let mut cues: Vec<LinePiece> = Vec::new();

        for chunk in pcm.chunks(16000) {
            if TRANSCRIBE_CANCEL.load(Ordering::SeqCst) {
                break;
            }
            let ev = stream.push(chunk).map_err(|e| format!("转写失败：{e}"))?;
            if let Some(delta) = ev.text {
                accumulated.push_str(&delta);
                // 字幕/校对素材：说话人与文本分离存（diar 并行中，归属收尾回填）
                cues.push(LinePiece {
                    start_sec: t_text_end,
                    end_sec: t_pos + 1.0,
                    speaker: None,
                    text: delta.clone(),
                    anchors: Vec::new(),
                });
                t_text_end = t_pos + 1.0;
                let _ = sink.add(TranscribeEventDto {
                    text: Some(accumulated.clone()),
                    status: None,
                    error: None,
                    cancelled: false,
                    done: false,
                    language: String::new(),
                    elapsed_sec: started.elapsed().as_secs_f64(),
                });
            }
            t_pos += chunk.len() as f64 / 16000.0;
        }

        if TRANSCRIBE_CANCEL.load(Ordering::SeqCst) {
            if let Some(h) = diar_handle {
                let _ = h.join();
            }
            return Ok((accumulated, detected_lang));
        }
        let (final_text, lang) = stream.finish().map_err(|e| format!("转写收尾失败：{e}"))?;
        if !lang.is_empty() {
            detected_lang = lang;
        }
        // 等待并行分离完成（分段走 GPU 与转写同时跑完，此处通常零等待；
        // 分离慢于识别时此提示避免静默等待）。分离失败不致命——按无说话人
        // 继续（文本已完整）。
        if diar_handle.is_some() {
            let _ = sink.add(TranscribeEventDto {
                text: None,
                status: Some("正在汇总说话人…".to_string()),
                error: None,
                cancelled: false,
                done: false,
                language: String::new(),
                elapsed_sec: 0.0,
            });
        }
        let diar_turns = match diar_handle {
            Some(h) => match h.join() {
                Ok(Ok(turns)) if !turns.is_empty() => Some(turns),
                Ok(Ok(_)) => None,
                Ok(Err(e)) => {
                    eprintln!("[diar] 分离失败（继续无说话人）：{e}");
                    None
                }
                Err(_) => None,
            },
            None => None,
        };
        let speaker_at = |a: f64, b: f64| -> Option<String> {
            let turns = diar_turns.as_ref()?;
            let mut best: Option<&DiarTurn> = None;
            let mut best_ov = 0.0f64;
            for t in turns {
                let ov = (t.end_sec.min(b) - t.start_sec.max(a)).max(0.0);
                if ov > best_ov {
                    best_ov = ov;
                    best = Some(t);
                }
            }
            best.map(|t| t.speaker.clone())
        };
        // diar 模式：按 5s 增量区间重叠回填说话人（词级精修在行构建后
        // 逐行进行——见 refine_lines_with_aligner；说话人轮次边界由 diar 段决定）
        if diar_turns.is_some() {
            // 块级归属（对齐未装/失败）：按 5s 增量区间重叠回填说话人，
            // 并重建带前缀的注解全文
            let mut annotated = String::new();
            let mut cur_spk: Option<String> = None;
            for p in &mut cues {
                p.speaker = speaker_at(p.start_sec, p.end_sec);
                if p.speaker.as_deref() != cur_spk.as_deref() {
                    if let Some(spk) = &p.speaker {
                        if !annotated.is_empty() {
                            annotated.push('\n');
                        }
                        annotated.push_str(&format!("[{spk}] "));
                        cur_spk = p.speaker.clone();
                    }
                }
                annotated.push_str(&p.text);
            }
            accumulated = annotated;
        }
        // diar 模式保留按时间对齐的注解文本（finish 全文无时间戳可对齐）；
        // 普通模式以 finish 权威全文为准
        if diar_turns.is_none() && !final_text.is_empty() {
            accumulated = final_text;
        }
        if let Some(t) = std::path::Path::new(path)
            .file_stem()
            .and_then(|s| s.to_str())
        {
            *LAST_AUDIO_TITLE.lock().unwrap() = t.to_string();
        }
        *LAST_AUDIO_PATH.lock().unwrap() = path.to_string();
        // 校对行（说话人轮次制）：同说话人连续段合并为一行（说话人变化才
        // 换行）；有说话人的行不做 32 字幕字数切分（整轮次一行，导出时
        // build_srt 再按字幕密度切）；未归属（None）行保持字数切分可读性
        //（锚点挂在切分后的首行，越界锚点在吸附插值时自动忽略）。
        // SRT/LRC 由 rebuild_exports_from_lines 统一重建。
        {
            let proof: Vec<asr_core::srt::ProofLine> = asr_core::srt::merge_speaker_runs(
                cues.iter()
                    .map(|p| asr_core::srt::ProofLine {
                        start_sec: p.start_sec,
                        end_sec: p.end_sec,
                        speaker: p.speaker.clone(),
                        text: p.text.clone(),
                        anchors: p.anchors.clone(),
                    })
                    .collect(),
            );
            let mut expanded: Vec<asr_core::srt::ProofLine> = proof
                .into_iter()
                .flat_map(|p| {
                    if p.speaker.is_some() {
                        vec![p]
                    } else {
                        let cue = asr_core::srt::Cue {
                            start_sec: p.start_sec,
                            end_sec: p.end_sec,
                            text: p.text.clone(),
                        };
                        asr_core::srt::split_cue_lines_pub(&cue)
                            .into_iter()
                            .enumerate()
                            .map(|(i, (s, e, text))| asr_core::srt::ProofLine {
                                start_sec: s,
                                end_sec: e,
                                speaker: None,
                                text,
                                // 锚点只挂首子行（未归属行本就无对齐锚点，
                                // 此分支实际为空防御）
                                anchors: if i == 0 { p.anchors.clone() } else { Vec::new() },
                            })
                            .collect::<Vec<_>>()
                    }
                })
                .collect();
            // 逐行对齐精修（对齐器已装且语言已知）：锚点=真实字时刻，
            // 行起止收敛到首末字。逐行容错，长音频不再有全量对齐的
            // max_source_positions 限制。
            if !detected_lang.is_empty() && model::aligner_model_path().is_file() {
                let sink2 = &sink;
                refine_lines_with_aligner(
                    &mut expanded,
                    &pcm,
                    &detected_lang,
                    backend_name,
                    device,
                    Some(&|i, n| {
                        // 精修耗时 ∝ 音频时长（长录音数分钟），逐行上报让
                        // UI 显示「正在精修时间轴…」而非干等
                        let _ = sink2.add(TranscribeEventDto {
                            text: None,
                            status: Some(format!("正在精修时间轴… {i}/{n}")),
                            error: None,
                            cancelled: false,
                            done: false,
                            language: String::new(),
                            elapsed_sec: 0.0,
                        });
                    }),
                    false,
                );
            }
            if !detected_lang.is_empty() {
                *LAST_LANG.lock().unwrap() = detected_lang.clone();
            }
            *LAST_ORIGINAL_LINES.lock().unwrap() = expanded.clone();
            set_proof_lines(expanded);
        }
        rebuild_exports_from_lines();
        Ok((accumulated, detected_lang))
    })();

    match result {
        Ok((text, lang)) => {
            if !text.is_empty() {
                let _ = sink.add(TranscribeEventDto {
                    text: Some(text),
                    status: None,
                    error: None,
                    cancelled: false,
                    done: false,
                    language: lang.clone(),
                    elapsed_sec: 0.0,
                });
            }
            let _ = sink.add(TranscribeEventDto {
                text: None,
                status: None,
                error: None,
                cancelled: TRANSCRIBE_CANCEL.load(Ordering::SeqCst),
                done: true,
                language: lang,
                elapsed_sec: started.elapsed().as_secs_f64(),
            });
        }
        Err(msg) => {
            let _ = sink.add(TranscribeEventDto {
                text: None,
                status: None,
                error: Some(msg),
                cancelled: false,
                done: false,
                language: String::new(),
                elapsed_sec: 0.0,
            });
        }
    }
}

/// 混合分离：sortformer 分段（重叠感知、GPU，切点准但跨窗 ID 会重标）
/// → CAM++ 逐段声纹 → complete-linkage 聚类统一全局 ID。
/// 长段（≥1.5s）做聚类中心（短段嵌入噪声大），短段按最近质心归类。
/// `num_speakers > 0` 按已知人数切树（推荐，自动模式对激烈抢话录音
/// 仍易过碎）；否则按 `threshold` 余弦距离切。
fn hybrid_diarize(
    pcm: &[f32],
    num_speakers: u32,
    backend: &str,
    device: u32,
) -> Result<Vec<DiarTurn>, String> {
    let sf_path = model::diar_model_path();
    let emb_path = model::embedding_model_path(); // 随包优先，其次缓存目录
    if !sf_path.is_file() {
        return Err("说话人分离模型未下载（设置中可安装，约 200 MB）".to_string());
    }
    if !emb_path.is_file() {
        return Err("声纹模型未下载（设置中可安装）".to_string());
    }
    // 1) sortformer 分段
    let cell = SORTFORMER_ENGINE.get_or_init(|| Mutex::new(None));
    let mut guard = cell.lock().unwrap();
    if guard.is_none() {
        *guard = Some(Arc::new(
            AcppModel::load(&sf_path, "sortformer_diar")
                .map_err(|e| format!("分离模型加载失败：{e}"))?,
        ));
    }
    let turns: Vec<DiarTurn> = guard
        .as_ref()
        .unwrap()
        .diarize(pcm, backend, device, 4)?
        .into_iter()
        .filter(|t| t.end_sec - t.start_sec >= 0.5)
        .map(|t| DiarTurn {
            start_sec: t.start_sec,
            end_sec: t.end_sec,
            speaker: t.speaker,
        })
        .collect();
    drop(guard);

    // 2) CAM++ 逐段声纹（长段中心 / 短段待归类）
    let ecell = EMBEDDER.get_or_init(|| Mutex::new(None));
    let mut eguard = ecell.lock().unwrap();
    if eguard.is_none() {
        *eguard = Some(Arc::new(
            SpeakerEmbedder::new(&emb_path, 4).map_err(|e| format!("声纹模型加载失败：{e}"))?,
        ));
    }
    let embedder = eguard.as_ref().unwrap().clone();
    drop(eguard);

    const MIN_CENTER_SEC: f64 = 1.5;
    let mut centers: Vec<Vec<f32>> = Vec::new();
    let mut center_turns: Vec<&DiarTurn> = Vec::new();
    let mut short_turns: Vec<(&DiarTurn, Vec<f32>)> = Vec::new();
    for t in &turns {
        let s = (t.start_sec * 16000.0) as usize;
        let e = ((t.end_sec * 16000.0) as usize).min(pcm.len());
        if e <= s {
            continue;
        }
        if let Some(v) = embedder.embed(&pcm[s..e]) {
            if t.end_sec - t.start_sec >= MIN_CENTER_SEC {
                centers.push(v);
                center_turns.push(t);
            } else {
                short_turns.push((t, v));
            }
        }
    }
    if centers.is_empty() {
        return Ok(Vec::new());
    }

    // 3) 聚类 + 短段就近归类
    let k = num_speakers as usize;
    let center_labels = cluster_embeddings(&centers, k, 0.55);
    let num_clusters = center_labels.iter().cloned().max().map_or(0, |m| m + 1).max(1);
    let mut centroids = vec![vec![0.0f32; embedder.dim()]; num_clusters];
    for (v, &l) in centers.iter().zip(&center_labels) {
        let nrm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        for (c, x) in centroids[l].iter_mut().zip(v) {
            *c += x / nrm;
        }
    }
    let mut out: Vec<(f64, f64, usize)> = Vec::with_capacity(turns.len());
    for (t, &l) in center_turns.iter().zip(&center_labels) {
        out.push((t.start_sec, t.end_sec, l));
    }
    for (t, v) in &short_turns {
        let nrm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        let mut best = (0usize, f32::INFINITY);
        for (l, c) in centroids.iter().enumerate() {
            let sim: f32 = c.iter().zip(v).map(|(a, b)| a * b / nrm).sum();
            let d = 1.0 - sim;
            if d < best.1 {
                best = (l, d);
            }
        }
        out.push((t.start_sec, t.end_sec, best.0));
    }
    out.sort_by(|a, b| a.0.total_cmp(&b.0));
    Ok(out
        .into_iter()
        .map(|(s, e, l)| DiarTurn {
            start_sec: s,
            end_sec: e,
            speaker: format!("SPEAKER_{l:02}"),
        })
        .collect())
}

/// 一条说话人段（桥内统一形状）。
struct DiarTurn {
    start_sec: f64,
    end_sec: f64,
    speaker: String,
}

/// 词级对齐（模型未安装返回 Err）。**必须按行/切片调用**——单次喂全量
/// 长音频会超音频编码器 max_source_positions（实测 23 分钟必炸），曾因此
/// 静默回退块级路径导致锚点全空。
pub(crate) fn align_pcm(
    pcm: &[f32],
    text: &str,
    language: &str,
    backend: &str,
    device: u32,
) -> Result<Vec<audiocpp_ffi::AlignedWord>, String> {
    let path = model::aligner_model_path();
    if !path.is_file() {
        return Err("对齐模型未安装".to_string());
    }
    let cell = ALIGNER_ENGINE.get_or_init(|| Mutex::new(None));
    let mut guard = cell.lock().unwrap();
    if guard.is_none() {
        *guard = Some(Arc::new(
            AcppModel::load(&path, "qwen3_forced_aligner")
                .map_err(|e| format!("对齐模型加载失败：{e}"))?,
        ));
    }
    guard.as_ref().unwrap().align(pcm, text, language, backend, device, 4)
}

/// 说话人分离模型是否已就绪（sortformer 分段 + CAM++ 声纹；声纹随包优先）。
pub fn diar_model_available() -> bool {
    model::diar_model_path().is_file() && model::embedding_model_path().is_file()
}

/// 模型安装进度（字节级；error 非空 = 终态失败）。
pub struct InstallProgressDto {
    pub completed_bytes: u64,
    pub total_bytes: u64,
    pub error: Option<String>,
}

/// 后台线程跑安装并按累计字节推进度；总大小 = 待下载文件的 HEAD 之和。
fn spawn_install(
    total: u64,
    sink: StreamSink<InstallProgressDto>,
    run: impl FnOnce(&mut dyn FnMut(u64) -> bool) -> Result<std::path::PathBuf, asr_core::download::DownloadError>
        + Send
        + 'static,
) {
    std::thread::spawn(move || {
        let mut on_bytes = |done: u64| -> bool {
            let _ = sink.add(InstallProgressDto {
                completed_bytes: done,
                total_bytes: total,
                error: None,
            });
            true
        };
        let result = run(&mut on_bytes);
        if let Err(e) = result {
            let _ = sink.add(InstallProgressDto {
                completed_bytes: 0,
                total_bytes: total,
                error: Some(e.to_string()),
            });
        }
    });
}

/// 待下载部分的总大小（已存在的文件不计；幂等安装的进度从实际缺口起算）。
/// CAM++ 声纹模型随包分发后不再计入（安装只下载 sortformer）。
fn diar_bundle_pending_bytes() -> u64 {
    let cfg = asr_core::settings::load();
    let mut total = 0u64;
    if !model::diar_model_path().is_file() {
        total += asr_core::download::url_size(&model::diar_url(cfg.source, &cfg.mirror_base))
            .unwrap_or(0);
    }
    if !model::embedding_bundled()
        && !model::sherpa_diar_dir().join(model::SHERPA_EMBEDDING_FILE).is_file()
    {
        total += asr_core::download::url_size(model::SHERPA_EMBEDDING_URL).unwrap_or(0);
    }
    total
}

/// 安装说话人分离模型组合（sortformer ~175MB + CAM++ ~27MB），
/// 字节级进度经 `sink` 推送（后台线程，错误以 error 字段终态上报）。
pub fn install_diar_model(sink: StreamSink<InstallProgressDto>) -> anyhow::Result<()> {
    let total = diar_bundle_pending_bytes();
    spawn_install(total, sink, |on_bytes| {
        asr_core::download::download_diar_bundle(on_bytes)
    });
    Ok(())
}

/// 词级对齐模型是否已安装（可选增强，~1.1 GB）。
pub fn aligner_model_available() -> bool {
    model::aligner_model_path().is_file()
}

/// 安装词级对齐模型（qwen3_forced_aligner Q8 ~1.1GB，hf-mirror），
/// 字节级进度经 `sink` 推送。
pub fn install_aligner_model(sink: StreamSink<InstallProgressDto>) -> anyhow::Result<()> {
    let cfg = asr_core::settings::load();
    let total = if model::aligner_model_path().is_file() {
        0
    } else {
        asr_core::download::url_size(&model::aligner_url(cfg.source, &cfg.mirror_base))
            .unwrap_or(0)
    };
    spawn_install(total, sink, |on_bytes| {
        asr_core::download::download_aligner_model(on_bytes)
    });
    Ok(())
}

/// 最近一次转写的 SRT 字幕（无则空串）。
pub fn last_srt() -> String {
    LAST_SRT.lock().unwrap().clone()
}

/// 最近一次转写的 LRC 歌词（无则空串）。
pub fn last_lrc() -> String {
    LAST_LRC.lock().unwrap().clone()
}

/// 校对视图：带时间轴的文本行（高亮/点行跳转/导出同源）。
pub fn transcript_lines() -> Vec<TranscriptLineDto> {
    LAST_LINES.lock().unwrap().clone()
}

/// 校对行编辑：更新第 idx 行文本并重建 SRT/LRC（导出反映校对结果）。
/// 文本编辑不改动锚点（对后续拆分而言是近似值，可接受）。
pub fn update_transcript_line(index: u32, text: String) -> anyhow::Result<()> {
    {
        let mut proof = LAST_PROOF.lock().unwrap();
        let Some(line) = proof.get_mut(index as usize) else {
            return Err(anyhow::anyhow!("行索引越界：{index}"));
        };
        line.text = text;
    }
    sync_lines_from_proof();
    rebuild_exports_from_lines();
    Ok(())
}

/// 行级改说话人（diar 精度人工修正）。
pub fn update_line_speaker(index: u32, speaker: Option<String>) -> anyhow::Result<()> {
    {
        let mut proof = LAST_PROOF.lock().unwrap();
        let Some(line) = proof.get_mut(index as usize) else {
            return Err(anyhow::anyhow!("行索引越界：{index}"));
        };
        line.speaker = speaker;
    }
    sync_lines_from_proof();
    rebuild_exports_from_lines();
    Ok(())
}

/// 校准操作撤销栈（快照式：行文本/锚点/说话人整体快照；上限 200 防膨胀）。
static PROOF_UNDO: Mutex<Vec<Vec<asr_core::srt::ProofLine>>> = Mutex::new(Vec::new());

/// 压入当前行快照（Dart 在每次修改性操作——拆行/换说话人/防抖文本回写
/// 的每个编辑会话——之前调用）。
pub fn push_proof_snapshot() {
    let mut stack = PROOF_UNDO.lock().unwrap();
    if stack.len() >= 200 {
        stack.remove(0);
    }
    stack.push(LAST_PROOF.lock().unwrap().clone());
}

/// 撤销上一次校准操作：恢复最近快照（行/锚点/说话人整体回滚，跨行
/// 生效——TextField 内置的单行 undo 与此天然分层：其栈空时按键穿透）。
/// 栈空返回 false。
pub fn undo_proof_edit() -> bool {
    let snapshot = { PROOF_UNDO.lock().unwrap().pop() };
    match snapshot {
        Some(s) => {
            *LAST_PROOF.lock().unwrap() = s;
            sync_lines_from_proof();
            rebuild_exports_from_lines();
            true
        }
        None => false,
    }
}

/// 校准模式拆行：在第 index 行的 char_pos（Unicode 字符数，即光标处）
/// 拆为两行——分界时刻**吸附逐字锚点**（qwen3_forced_aligner 的真实字时刻，
/// 锚点间线性插值；无锚点退回字符比例），后半行挂 second_speaker。
pub fn split_transcript_line(
    index: u32,
    char_pos: u32,
    second_speaker: Option<String>,
) -> anyhow::Result<()> {
    {
        let mut proof = LAST_PROOF.lock().unwrap();
        if asr_core::srt::split_proof_line(
            &mut proof,
            index as usize,
            char_pos as usize,
            second_speaker,
        )
        .is_none()
        {
            return Err(anyhow::anyhow!("拆分位置无效（需在行内非端点处）"));
        }
    }
    sync_lines_from_proof();
    rebuild_exports_from_lines();
    Ok(())
}

/// 说话人重命名（如 SPEAKER_00 → "客服"；全局生效，导出同步）。
pub fn set_speaker_name(speaker: String, name: String) -> anyhow::Result<()> {
    speaker_names()
        .lock()
        .unwrap()
        .insert(speaker, name);
    rebuild_exports_from_lines();
    Ok(())
}

// ── 项目文件（校准工作的保存/续作）──────────────────────────────────────

/// 项目文件 v1：行（含逐字锚点）+ 原行快照（退出 diff 基准）+ 说话人
/// 显示名 + 音频路径/标题。JSON，扩展名 .asrproj。
#[derive(serde::Serialize, serde::Deserialize)]
struct ProjectFile {
    version: u32,
    audio_path: String,
    audio_title: String,
    /// 转写检测到的语言（重新对齐需要；旧项目无此字段则空）
    #[serde(default)]
    language: String,
    speaker_names: std::collections::HashMap<String, String>,
    lines: Vec<asr_core::srt::ProofLine>,
    original_lines: Vec<asr_core::srt::ProofLine>,
}

/// 保存项目到指定路径（.asrproj）。当前无校准内容时返回错误。
pub fn save_project(path: String) -> anyhow::Result<()> {
    let (proof, original) = {
        let p = LAST_PROOF.lock().unwrap().clone();
        let o = LAST_ORIGINAL_LINES.lock().unwrap().clone();
        (p, o)
    };
    if proof.is_empty() {
        return Err(anyhow::anyhow!("当前没有可保存的校准内容（先完成一次识别）"));
    }
    let project = ProjectFile {
        version: 1,
        audio_path: LAST_AUDIO_PATH.lock().unwrap().clone(),
        audio_title: LAST_AUDIO_TITLE.lock().unwrap().clone(),
        language: LAST_LANG.lock().unwrap().clone(),
        speaker_names: speaker_names().lock().unwrap().clone(),
        lines: proof,
        original_lines: original,
    };
    let json = serde_json::to_string_pretty(&project)
        .map_err(|e| anyhow::anyhow!("项目序列化失败：{e}"))?;
    std::fs::write(&path, json).map_err(|e| anyhow::anyhow!("项目写入失败：{e}"))?;
    Ok(())
}

/// 加载项目的结果（音频存在性由调用方处理提示与重选）。
pub struct LoadedProjectDto {
    pub audio_path: String,
    pub audio_exists: bool,
    pub line_count: u32,
}

/// 加载项目：恢复行/锚点/原行快照/说话人名到当前会话（SRT/LRC 同步重建）。
pub fn load_project(path: String) -> anyhow::Result<LoadedProjectDto> {
    let json = std::fs::read_to_string(&path).map_err(|e| anyhow::anyhow!("项目读取失败：{e}"))?;
    let project: ProjectFile =
        serde_json::from_str(&json).map_err(|e| anyhow::anyhow!("项目解析失败：{e}"))?;
    if project.version != 1 {
        return Err(anyhow::anyhow!("不支持的项目版本：v{}", project.version));
    }
    let count = project.lines.len() as u32;
    *LAST_ORIGINAL_LINES.lock().unwrap() = project.original_lines;
    set_proof_lines(project.lines);
    *speaker_names().lock().unwrap() = project.speaker_names;
    *LAST_AUDIO_PATH.lock().unwrap() = project.audio_path.clone();
    *LAST_AUDIO_TITLE.lock().unwrap() = project.audio_title;
    *LAST_LANG.lock().unwrap() = project.language.clone();
    rebuild_exports_from_lines();
    Ok(LoadedProjectDto {
        audio_exists: std::path::Path::new(&project.audio_path).is_file(),
        audio_path: project.audio_path,
        line_count: count,
    })
}

/// 项目加载后音频移动/重选时改指（保存项目时记录新路径）。
pub fn update_project_audio(path: String) {
    *LAST_AUDIO_PATH.lock().unwrap() = path.clone();
    if let Some(t) = std::path::Path::new(&path)
        .file_stem()
        .and_then(|s| s.to_str())
    {
        *LAST_AUDIO_TITLE.lock().unwrap() = t.to_string();
    }
    rebuild_exports_from_lines();
}

/// 逐行重新对齐当前项目：从 LAST_AUDIO_PATH 重新解码音频，对 LAST_PROOF
/// 每行（含编辑过的文本）重跑词级对齐——锚点重建、行起止精修。
/// 返回成功对齐的行数。需要对齐模型与已检测的语言（项目或转写记录）。
pub fn realign_project_lines() -> anyhow::Result<u32> {
    let audio = LAST_AUDIO_PATH.lock().unwrap().clone();
    if audio.is_empty() {
        return Err(anyhow::anyhow!("没有音频记录（先转写或加载项目）"));
    }
    let language = {
        let l = LAST_LANG.lock().unwrap().clone();
        if l.is_empty() { asr_core::settings::load().language } else { l }
    };
    let language = asr_core::languages::model_value(&language)
        .unwrap_or_else(|| "Chinese".to_string());
    if !model::aligner_model_path().is_file() {
        return Err(anyhow::anyhow!("对齐模型未安装（设置中可安装，约 1.1 GB）"));
    }
    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(&audio))
        .map_err(|e| anyhow::anyhow!("读取音频失败：{e}"))?;
    let settings = asr_core::settings::load();
    let backend = acpp_backend_name(&settings.backend);
    let device = DEVICE_ORDINAL.load(Ordering::SeqCst);
    let ok = {
        let mut proof = LAST_PROOF.lock().unwrap();
        refine_lines_with_aligner(
            &mut proof, &pcm, &language, backend, device, None, true,
        )
    };
    sync_lines_from_proof();
    rebuild_exports_from_lines();
    Ok(ok as u32)
}

/// 说话人显示名（项目加载后 UI 同步用）。
pub fn speaker_names_map() -> std::collections::HashMap<String, String> {
    speaker_names().lock().unwrap().clone()
}

/// 转写完成时的原始行快照（退出校准 diff 基准；项目加载后恢复）。
pub fn original_transcript_lines() -> Vec<TranscriptLineDto> {
    LAST_ORIGINAL_LINES
        .lock()
        .unwrap()
        .iter()
        .map(|l| TranscriptLineDto {
            start_sec: l.start_sec,
            end_sec: l.end_sec,
            speaker: l.speaker.clone(),
            text: l.text.clone(),
        })
        .collect()
}

/// 校对视图：波形峰值（0..1，每秒 buckets 个），按路径缓存。
pub fn waveform_peaks(path: String, buckets_per_sec: u32) -> Vec<f32> {
    {
        let cache = WAVE_CACHE.lock().unwrap();
        if cache.0 == path && !cache.1.is_empty() {
            return cache.1.clone();
        }
    }
    let pcm = match asr_core::audio::load_audio_16k_mono(std::path::Path::new(&path)) {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    let per = (16000 / buckets_per_sec.max(1)) as usize;
    let mut peaks = Vec::with_capacity(pcm.len() / per + 1);
    for chunk in pcm.chunks(per.max(1)) {
        let peak = chunk.iter().map(|x| x.abs()).fold(0.0f32, f32::max);
        peaks.push(peak.min(1.0));
    }
    // 归一化到全域最大值，视觉幅度稳定
    let max = peaks.iter().cloned().fold(0.0f32, f32::max).max(1e-6);
    for p in peaks.iter_mut() {
        *p /= max;
    }
    *WAVE_CACHE.lock().unwrap() = (path, peaks.clone());
    peaks
}

/// 外接 LLM 润色（OpenAI 兼容端点，配置见设置）。失败返回 Err，
/// 调用方保留原文并提示。
pub fn polish_text(text: String) -> anyhow::Result<String> {
    let settings = asr_core::settings::load();
    asr_core::llm::polish_text(&text, &settings).map_err(|e| anyhow::anyhow!("{e}"))
}

pub fn stop_transcribe() {
    TRANSCRIBE_CANCEL.store(true, Ordering::SeqCst);
}

/// Q8 模型是否已生成（设置页状态展示）。
pub fn q8_model_available() -> bool {
    model::model_dir().join("model.q8_0.gguf").exists()
}

/// 一键转换：-hf safetensors → audio.cpp 方言 Q8 GGUF（model.q8_0.gguf）。
/// 调用随应用分发的 audiocpp_gguf 工具（AppImage usr/bin 内），约 10 秒。
pub fn convert_model_to_q8() -> anyhow::Result<()> {
    let dir = model::model_dir();
    let input = dir.join("model.safetensors");
    let output = dir.join("model.q8_0.gguf");
    if !input.exists() {
        return Err(anyhow::anyhow!("未找到模型权重（model.safetensors），请先下载"));
    }
    if output.exists() {
        return Ok(()); // 幂等
    }
    let bin = find_audiocpp_gguf()?;
    let status = std::process::Command::new(&bin)
        .arg("--input").arg(&input)
        .arg("--output").arg(&output)
        .arg("--type").arg("q8_0")
        .status()
        .map_err(|e| anyhow::anyhow!("启动转换工具失败（{}）：{e}", bin.display()))?;
    if !status.success() {
        let _ = std::fs::remove_file(&output); // 清理半成品
        return Err(anyhow::anyhow!(
            "Q8 转换失败（exit {:?}），详情见应用日志", status.code()
        ));
    }
    Ok(())
}

fn find_audiocpp_gguf() -> anyhow::Result<std::path::PathBuf> {
    let bin_name = if cfg!(target_os = "windows") { "audiocpp_gguf.exe" } else { "audiocpp_gguf" };
    if let Ok(p) = std::env::var("AUDIOCPP_GGUF_BIN") {
        let p = std::path::PathBuf::from(p);
        if p.exists() {
            return Ok(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let sibling = exe
            .parent()
            .map(|d| d.join(bin_name))
            .filter(|p| p.exists());
        if let Some(p) = sibling {
            return Ok(p);
        }
    }
    // PATH 兜底（开发环境）
    Ok(std::path::PathBuf::from(bin_name))
}

#[cfg(test)]
mod undo_tests {
    use super::*;

    #[test]
    fn proof_undo_roundtrip() {
        {
            let mut proof = LAST_PROOF.lock().unwrap();
            *proof = vec![asr_core::srt::ProofLine {
                start_sec: 0.0,
                end_sec: 1.0,
                speaker: None,
                text: "a".to_string(),
                anchors: vec![],
            }];
        }
        push_proof_snapshot();
        update_transcript_line(0, "b".to_string()).unwrap();
        assert!(undo_proof_edit());
        assert_eq!(LAST_PROOF.lock().unwrap()[0].text, "a");
        assert!(!undo_proof_edit()); // 栈空
    }
}
