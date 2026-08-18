//! 词级对齐精修（qwen3_forced_aligner）：锚点回原文本、长行分段推进、
//! 逐行精修与顺序重铺。从 api/engine.rs 拆出——纯逻辑无 frb API，
//! 引擎句柄经 `api::engine::align_pcm`（pub(crate)）调用。

use crate::api::engine::align_pcm;

/// 镜像 audiocpp qwen3_forced_aligner 的 clean_token 字符保留规则。
/// 对齐器只返回清洗后的词（丢空格/标点），锚点 char_offset 契约却是
/// 原始行文本的 Unicode 字符位（含标点）——须把词映射回原文本偏移，
/// 否则含标点的行锚点整体错位、拆行插值随之偏移。
pub(crate) fn aligner_kept_char(c: char) -> bool {
    matches!(c,
        '\'' | 'A'..='Z' | 'a'..='z' | '0'..='9'
        | '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}'
        | '\u{20000}'..='\u{2A6DF}' | '\u{2A700}'..='\u{2B73F}'
        | '\u{2B740}'..='\u{2B81F}' | '\u{2B820}'..='\u{2CEAF}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{00C0}'..='\u{02AF}' | '\u{0370}'..='\u{03FF}'
        | '\u{0400}'..='\u{052F}' | '\u{0E00}'..='\u{0E7F}'
        | '\u{3040}'..='\u{30FF}' | '\u{AC00}'..='\u{D7AF}')
}

/// 词序列在原始文本「保留字符流」上顺序对位，返回每个词首字符的原始
/// 字符偏移。词流与文本清洗结果不一致时返回 None（调用方退回按词字符
/// 数累计的旧近似）。
pub(crate) fn anchor_offsets_for(
    text: &str,
    words: &[audiocpp_ffi::AlignedWord],
) -> Option<Vec<u32>> {
    let chars: Vec<char> = text.chars().collect();
    let stream: Vec<usize> = chars
        .iter()
        .enumerate()
        .filter(|(_, c)| aligner_kept_char(**c))
        .map(|(i, _)| i)
        .collect();
    let mut offsets = Vec::with_capacity(words.len());
    let mut cur = 0usize;
    for w in words {
        let wchars: Vec<char> = w.word.chars().collect();
        if cur + wchars.len() > stream.len() {
            return None;
        }
        for (k, wc) in wchars.iter().enumerate() {
            if chars[stream[cur + k]] != *wc {
                return None;
            }
        }
        offsets.push(stream[cur] as u32);
        cur += wchars.len();
    }
    Some(offsets)
}

/// 分段对齐的段文本上限（保留字符数）与音频窗长：对齐器在长音频上词
/// 时间戳系统性压扁（实测 29s 行的 45 字被挤在 12s 内；且音频装不下
/// 文本时不给任何信号，词被硬塞进段内，「外推检测」不可靠），必须按
/// 保守语速（2 字/秒）预切文本块、每块用短音频窗（短窗内对齐精确，
/// 实测 8-10s 段词时刻与真实吻合）。
pub(crate) const ALIGN_SEGMENT_CHARS: usize = 30;
pub(crate) const ALIGN_WINDOW_SEC: f64 = 14.0;

/// 把文本切成每块 ≤max_chars 保留字符的块（切点吸附句读，禁则处理：
/// 下一块不以标点开头）。
pub(crate) fn split_align_chunks(text: &str, max_chars: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let total_kept = chars.iter().filter(|c| aligner_kept_char(**c)).count();
    if total_kept <= max_chars {
        return vec![text.to_string()];
    }
    let parts = total_kept.div_ceil(max_chars);
    let per = total_kept / parts;
    let mut out = Vec::with_capacity(parts);
    let mut pos = 0usize;
    for p in 0..parts {
        // 目标切点按保留字符比例；落在原文本字符位上
        let kept_target = per * (p + 1);
        let mut kept_seen = 0usize;
        let mut cut = chars.len();
        for (i, c) in chars.iter().enumerate().skip(pos) {
            if kept_seen >= kept_target {
                cut = i;
                break;
            }
            if aligner_kept_char(*c) {
                kept_seen += 1;
            }
        }
        if p + 1 < parts {
            // 右移吸附句读（最多 8 字），再并入连续标点（禁则）
            while cut < chars.len() && !"。，？！ ,、；：".contains(*chars.get(cut).unwrap_or(&' ')) && kept_seen < per + 8 {
                if aligner_kept_char(chars[cut]) {
                    kept_seen += 1;
                }
                cut += 1;
            }
            while cut < chars.len() && "。，？！、；：…— ,.!?;:".contains(chars[cut]) {
                cut += 1;
            }
        }
        let piece: String = chars[pos..cut.min(chars.len())].iter().collect();
        if !piece.trim().is_empty() {
            out.push(piece);
        }
        pos = cut.min(chars.len());
        if pos >= chars.len() {
            break;
        }
    }
    // 兜底：比例切块漏了尾部（吸附越界等）
    if pos < chars.len() {
        let tail: String = chars[pos..].iter().collect();
        if !tail.trim().is_empty() {
            out.push(tail);
        }
    }
    out
}

/// 单行对齐（长行分段推进）：文本按保守语速预切块，块 i 在「上一块
/// 末词时刻起的 14s 短窗」内对齐（窗随实际语音进度推进）。返回词的
/// 绝对时刻；空 = 对齐失败。
pub(crate) fn align_line_segmented(
    pcm: &[f32],
    base: f64,
    text: &str,
    language: &str,
    backend: &str,
    device: u32,
) -> Vec<audiocpp_ffi::AlignedWord> {
    let mut accepted: Vec<audiocpp_ffi::AlignedWord> = Vec::new();
    let mut rel = 0.0f64; // 窗起点相对切片
    for chunk in split_align_chunks(text, ALIGN_SEGMENT_CHARS) {
        let s = (rel * 16000.0) as usize;
        let e = (((rel + ALIGN_WINDOW_SEC) * 16000.0) as usize).min(pcm.len());
        if e <= s + 8000 {
            break;
        }
        let words = match align_pcm(&pcm[s..e], &chunk, language, backend, device) {
            Ok(w) if !w.is_empty() => w,
            _ => break,
        };
        let seg_end = rel + words.last().unwrap().end_sec;
        for w in &words {
            accepted.push(audiocpp_ffi::AlignedWord {
                start_sec: base + rel + w.start_sec,
                end_sec: base + rel + w.end_sec,
                word: w.word.clone(),
                confidence: w.confidence,
            });
        }
        rel = seg_end;
    }
    accepted
}

/// 逐行对齐精修：对每行取音频切片 + 行文本跑对齐——锚点（真实字时刻）
/// + 行起止收敛到首末字真实时刻。逐行容错（单行失败保留粗时间/空锚点）。
///
/// `sequential`：粗时间不可信（存量坏项目，行 start 塌 0、区间整体前移，
/// 直接按粗区间切片会截掉行尾）时按「前一行末词 + 本行时长」顺序重铺
/// 切片；转写完成路径粗时间来自真实 delta 区间，用粗区间 + 小余量。
///
/// 返回成功行数。
pub(crate) fn refine_lines_with_aligner(
    proof: &mut [asr_core::srt::ProofLine],
    pcm: &[f32],
    language: &str,
    backend: &str,
    device: u32,
    progress: Option<&dyn Fn(usize, usize)>,
    sequential: bool,
) -> usize {
    let total = proof.len();
    let mut ok_count = 0usize;
    let mut failures = 0usize;
    let mut cur = 0.0f64; // 上一行末词时刻（sequential 重铺的游标）
    for (idx, line) in proof.iter_mut().enumerate() {
        if let Some(cb) = progress {
            cb(idx, total);
        }
        if line.text.trim().is_empty() {
            continue;
        }
        let dur = (line.end_sec - line.start_sec).max(0.0);
        // 切片起点 = 对齐器返回时间的基准（相对切片，须加回偏移）。
        let base = if sequential {
            // 坏数据粗 start 弃用：上一行末词即语音边界（对齐器容忍少量
            // 前置无关音频，但前置大段语音会把首词吸到窗起点，实测回看
            // 2s 时首词贴 0.08s——回看必须极小）。
            (cur - 0.3).max(0.0)
        } else {
            (line.start_sec - 0.2).max(0.0)
        };
        let end_guess = if sequential {
            line.end_sec.max(cur + dur * 1.2 + 5.0)
        } else {
            line.end_sec + 1.0 // 块尾截断保险
        };
        let s = (base * 16000.0) as usize;
        let e = ((end_guess * 16000.0) as usize).min(pcm.len());
        if e <= s {
            continue;
        }
        let words = align_line_segmented(
            &pcm[s..e],
            base,
            &line.text,
            language,
            backend,
            device,
        );
        if words.is_empty() {
            failures += 1;
            cur += dur; // 失败行时长仍可信，游标按粗时长推进
        } else {
            // 锚点偏移映射回原始文本字符位（含标点）；对位失败退回
            // 按词字符数累计的旧近似（不含空格标点，会错位）。
            let offsets = anchor_offsets_for(&line.text, &words);
            let mut anchors = Vec::with_capacity(words.len());
            let mut chars = 0u32;
            let mut last_end = base;
            for (wi, w) in words.iter().enumerate() {
                last_end = w.end_sec;
                anchors.push(asr_core::srt::WordAnchor {
                    char_offset: offsets.as_ref().map_or(chars, |o| o[wi]),
                    start_sec: w.start_sec,
                });
                chars += w.word.chars().count() as u32;
            }
            line.start_sec = words[0].start_sec;
            line.end_sec = last_end;
            line.anchors = anchors;
            cur = last_end;
            ok_count += 1;
        }
    }
    if failures > 0 {
        eprintln!("[align] {failures} 行对齐失败（保留块级时间/空锚点）");
    }
    ok_count
}


#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str) -> audiocpp_ffi::AlignedWord {
        audiocpp_ffi::AlignedWord {
            start_sec: 0.0,
            end_sec: 0.1,
            word: text.to_string(),
            confidence: 0.0,
        }
    }

    #[test]
    fn anchor_offsets_map_back_to_original_text_positions() {
        // 前导空格 + 标点：清洗后词序列须映射回原始字符位
        // （' 您好，请' → 您@1 好@2 请@4，而非 0/1/2）
        let text = " 您好，请问有什么可以帮到您？";
        let words: Vec<_> = ["您", "好", "请", "问", "有", "什", "么", "可", "以", "帮", "到", "您"]
            .iter().map(|w| word(w)).collect();
        let offsets = anchor_offsets_for(text, &words).unwrap();
        assert_eq!(
            offsets,
            vec![1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
        );
    }

    #[test]
    fn anchor_offsets_english_and_emoji() {
        // 英文词跨标点对位 + emoji（非保留字符）跳过
        let text = "OK，next😀 time";
        let words: Vec<_> = ["OK", "next", "time"].iter().map(|w| word(w)).collect();
        let offsets = anchor_offsets_for(text, &words).unwrap();
        assert_eq!(offsets, vec![0, 3, 9]);
    }

    #[test]
    fn split_align_chunks_respects_kept_char_budget() {
        // 50 保留字符 → 2 块；切点吸附句读允许最多多带 8 个保留字符
        let text = " 好，现在我来看一下今天的日期。今天是几号了？就这个问题我想咨询一下你们。 那个，我上周跟你们有一笔订单。 关于这订单";
        let chunks = split_align_chunks(text, ALIGN_SEGMENT_CHARS);
        assert_eq!(chunks.len(), 2);
        let kept = |t: &str| t.chars().filter(|c| aligner_kept_char(*c)).count();
        assert!(chunks.iter().all(|c| kept(c) <= ALIGN_SEGMENT_CHARS + 8));
        // 块拼回 ≈ 原文本（切点吸附句读只会在块边界重分标点）
        assert_eq!(chunks.concat(), text);
        // 下一块不以标点开头（禁则）
        for w in chunks.windows(2) {
            assert!(!"。，？！、；：".contains(w[1].chars().next().unwrap()));
        }
    }

    #[test]
    fn split_align_chunks_short_text_single() {
        assert_eq!(split_align_chunks("你好，世界。", 30), vec!["你好，世界。"]);
    }

    #[test]
    fn anchor_offsets_mismatch_falls_back() {
        // 词流与文本不一致 → None（调用方退回旧累计法）
        let text = "你好";
        let words: Vec<_> = ["你", "世", "界"].iter().map(|w| word(w)).collect();
        assert!(anchor_offsets_for(text, &words).is_none());
    }
}

#[cfg(test)]
mod manual_align_check {
    use super::*;

    /// 手动端到端验证（需真实模型与音频，--ignored 单独跑）：
    /// 用用户项目的一行真实文本+切片跑对齐器，检查词序列能否与原始文本
    /// 保留字符流对位、词时刻是否单调合理。
    #[test]
    #[ignore]
    fn short_audio_long_text() {
        let audio = std::env::var("SIMPLE_ASR_TEST_AUDIO").unwrap_or_default();
        if audio.is_empty() {
            eprintln!("跳过：未设置 SIMPLE_ASR_TEST_AUDIO");
            return;
        }
        let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(&audio)).unwrap();
        // 通用长句占位：验证「短音频 + 超长文本」时尾部词外推特征
        //（实际验证时应换成音频 8.6s 起的真实语句）
        let text = " 好，现在我来看一下今天的日期。今天是几号了？就这个问题我想咨询一下你们。 那个，我上周跟你们有一笔订单。 关于这订单";
        let s = (8.64 * 16000.0) as usize;
        let e = (18.64 * 16000.0) as usize;
        let words = align_pcm(&pcm[s..e], text, "Chinese", "auto", 0).unwrap();
        for w in &words {
            println!("  {:.3}-{:.3} {}", w.start_sec, w.end_sec, w.word);
        }
    }

    #[test]
    #[ignore]
    fn real_align_on_audio() {
        let audio = std::env::var("SIMPLE_ASR_TEST_AUDIO").unwrap_or_default();
        if audio.is_empty() {
            eprintln!("跳过：未设置 SIMPLE_ASR_TEST_AUDIO");
            return;
        }
        let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(&audio)).unwrap();
        // 文本须改为 SIMPLE_ASR_TEST_AUDIO 开头的真实语句（此处为客服
        // 开场白占位示例）——约束对齐要求文本与音频内容对应
        let text = " 您好，请问有什么可以帮到您？";
        let base = 0.0f64;
        let dur = 16.0f64;
        let s = (base * 16000.0) as usize;
        let e = ((base + dur) * 16000.0) as usize;
        let words = align_pcm(&pcm[s..e], text, "Chinese", "auto", 0).unwrap();
        println!("words: {}", words.len());
        for w in words.iter().take(40) {
            println!("  {:.3}-{:.3} {}", w.start_sec, w.end_sec, w.word);
        }
        let offsets = anchor_offsets_for(text, &words);
        println!("mapped offsets: {:?}", offsets.is_some());
        // 单调性
        let mut mono = true;
        for w in words.windows(2) {
            if w[1].start_sec < w[0].start_sec - 1e-9 {
                mono = false;
            }
        }
        println!("monotonic: {mono}");
        assert!(offsets.is_some(), "词序列与文本保留字符流对位失败");
    }
}

#[cfg(test)]
mod manual_realign_check {
    use super::*;

    /// 手动端到端（--ignored）：旧坏项目（start 塌 0）前 12 行真实验证
    /// sequential 重铺 + 分段对齐——修复后行时间单调推进、不塌 0、
    /// 锚点全部映射回原始文本字符位。
    #[test]
    #[ignore]
    fn sequential_refine_on_legacy_project() {
        let audio = std::env::var("SIMPLE_ASR_TEST_AUDIO").unwrap_or_default();
        if audio.is_empty() {
            eprintln!("跳过：未设置 SIMPLE_ASR_TEST_AUDIO");
            return;
        }
        let proj = std::env::var("SIMPLE_ASR_TEST_PROJECT").unwrap_or_default();
        if proj.is_empty() {
            eprintln!("跳过：未设置 SIMPLE_ASR_TEST_PROJECT");
            return;
        }
        let raw = std::fs::read_to_string(proj).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let mut proof: Vec<asr_core::srt::ProofLine> = Vec::new();
        for l in v["lines"].as_array().unwrap().iter().take(12) {
            proof.push(asr_core::srt::ProofLine {
                start_sec: l["start_sec"].as_f64().unwrap(),
                end_sec: l["end_sec"].as_f64().unwrap(),
                speaker: l["speaker"].as_str().map(|s| s.to_string()),
                text: l["text"].as_str().unwrap().to_string(),
                anchors: vec![],
            });
        }
        let pcm = asr_core::audio::load_audio_16k_mono(std::path::Path::new(&audio)).unwrap();
        let n = proof.len();
        let ok = refine_lines_with_aligner(&mut proof, &pcm, "Chinese", "auto", 0, None, true);
        println!("ok={ok}/{n}");
        let mut prev_end = 0.0f64;
        for (i, l) in proof.iter().enumerate() {
            println!(
                "[{i:2}] {:8.2}-{:8.2} anchors={:3} {}",
                l.start_sec,
                l.end_sec,
                l.anchors.len(),
                l.text.chars().take(12).collect::<String>()
            );
            assert!(l.start_sec >= prev_end - 6.0, "行 {i} 大幅回退");
            assert!(l.end_sec > l.start_sec, "行 {i} 非正时长");
            prev_end = prev_end.max(l.end_sec);
        }
        assert!(ok as usize >= n * 3 / 4, "成功率过低 {ok}/{n}");
    }
}

