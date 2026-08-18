//! 字幕/歌词导出：流式增量（带音频时间区间与可选说话人）→ SRT（播放器
//! 字幕）与 LRC（歌词式逐行时间轴）。
//!
//! 一条流式增量（默认 5 秒节奏）≈ 一条字幕，符合常见密度；文本过长时按
//! 字符比例在区间内再切分（切点对齐句读），两种格式共用该切分。

use serde::{Deserialize, Serialize};

/// 一条字幕素材：音频区间（秒）+ 文本（已含 [说话人] 前缀则原样保留）。
pub struct Cue {
    pub start_sec: f64,
    pub end_sec: f64,
    pub text: String,
}

/// 单条字幕的目标长度上限（超长按比例切分，最短 1 秒一条）。
const MAX_CUE_CHARS: usize = 32;

/// 共享的行切分：每条 Cue → 一或多条 (start, end, text) 行。
fn split_cue_lines(cue: &Cue) -> Vec<(f64, f64, String)> {
    let text = cue.text.trim();
    if text.is_empty() {
        return Vec::new();
    }
    let total = text.chars().count();
    let span = (cue.end_sec - cue.start_sec).max(0.2);
    if total <= MAX_CUE_CHARS {
        return vec![(cue.start_sec, cue.end_sec, text.to_string())];
    }
    // 按字符比例切分；在切点附近的句读处对齐
    let parts = total.div_ceil(MAX_CUE_CHARS);
    let per = span / parts as f64;
    let chars: Vec<char> = text.chars().collect();
    let mut lines = Vec::with_capacity(parts);
    let mut pos = 0usize;
    for p in 0..parts {
        let target = total * (p + 1) / parts;
        let mut cut = target.min(total);
        if p + 1 < parts {
            // 切点右移到最近的句读/空格（最多多带 8 字）
            while cut < total && cut < target + 8 && !"。，？！ ,、".contains(chars[cut]) {
                cut += 1;
            }
            cut = cut.min(total);
            // 禁则处理：连续标点（？！……）并入当前行，下一行不以标点开头
            while cut < total && "。，？！、；：…— ,.!?;:".contains(chars[cut]) {
                cut += 1;
            }
            cut = cut.min(target + MAX_CUE_CHARS + 8).min(total);
        }
        let piece: String = chars[pos..cut].iter().collect();
        let s = cue.start_sec + per * p as f64;
        let e = cue.start_sec + per * (p + 1) as f64;
        lines.push((s, e.max(s + 1.0), piece.trim().to_string()));
        pos = cut;
    }
    lines
}

/// 供校对视图复用的行切分（与 SRT/LRC 完全同源）。
pub fn split_cue_lines_pub(cue: &Cue) -> Vec<(f64, f64, String)> {
    split_cue_lines(cue)
}

pub fn build_srt(cues: &[Cue]) -> String {
    let mut out = String::new();
    let mut idx = 1usize;
    for cue in cues {
        for (s, e, text) in split_cue_lines(cue) {
            push_cue(&mut out, &mut idx, s, e, &text);
        }
    }
    out
}

/// LRC 歌词（[mm:ss.xx]文本 逐行时间轴，音乐播放器/歌词组件直接可用）。
/// `title` 可选写入 [ti:] 头。
pub fn build_lrc(cues: &[Cue], title: Option<&str>) -> String {
    let mut out = String::new();
    if let Some(t) = title {
        if !t.is_empty() {
            out.push_str(&format!("[ti:{t}]\n"));
        }
    }
    for cue in cues {
        for (s, _, text) in split_cue_lines(cue) {
            out.push_str(&format!("[{}]{}\n", fmt_lrc_ts(s), text));
        }
    }
    out
}

fn fmt_lrc_ts(sec: f64) -> String {
    let cs = (sec * 100.0).round() as u64;
    format!("{:02}:{:02}.{:02}", cs / 6000, cs / 100 % 60, cs % 100)
}

fn push_cue(out: &mut String, idx: &mut usize, s: f64, e: f64, text: &str) {
    out.push_str(&format!("{idx}\n{} --> {}\n{}\n\n", fmt_ts(s), fmt_ts(e), text));
    *idx += 1;
}

fn fmt_ts(sec: f64) -> String {
    let ms = (sec * 1000.0).round() as u64;
    format!("{:02}:{:02}:{:02},{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// 逐字锚点：行内第 char_offset 个字符（Unicode 字符数）的真实开始时刻
/// （qwen3_forced_aligner 输出）。拆分时优先吸附到锚点。
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct WordAnchor {
    pub char_offset: u32,
    pub start_sec: f64,
}

/// 校对行（说话人轮次制）：一行 = 一个说话人的连续发言，时间跨度即轮次。
/// 可序列化（项目文件整体存取）。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProofLine {
    pub start_sec: f64,
    pub end_sec: f64,
    /// Some = 说话人 id；None = 未归属（diar 空隙/未开启）
    pub speaker: Option<String>,
    pub text: String,
    /// 行内逐字锚点（可为空 = 块级归属无对齐；文本编辑后为近似值）
    pub anchors: Vec<WordAnchor>,
}

/// 相邻同说话人（Some 且相等）的行合并为一行——「说话人变化才换行」：
/// A 连说十句仍是一行，B 开口才起新行。None 行不参与合并（诚实保留空隙）。
pub fn merge_speaker_runs(lines: Vec<ProofLine>) -> Vec<ProofLine> {
    let mut out: Vec<ProofLine> = Vec::with_capacity(lines.len());
    for line in lines {
        if let (Some(back), Some(spk)) = (out.last_mut(), &line.speaker) {
            if back.speaker.as_ref() == Some(spk) {
                let base = back.text.chars().count() as u32;
                back.end_sec = back.end_sec.max(line.end_sec);
                back.anchors
                    .extend(line.anchors.iter().map(|a| WordAnchor {
                        char_offset: a.char_offset + base,
                        start_sec: a.start_sec,
                    }));
                back.text.push_str(&line.text);
                continue;
            }
        }
        out.push(line);
    }
    out
}

/// 在第 index 行的 char_pos（Unicode 字符数）处拆分为两行，后半行挂
/// second_speaker。分界时刻优先**吸附逐字锚点**：有锚点时在相邻锚点间
/// 线性插值（真实字时刻），无锚点退回整行字符比例。锚点随行拆分
/// （后半行偏移减去 char_pos，并补 0 号锚点 = 分界时刻）。
/// 越界/端点返回 None 不改动；成功返回分界时刻。
pub fn split_proof_line(
    lines: &mut Vec<ProofLine>,
    index: usize,
    char_pos: usize,
    second_speaker: Option<String>,
) -> Option<f64> {
    let total = lines.get(index)?.text.chars().count();
    if char_pos == 0 || char_pos >= total {
        return None;
    }
    let line = lines.get(index)?;
    let left: String = line.text.chars().take(char_pos).collect();
    let right: String = line.text.chars().skip(char_pos).collect();
    let split_at = anchored_time(line, char_pos, total);
    let (left_anchors, right_anchors) = split_anchors(&line.anchors, char_pos, split_at);
    let first = ProofLine {
        start_sec: line.start_sec,
        end_sec: split_at,
        speaker: line.speaker.clone(),
        text: left,
        anchors: left_anchors,
    };
    let second = ProofLine {
        start_sec: split_at,
        end_sec: line.end_sec,
        speaker: second_speaker,
        text: right,
        anchors: right_anchors,
    };
    lines.splice(index..=index, [first, second]);
    Some(split_at)
}

/// char_pos 处的时刻：锚点间线性插值；无锚点用整行比例。
/// 虚拟节点 = (0, start) + 锚点 + (total, end)，插值点必在其中一段。
fn anchored_time(line: &ProofLine, char_pos: usize, total: usize) -> f64 {
    let mut pts: Vec<(f64, f64)> = vec![(0.0, line.start_sec)];
    for a in &line.anchors {
        if (a.char_offset as usize) > 0 && (a.char_offset as usize) < total {
            pts.push((a.char_offset as f64, a.start_sec));
        }
    }
    pts.push((total as f64, line.end_sec));
    pts.sort_by(|a, b| a.0.total_cmp(&b.0));
    for w in pts.windows(2) {
        let (x0, y0) = w[0];
        let (x1, y1) = w[1];
        let x = char_pos as f64;
        if x >= x0 && x <= x1 {
            if x1 <= x0 {
                return y0;
            }
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        }
    }
    line.end_sec
}

/// 锚点随拆分一分为二：左行保留 offset < pos 的；右行 offset >= pos 的
/// 减去 pos，并在头部补 (0, split_at)。
fn split_anchors(
    anchors: &[WordAnchor],
    char_pos: usize,
    split_at: f64,
) -> (Vec<WordAnchor>, Vec<WordAnchor>) {
    let mut left = Vec::new();
    let mut right = vec![WordAnchor {
        char_offset: 0,
        start_sec: split_at,
    }];
    for a in anchors {
        if (a.char_offset as usize) < char_pos {
            left.push(*a);
        } else if (a.char_offset as usize) > char_pos {
            right.push(WordAnchor {
                char_offset: a.char_offset - char_pos as u32,
                start_sec: a.start_sec,
            });
        } // 恰在分界处的锚点被右行头部锚点取代
    }
    (left, right)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_timestamps() {
        assert_eq!(fmt_ts(0.0), "00:00:00,000");
        assert_eq!(fmt_ts(3661.5), "01:01:01,500");
        assert_eq!(fmt_ts(7599.999), "02:06:39,999");
    }

    #[test]
    fn one_cue_per_short_delta() {
        let srt = build_srt(&[Cue { start_sec: 2.0, end_sec: 6.4, text: "它标签是胶水".into() }]);
        assert!(srt.starts_with("1\n00:00:02,000 --> 00:00:06,400\n它标签是胶水\n"));
    }

    #[test]
    fn splits_long_delta_proportionally() {
        let long = "字".repeat(80);
        let srt = build_srt(&[Cue { start_sec: 0.0, end_sec: 10.0, text: long }]);
        let count = srt.matches("-->").count();
        assert!(count >= 2, "{srt}");
        // 首条起始为 0，末条结束为 10
        assert!(srt.contains("00:00:00,000"));
        assert!(srt.contains("00:00:10,000"));
    }

    #[test]
    fn lrc_lines_and_timestamps() {
        let lrc = build_lrc(
            &[Cue { start_sec: 2.0, end_sec: 6.4, text: "它标签是胶水".into() }],
            Some("录音"),
        );
        assert!(lrc.starts_with("[ti:录音]\n[00:02.00]它标签是胶水\n"), "{lrc}");
    }

    #[test]
    fn lrc_splits_long_line_consistently_with_srt() {
        let long = "句。".repeat(40); // 80 字
        let cues = [Cue { start_sec: 10.0, end_sec: 20.0, text: long }];
        let srt_count = build_srt(&cues).matches("-->").count();
        let lrc_count = build_lrc(&cues, None).lines().count();
        assert_eq!(srt_count, lrc_count);
    }

    #[test]
    fn lrc_timestamp_format() {
        assert_eq!(fmt_lrc_ts(0.0), "00:00.00");
        assert_eq!(fmt_lrc_ts(61.239), "01:01.24");
        assert_eq!(fmt_lrc_ts(3599.999), "60:00.00");
    }

    #[test]
    fn next_line_never_starts_with_punctuation() {
        let text = format!("{}{}", "字".repeat(40), "？！嗯哦"); // 44 字，尾带连续标点
        let cues = [Cue { start_sec: 0.0, end_sec: 10.0, text }];
        let srt = build_srt(&cues);
        let cue_lines: Vec<&str> = srt
            .split("\n\n")
            .flat_map(|c| c.lines().skip(2).collect::<Vec<_>>())
            .collect();
        for l in cue_lines.iter().skip(1) {
            let first = l.chars().next().unwrap_or('字');
            assert!(
                !"。，？！、；：…— ,.!?;:".contains(first),
                "行以标点开头：{l}"
            );
        }
    }

    #[test]
    fn skips_empty_cues() {
        assert_eq!(build_srt(&[Cue { start_sec: 1.0, end_sec: 2.0, text: "  ".into() }]), "");
    }

    fn pl(spk: Option<&str>, start: f64, end: f64, text: &str) -> ProofLine {
        ProofLine {
            start_sec: start,
            end_sec: end,
            speaker: spk.map(str::to_string),
            text: text.into(),
            anchors: Vec::new(),
        }
    }

    #[test]
    fn merges_consecutive_same_speaker_runs() {
        let merged = merge_speaker_runs(vec![
            pl(Some("A"), 0.0, 5.0, "你好"),
            pl(Some("A"), 5.0, 10.0, "请问"),
            pl(Some("B"), 10.0, 12.0, "是我"),
            pl(Some("A"), 12.0, 15.0, "好的"),
            pl(Some("A"), 15.0, 18.0, "马上"),
        ]);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].text, "你好请问");
        assert_eq!((merged[0].start_sec, merged[0].end_sec), (0.0, 10.0));
        assert_eq!(merged[2].text, "好的马上");
        // None 不参与合并
        let kept = merge_speaker_runs(vec![
            pl(None, 0.0, 1.0, "a"),
            pl(None, 1.0, 2.0, "b"),
        ]);
        assert_eq!(kept.len(), 2);
    }


    #[test]
    fn split_snaps_to_word_anchors() {
        let text = "字".repeat(20);
        // 锚点：第 5/10/15 字的真实时刻（非线性，模拟真实语速起伏）
        let line = ProofLine {
            start_sec: 10.0,
            end_sec: 30.0,
            speaker: Some("A".into()),
            text,
            anchors: vec![(5u32, 13.0), (10, 21.0), (15, 23.0)]
                .into_iter()
                .map(|(o, t)| WordAnchor { char_offset: o, start_sec: t })
                .collect(),
        };
        // 恰在锚点上：吸附真实时刻 21.0（比例插值会给出 20.0）
        let mut lines = vec![line.clone()];
        let at = split_proof_line(&mut lines, 0, 10, Some("B".into())).unwrap();
        assert!((at - 21.0).abs() < 1e-9);
        // 锚点之间（12 字，锚点 10→15 为 21.0→23.0）：线性插值 21.8
        let mut lines2 = vec![line];
        let at2 = split_proof_line(&mut lines2, 0, 12, None).unwrap();
        assert!((at2 - 21.8).abs() < 1e-6);
        // 锚点随行拆分：右行 0 号锚点 = 分界时刻，原 15 号锚点变 5 号
        let right = &lines[1];
        assert_eq!(right.anchors[0].char_offset, 0);
        assert!((right.anchors[0].start_sec - 21.0).abs() < 1e-9);
        assert_eq!(right.anchors[1].char_offset, 5);
        assert!((right.anchors[1].start_sec - 23.0).abs() < 1e-9);
        // 左行保留 5 号锚点
        assert_eq!(lines[0].anchors.len(), 1);
        assert_eq!(lines[0].anchors[0].char_offset, 5);
    }

    #[test]
    fn merge_concatenates_anchors_with_offset_base() {
        let a = ProofLine {
            start_sec: 0.0,
            end_sec: 4.0,
            speaker: Some("A".into()),
            text: "四四个字".into(),
            anchors: vec![WordAnchor { char_offset: 2, start_sec: 2.0 }],
        };
        let b = ProofLine {
            start_sec: 4.0,
            end_sec: 8.0,
            speaker: Some("A".into()),
            text: "又是四个".into(),
            anchors: vec![WordAnchor { char_offset: 1, start_sec: 5.0 }],
        };
        let merged = merge_speaker_runs(vec![a, b]);
        assert_eq!(merged.len(), 1);
        // 第二段锚点偏移 += 前段字符数(4)
        assert_eq!(merged[0].anchors[1].char_offset, 5);
        assert!((merged[0].anchors[1].start_sec - 5.0).abs() < 1e-9);
    }
    #[test]
    fn splits_line_proportionally_with_next_speaker() {
        let text = "字".repeat(20);
        let mut lines = vec![pl(Some("A"), 10.0, 30.0, &text)];
        let ok = split_proof_line(&mut lines, 0, 10, Some("B".into())).is_some();
        assert!(ok);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text.chars().count(), 10);
        assert_eq!(lines[0].speaker.as_deref(), Some("A"));
        assert_eq!(lines[1].speaker.as_deref(), Some("B"));
        // 起点 10s + 20s 跨度按 10/20 比例 → 分界在 20.0
        assert!((lines[0].end_sec - 20.0).abs() < 1e-9);
        assert!((lines[1].start_sec - 20.0).abs() < 1e-9);
        assert!((lines[1].end_sec - 30.0).abs() < 1e-9);
        // 拼回原文
        assert_eq!(format!("{}{}", lines[0].text, lines[1].text), text);
    }

    #[test]
    fn split_rejects_degenerate_positions() {
        let mut lines = vec![pl(Some("A"), 0.0, 5.0, "五个字")];
        assert!(split_proof_line(&mut lines, 0, 0, None).is_none());
        assert!(split_proof_line(&mut lines, 0, 5, None).is_none());
        assert!(split_proof_line(&mut lines, 9, 1, None).is_none());
        assert_eq!(lines.len(), 1);
    }
}
