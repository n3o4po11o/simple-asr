//! audiocpp 引擎冒烟：加载模型（-hf / Q8 GGUF）+ 转写一段音频。
//! Usage: engine-smoke <audio> [session_sec] [backend] [model-path]
//! download / probe 子命令沿用（asr-core 层，与引擎无关）。

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();
    let audio = std::env::args().nth(1).expect("usage: engine-smoke <audio> [mode] ...");
    let mode = std::env::args().nth(2).unwrap_or_default();
    let dir = asr_core::model::model_dir();
    println!("model dir : {}", dir.display());
    println!("audio     : {audio}");

    // download 模式：下载 -hf 快照（ModelScope）
    if mode == "download" {
        let started = std::time::Instant::now();
        let dir = asr_core::download::download_model(
            asr_core::model::ModelSource::ModelScope,
            |p| {
                println!("  {}/{} {} ({:.0}%)", p.completed_files, p.total_files,
                    p.current_file, p.fraction() * 100.0);
                true
            },
        )
        .expect("download failed");
        println!("downloaded to {} in {:.0}s", dir.display(), started.elapsed().as_secs_f32());
        return Ok(());
    }

    // probe 模式：逐包统计解码行为（验证重采样/时长）
    if mode == "probe" {
        let samples = asr_core::audio::load_audio_16k_mono(std::path::Path::new(&audio))?;
        println!("samples   : {} ({:.1}s @16k)", samples.len(), samples.len() as f32 / 16000.0);
        return Ok(());
    }

    if mode == "stream" {
        return stream_main(&audio);
    }
    if mode == "diar" {
        return diar_main(&audio);
    }
    if mode == "shdiar" {
        return sherpa_diar_main(&audio);
    }
    if mode == "hydiar" {
        return hybrid_diar_main(&audio);
    }
    if mode == "align" {
        return align_main(&audio);
    }
    acpp_main(&audio)
}

/// 混合分离模式：engine-smoke <audio> hydiar [num_speakers] [threshold]
/// sortformer 分段（重叠感知）→ CAM++ 逐段声纹 → 全局聚类统一 ID。
/// 模型用 asr-core 路径（sortformer gguf + sherpa campplus）。
fn hybrid_diar_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let num_speakers: u32 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(2);
    let threshold: f32 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(0.5);
    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    println!("audio     : {:.1}s，k={num_speakers} thr={threshold}", pcm.len() as f64 / 16000.0);

    // 1) sortformer 分段（Metal，快）
    let backend = if cfg!(target_os = "macos") { "metal" } else { "vulkan" };
    let t0 = std::time::Instant::now();
    let diar = audiocpp_ffi::AcppModel::load(&asr_core::model::diar_model_path(), "sortformer_diar")
        .map_err(|e| e.to_string())?;
    let turns = diar.diarize(&pcm, backend, 0, 4).map_err(|e| e.to_string())?;
    let turns: Vec<_> = turns.into_iter().filter(|t| t.end_sec - t.start_sec >= 0.5).collect();
    println!("sortformer: {:.1}s，{} 段", t0.elapsed().as_secs_f64(), turns.len());

    // 2) CAM++ 逐段声纹（长段做聚类中心，短段噪声大后续按最近质心归类）
    let t1 = std::time::Instant::now();
    let emb_model = asr_core::model::sherpa_diar_dir()
        .join(asr_core::model::SHERPA_EMBEDDING_FILE);
    let embedder = sherpa_ffi::SpeakerEmbedder::new(&emb_model, 4).map_err(|e| e.to_string())?;
    const MIN_CENTER_SEC: f64 = 1.5;
    let mut centers = Vec::new();
    let mut center_turns = Vec::new();
    let mut short_turns = Vec::new();
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
    println!("embed     : {:.1}s，中心 {} 段（≥{MIN_CENTER_SEC}s）+ 短 {} 段",
        t1.elapsed().as_secs_f64(), centers.len(), short_turns.len());

    // 3) 聚类中心段 → 短段按最近质心归类
    let t2 = std::time::Instant::now();
    let center_labels = sherpa_ffi::cluster_embeddings(&centers, num_speakers as usize, threshold);
    let k = center_labels.iter().cloned().max().map_or(0, |m| m + 1);
    // 质心（L2 归一化）
    let mut centroids = vec![vec![0.0f32; embedder.dim()]; k];
    let mut counts = vec![0usize; k];
    for (v, &l) in centers.iter().zip(&center_labels) {
        let nrm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        for (c, x) in centroids[l].iter_mut().zip(v) {
            *c += x / nrm;
        }
        counts[l] += 1;
    }
    let mut all: Vec<(&&audiocpp_ffi::SpeakerSegment, usize)> = center_turns
        .iter()
        .zip(&center_labels)
        .map(|(t, &l)| (t, l))
        .collect();
    for (t, v) in &short_turns {
        let nrm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        let mut best = (0usize, f32::INFINITY);
        for (l, c) in centroids.iter().enumerate() {
            let sim: f32 = c.iter().zip(v).map(|(a, b)| a * b / nrm).sum();
            let d = 1.0 - sim;
            if d < best.1 {
                best = (l, d);
            }
        }
        all.push((t, best.0));
    }
    all.sort_by_key(|(t, _)| (t.start_sec * 1000.0) as u64);
    println!("cluster   : {:.2}s，{k} 簇", t2.elapsed().as_secs_f64());
    let mut cnt: std::collections::BTreeMap<usize, (usize, f64)> = std::collections::BTreeMap::new();
    for (t, l) in &all {
        let e = cnt.entry(*l).or_insert((0, 0.0));
        e.0 += 1;
        e.1 += t.end_sec - t.start_sec;
        println!("  [{:7.2} - {:7.2}] SPEAKER_{l:02}（原 {}）", t.start_sec, t.end_sec, t.speaker);
    }
    println!("── 簇统计 ──");
    for (l, (c, d)) in &cnt {
        println!("  SPEAKER_{l:02}: {c} 段 / {d:.0} 秒");
    }
    Ok(())
}

/// 词级对齐模式：engine-smoke <audio> align <aligner.gguf> [backend]
/// 先离线转写取全文，再用 qwen3_forced_aligner 对齐同一音频与文本。
fn align_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let aligner = std::env::args()
        .nth(3)
        .unwrap_or_else(|| {
            asr_core::model::models_root()
                .join("qwen3-forced-aligner-0.6b-q8_0.gguf")
                .to_string_lossy()
                .into_owned()
        });
    let backend = std::env::args().nth(4).unwrap_or_else(|| {
        if cfg!(target_os = "macos") { "metal".into() } else { "vulkan".into() }
    });

    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    println!("audio     : {:.1}s, backend {backend}", pcm.len() as f64 / 16000.0);

    // 1) 离线转写拿权威全文 + 语言
    let asr = audiocpp_ffi::AcppModel::load(&asr_core::model::model_dir(), "qwen3_asr")
        .map_err(|e| e.to_string())?;
    let t0 = std::time::Instant::now();
    let (text, lang) = asr.transcribe(&pcm, &backend, 0, 4, "")?;
    println!("asr       : {:.1}s，{} 字符，语言 {lang}", t0.elapsed().as_secs_f64(), text.chars().count());

    // 2) 词级对齐
    let m = audiocpp_ffi::AcppModel::load(std::path::Path::new(&aligner), "qwen3_forced_aligner")
        .map_err(|e| e.to_string())?;
    let t1 = std::time::Instant::now();
    let words = m.align(&pcm, &text, &lang, &backend, 0, 4)?;
    println!("align     : {:.1}s，{} 词", t1.elapsed().as_secs_f64(), words.len());
    for w in words.iter().take(10) {
        println!("  [{:7.2} - {:7.2}] {} conf={:.2}", w.start_sec, w.end_sec, w.word, w.confidence);
    }
    if words.len() > 10 {
        println!("  …（共 {} 词）", words.len());
    }
    Ok(())
}

/// sherpa-onnx 说话人分离模式：engine-smoke <audio> shdiar [模型目录] [num_speakers]
/// 模型目录默认 ~/Library/Caches/simple-asr/models/sherpa-diar（含
/// sherpa-onnx-pyannote-segmentation-3-0/model.onnx 与 campplus onnx）。
fn sherpa_diar_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let models = std::env::args().nth(3).unwrap_or_else(|| {
        asr_core::model::models_root().join("sherpa-diar").to_string_lossy().into_owned()
    });
    let num_speakers: u32 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(0);
    let threshold: f32 = std::env::args().nth(5).and_then(|s| s.parse().ok()).unwrap_or(0.5);
    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    let dur = pcm.len() as f64 / 16000.0;
    println!("audio     : {dur:.1}s，speakers={num_speakers}(0=自动) threshold={threshold}");

    let d = sherpa_ffi::SherpaDiarization::new(&sherpa_ffi::DiarizationParams {
        segmentation_model: std::path::PathBuf::from(format!("{models}/sherpa-onnx-pyannote-segmentation-3-0/model.onnx")),
        embedding_model: std::path::PathBuf::from(format!("{models}/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")),
        num_speakers,
        threshold,
        num_threads: 4,
    })
    .map_err(|e| e.to_string())?;

    let t0 = std::time::Instant::now();
    let turns = d.process(&pcm).map_err(|e| e.to_string())?;
    println!("sherpa    : {:.1}s，{} 段", t0.elapsed().as_secs_f64(), turns.len());
    for t in &turns {
        println!("  [{:6.2} - {:6.2}] SPEAKER_{:02}", t.start_sec, t.end_sec, t.speaker);
    }
    Ok(())
}

/// 说话人分离模式：engine-smoke <audio> diar <diar-model.gguf> [backend]
/// 流水线：sortformer 分窗分离 → 流式 ASR（增量带音频时间区间）→
/// 重叠对齐合并 → 输出「[说话人] 文本」。
fn diar_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let diar_model = std::env::args()
        .nth(3)
        .expect("usage: engine-smoke <audio> diar <diar-model.gguf> [backend]");
    let backend = std::env::args().nth(4).unwrap_or_else(|| {
        if cfg!(target_os = "macos") { "metal".into() } else { "vulkan".into() }
    });

    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    let dur = pcm.len() as f64 / 16000.0;
    println!("audio     : {dur:.1}s, backend {backend}");

    // 1) 说话人分离
    let t0 = std::time::Instant::now();
    let diar = audiocpp_ffi::AcppModel::load(std::path::Path::new(&diar_model), "sortformer_diar")
        .map_err(|e| e.to_string())?;
    let turns = diar.diarize(&pcm, &backend, 0, 4).map_err(|e| e.to_string())?;
    println!("diar      : {:.1}s，{} 段", t0.elapsed().as_secs_f64(), turns.len());
    for t in &turns {
        println!("  [{:6.2} - {:6.2}] {}", t.start_sec, t.end_sec, t.speaker);
    }

    // 2) 流式 ASR：每秒 push，增量文本记时间区间 [prev_end, now]
    let asr = audiocpp_ffi::AcppModel::load(&asr_core::model::model_dir(), "qwen3_asr")
        .map_err(|e| e.to_string())?;
    let stream = asr.start_stream(&backend, 0, 4, "", 5.0, pcm.len())
        .map_err(|e| e.to_string())?;
    let mut pieces: Vec<(f64, f64, String)> = Vec::new();
    let mut t_pos = 0.0f64;
    let mut t_prev_text_end = 0.0f64;
    for chunk in pcm.chunks(16000) {
        let ev = stream.push(chunk).map_err(|e| e.to_string())?;
        if let Some(delta) = ev.text {
            pieces.push((t_prev_text_end, t_pos + 1.0, delta));
            t_prev_text_end = t_pos + 1.0;
        }
        t_pos += chunk.len() as f64 / 16000.0;
    }
    let (_final_text, lang) = stream.finish().map_err(|e| e.to_string())?;

    // 3) 重叠对齐：每段文本找覆盖最大的说话人段
    let speaker_at = |a: f64, b: f64| -> String {
        let mut best = ("?".to_string(), 0.0f64);
        for t in &turns {
            let ov = (t.end_sec.min(b) - t.start_sec.max(a)).max(0.0);
            if ov > best.1 {
                best = (t.speaker.clone(), ov);
            }
        }
        best.0
    };
    let mut out = String::new();
    let mut cur_spk = String::new();
    for (a, b, text) in &pieces {
        let spk = speaker_at(*a, *b);
        if spk != cur_spk {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(&format!("[{spk}] "));
            cur_spk = spk;
        }
        out.push_str(text);
    }
    println!("language  : {lang}");
    println!("==== 带说话人转写 ====");
    println!("{out}");
    Ok(())
}

/// 流式模式：engine-smoke <audio> stream [backend] [delta_sec]
/// 每 1 秒音频 push 一次，验证增量事件与最终全文。
fn stream_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let backend = std::env::args().nth(3).unwrap_or_else(|| {
        if cfg!(target_os = "macos") { "metal".into() } else { "vulkan".into() }
    });
    let delta_sec: f64 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let model = asr_core::model::model_dir();
    println!("engine    : audio.cpp (FFI streaming)");
    println!("backend   : {backend}, delta {delta_sec}s");

    let m = audiocpp_ffi::AcppModel::load(&model, "qwen3_asr").map_err(|e| e.to_string())?;
    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    println!("samples   : {} ({:.1}s @16k)", pcm.len(), pcm.len() as f32 / 16000.0);

    let t0 = std::time::Instant::now();
    let stream = m.start_stream(&backend, 0, 4, "", delta_sec, pcm.len()).map_err(|e| e.to_string())?;
    let mut live = String::new();
    let mut n_events = 0usize;
    for chunk in pcm.chunks(16000) {
        let ev = stream.push(chunk).map_err(|e| e.to_string())?;
        if let Some(delta) = ev.text {
            n_events += 1;
            live.push_str(&delta);
            println!("  [Δ{}] +{} → 累计 {}", n_events, delta.chars().count(), live.chars().count());
        }
    }
    let (final_text, lang) = stream.finish().map_err(|e| e.to_string())?;
    println!("事件数    : {n_events}，收尾全文 {} 字符（live 累计 {}）",
        final_text.chars().count(), live.chars().count());
    println!("elapsed   : {:.2}s ({:.1}x 实时)", t0.elapsed().as_secs_f32(),
        pcm.len() as f32 / 16000.0 / t0.elapsed().as_secs_f32());
    println!("language  : {lang}");
    println!("TEXT      : {final_text}");
    Ok(())
}

/// audiocpp 转写：audio.cpp 引擎（FFI 直连）。
/// 会话块默认 300s——audio.cpp 内部自带 VAD 智能分块，大块=边界更少、
/// 覆盖率更高；显存由其内部分块约束。
fn acpp_main(audio: &str) -> Result<(), Box<dyn std::error::Error>> {
    let started = std::time::Instant::now();
    let session_sec: f32 = std::env::args()
        .nth(3)
        .and_then(|s| s.parse().ok())
        .unwrap_or(300.0);
    let backend = std::env::args().nth(4).unwrap_or_else(|| "vulkan".into());
    let model = std::env::args().nth(5).unwrap_or_else(|| {
        asr_core::model::model_dir().to_string_lossy().into_owned()
    });
    println!("engine    : audio.cpp (FFI)");
    println!("model     : {model}");
    println!("backend   : {backend}, session {session_sec}s");

    let model = audiocpp_ffi::AcppModel::load(std::path::Path::new(&model), "qwen3_asr")
        .map_err(|e| e.to_string())?;
    println!("model open: {:.1}s (懒加载，权重首推理时上 GPU)",
        started.elapsed().as_secs_f32());

    let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(audio))?;
    println!("samples   : {} ({:.1}s @16k)", pcm.len(), pcm.len() as f32 / 16000.0);

    let cs = (session_sec * 16000.0) as usize;
    let mut accumulated = String::new();
    let mut detected = String::new();
    let t0 = std::time::Instant::now();
    let mut n = 0usize;
    for chunk in pcm.chunks(cs.max(1)) {
        let r = model.transcribe(chunk, &backend, 0, 4, "")?;
        n += 1;
        if !r.0.is_empty() {
            if !r.1.is_empty() {
                detected = r.1.clone();
            }
            if !accumulated.is_empty()
                && accumulated.chars().last().is_some_and(|c| c.is_ascii_alphanumeric())
                && r.0.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
            {
                accumulated.push(' ');
            }
            accumulated.push_str(&r.0);
        }
        println!("  [块 {n}] +{} (累计 {})", r.0.chars().count(), accumulated.chars().count());
    }
    println!("elapsed   : {:.2}s ({:.1}x 实时)", t0.elapsed().as_secs_f32(),
        pcm.len() as f32 / 16000.0 / t0.elapsed().as_secs_f32());
    println!("language  : {detected}");
    println!("chars     : {}", accumulated.chars().count());
    println!("TEXT      : {accumulated}");
    Ok(())
}
