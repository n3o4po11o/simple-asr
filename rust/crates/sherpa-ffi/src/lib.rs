//! sherpa-onnx 离线说话人分离的 Rust FFI（k2-fsa 预编译 C API）。
//!
//! 流水线 = pyannote 分割（窗口级说话人概率）+ CAM++ 声纹提取
//! （16kHz → 192 维向量）+ 快速聚类（全局一致说话人 ID）——即 FunASR
//! 「VAD + CAM++」思路的纯 C++/ONNX 实现，无 Python 依赖。
//! 对比旧 sortformer 路线：根治跨窗 ID 重标（声纹聚类），模型体积
//! ~34MB（旧 175MB）。CPU 推理即够（嵌入网络很小）。
//!
//! 输入约定：16kHz 单声道 f32 PCM——与 asr-core 音频管线产物一致。

use std::ffi::{c_char, c_float, c_int, c_void, CString};
use std::path::Path;

mod sys {
    use super::*;

    #[repr(C)]
    pub struct OnlineStream {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct EmbeddingExtractorConfig {
        pub model: *const c_char,
        pub num_threads: c_int,
        pub debug: c_int,
        pub provider: *const c_char,
    }

    extern "C" {
        pub fn SherpaOnnxCreateSpeakerEmbeddingExtractor(
            config: *const EmbeddingExtractorConfig,
        ) -> *const c_void;
        pub fn SherpaOnnxDestroySpeakerEmbeddingExtractor(p: *const c_void);
        pub fn SherpaOnnxSpeakerEmbeddingExtractorDim(p: *const c_void) -> c_int;
        pub fn SherpaOnnxSpeakerEmbeddingExtractorCreateStream(
            p: *const c_void,
        ) -> *const OnlineStream;
        pub fn SherpaOnnxOnlineStreamAcceptWaveform(
            stream: *const OnlineStream,
            sample_rate: c_int,
            samples: *const c_float,
            n: c_int,
        );
        pub fn SherpaOnnxOnlineStreamInputFinished(stream: *const OnlineStream);
        pub fn SherpaOnnxDestroyOnlineStream(stream: *const OnlineStream);
        pub fn SherpaOnnxSpeakerEmbeddingExtractorIsReady(
            p: *const c_void,
            s: *const OnlineStream,
        ) -> c_int;
        pub fn SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(
            p: *const c_void,
            s: *const OnlineStream,
        ) -> *const c_float;
        pub fn SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v: *const c_float);
    }

    #[repr(C)]
    pub struct PyannoteModelConfig {
        pub model: *const c_char,
    }

    #[repr(C)]
    pub struct SegmentationModelConfig {
        pub pyannote: PyannoteModelConfig,
        pub num_threads: c_int,
        pub debug: c_int,
        pub provider: *const c_char,
    }

    #[repr(C)]
    pub struct FastClusteringConfig {
        /// 已知说话人数（>0 时绕过阈值聚类，强烈推荐已知场景使用）。
        pub num_clusters: c_int,
        /// 说话人数未知时的距离阈值（0.5 为 CAM++ 常用值）。
        pub threshold: c_float,
    }

    #[repr(C)]
    pub struct DiarizationConfig {
        pub segmentation: SegmentationModelConfig,
        pub embedding: EmbeddingExtractorConfig,
        pub clustering: FastClusteringConfig,
        /// 短于此秒数的段被丢弃（假阳性碎片过滤）。
        pub min_duration_on: c_float,
        /// 短于此秒数的间隙可合并。
        pub min_duration_off: c_float,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct DiarizationSegment {
        pub start: c_float,
        pub end: c_float,
        pub speaker: c_int,
    }

    extern "C" {
        pub fn SherpaOnnxCreateOfflineSpeakerDiarization(
            config: *const DiarizationConfig,
        ) -> *const c_void;
        pub fn SherpaOnnxDestroyOfflineSpeakerDiarization(sd: *const c_void);
        pub fn SherpaOnnxOfflineSpeakerDiarizationProcess(
            sd: *const c_void,
            samples: *const c_float,
            n: c_int,
        ) -> *const c_void;
        pub fn SherpaOnnxOfflineSpeakerDiarizationDestroyResult(r: *const c_void);
        pub fn SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(
            r: *const c_void,
        ) -> c_int;
        pub fn SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(
            r: *const c_void,
        ) -> *const DiarizationSegment;
        pub fn SherpaOnnxOfflineSpeakerDiarizationDestroySegment(
            s: *const DiarizationSegment,
        );
    }
}

/// 一条说话人分段（秒）。`speaker` 为聚类 ID（全局一致）。
pub struct SpeakerSegment {
    pub start_sec: f64,
    pub end_sec: f64,
    pub speaker: u32,
}

/// 离线说话人分离器（模型路径在创建时固定）。
pub struct SherpaDiarization {
    ptr: *const c_void,
}

// C API 无全局可变状态；句柄由调用方串行使用（与 AcppModel 约定一致）。
unsafe impl Send for SherpaDiarization {}
unsafe impl Sync for SherpaDiarization {}

/// 分离配置（Rust 侧默认值聚合）。
pub struct DiarizationParams {
    /// pyannote 分割模型（model.onnx）
    pub segmentation_model: std::path::PathBuf,
    /// CAM++ 声纹模型（*.onnx）
    pub embedding_model: std::path::PathBuf,
    /// 已知说话人数；0 = 按阈值自动聚类
    pub num_speakers: u32,
    /// 自动聚类的距离阈值（CAM++ 常用 0.5）
    pub threshold: f32,
    pub num_threads: u32,
}

impl SherpaDiarization {
    pub fn new(params: &DiarizationParams) -> Result<Self, String> {
        let seg = CString::new(
            params.segmentation_model.to_string_lossy().as_bytes(),
        )
        .map_err(|e| format!("分割模型路径非法：{e}"))?;
        let emb = CString::new(
            params.embedding_model.to_string_lossy().as_bytes(),
        )
        .map_err(|e| format!("声纹模型路径非法：{e}"))?;
        let provider = CString::new("cpu").unwrap();
        let config = sys::DiarizationConfig {
            segmentation: sys::SegmentationModelConfig {
                pyannote: sys::PyannoteModelConfig { model: seg.as_ptr() },
                num_threads: params.num_threads as c_int,
                debug: 0,
                provider: provider.as_ptr(),
            },
            embedding: sys::EmbeddingExtractorConfig {
                model: emb.as_ptr(),
                num_threads: params.num_threads as c_int,
                debug: 0,
                provider: provider.as_ptr(),
            },
            clustering: sys::FastClusteringConfig {
                num_clusters: params.num_speakers as c_int,
                threshold: params.threshold,
            },
            min_duration_on: 0.5,
            min_duration_off: 0.5,
        };
        let ptr = unsafe {
            sys::SherpaOnnxCreateOfflineSpeakerDiarization(&config)
        };
        if ptr.is_null() {
            // 常见原因：模型文件不存在（上游 stderr 有具体日志）
            Err(format!(
                "sherpa-onnx 分离器创建失败（检查模型路径：{} / {}）",
                params.segmentation_model.display(),
                params.embedding_model.display()
            ))
        } else {
            Ok(Self { ptr })
        }
    }

    /// 整段分离。返回按开始时间排序的说话人段。
    pub fn process(&self, pcm: &[f32]) -> Result<Vec<SpeakerSegment>, String> {
        if pcm.len() > c_int::MAX as usize {
            return Err("音频过长（超出 c_int 样本数上限）".to_string());
        }
        let result = unsafe {
            sys::SherpaOnnxOfflineSpeakerDiarizationProcess(
                self.ptr,
                pcm.as_ptr(),
                pcm.len() as c_int,
            )
        };
        if result.is_null() {
            return Err("sherpa-onnx 分离失败".to_string());
        }
        unsafe {
            let n = sys::SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result);
            let arr = sys::SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result);
            let mut out = Vec::with_capacity(n.max(0) as usize);
            if !arr.is_null() {
                for i in 0..n {
                    let s = *arr.offset(i as isize);
                    out.push(SpeakerSegment {
                        start_sec: s.start as f64,
                        end_sec: s.end as f64,
                        speaker: s.speaker.max(0) as u32,
                    });
                }
                sys::SherpaOnnxOfflineSpeakerDiarizationDestroySegment(arr);
            }
            sys::SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result);
            Ok(out)
        }
    }
}

impl Drop for SherpaDiarization {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { sys::SherpaOnnxDestroyOfflineSpeakerDiarization(self.ptr) };
        }
    }
}

/// CAM++ 声纹提取器（独立于整套分离流水线——用于对自定义分段提声纹）。
pub struct SpeakerEmbedder {
    ptr: *const c_void,
    dim: usize,
}

unsafe impl Send for SpeakerEmbedder {}
unsafe impl Sync for SpeakerEmbedder {}

impl SpeakerEmbedder {
    pub fn new(model: &Path, num_threads: u32) -> Result<Self, String> {
        let m = CString::new(model.to_string_lossy().as_bytes())
            .map_err(|e| format!("声纹模型路径非法：{e}"))?;
        let provider = CString::new("cpu").unwrap();
        let cfg = sys::EmbeddingExtractorConfig {
            model: m.as_ptr(),
            num_threads: num_threads as c_int,
            debug: 0,
            provider: provider.as_ptr(),
        };
        let ptr = unsafe { sys::SherpaOnnxCreateSpeakerEmbeddingExtractor(&cfg) };
        if ptr.is_null() {
            return Err(format!("声纹提取器创建失败（检查模型：{}）", model.display()));
        }
        let dim = unsafe { sys::SherpaOnnxSpeakerEmbeddingExtractorDim(ptr) } as usize;
        Ok(Self { ptr, dim })
    }

    pub fn dim(&self) -> usize {
        self.dim
    }

    /// 提取一段 16k 单声道音频的声纹（段太短时上游不可用，返回 None）。
    pub fn embed(&self, pcm: &[f32]) -> Option<Vec<f32>> {
        if pcm.len() > c_int::MAX as usize || pcm.is_empty() {
            return None;
        }
        unsafe {
            let stream = sys::SherpaOnnxSpeakerEmbeddingExtractorCreateStream(self.ptr);
            if stream.is_null() {
                return None;
            }
            sys::SherpaOnnxOnlineStreamAcceptWaveform(
                stream,
                16000,
                pcm.as_ptr(),
                pcm.len() as c_int,
            );
            sys::SherpaOnnxOnlineStreamInputFinished(stream);
            let out = if sys::SherpaOnnxSpeakerEmbeddingExtractorIsReady(self.ptr, stream) != 0 {
                let v = sys::SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(self.ptr, stream);
                if !v.is_null() {
                    let emb = std::slice::from_raw_parts(v, self.dim).to_vec();
                    sys::SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v);
                    Some(emb)
                } else {
                    None
                }
            } else {
                None
            };
            sys::SherpaOnnxDestroyOnlineStream(stream);
            out
        }
    }
}

impl Drop for SpeakerEmbedder {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { sys::SherpaOnnxDestroySpeakerEmbeddingExtractor(self.ptr) };
        }
    }
}



/// 声纹聚类：余弦距离 complete-linkage 层次聚类 + FunASR 式收尾。
/// `num_clusters > 0` 按已知人数切树；否则按 `threshold` 距离阈值切。
/// 收尾两步（均不减少显式给定的 K）：
/// 1. 微簇回收（FunASR merge_by_cos 的安全版）：自动模式下，段数 <5% 的
///    碎片簇并入质心最相似的大簇（余弦 >0.5）——complete-linkage 对合并
///    不同说话人天然保守（取最大距离），但阈值切树仍会产生伪碎片。
/// 2. Lloyd 精修：按质心重指派所有段 ×3 轮——修正边界段的错配。
pub fn cluster_embeddings(
    embeddings: &[Vec<f32>],
    num_clusters: usize,
    threshold: f32,
) -> Vec<usize> {
    let n = embeddings.len();
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![0];
    }
    // L2 归一化（精修阶段直接点积即余弦）
    let normed: Vec<Vec<f32>> = embeddings
        .iter()
        .map(|v| {
            let nrm = norm(v);
            v.iter().map(|x| x / nrm).collect()
        })
        .collect();
    // 余弦距离矩阵
    let mut dist = vec![0.0f32; n * n];
    for i in 0..n {
        for j in (i + 1)..n {
            let d = 1.0 - dot(&normed[i], &normed[j]);
            dist[i * n + j] = d;
            dist[j * n + i] = d;
        }
    }
    // 朴素凝聚层次（complete-linkage），n 为段数（百级）足够快
    let clusters: Vec<Vec<usize>> = (0..n).map(|i| vec![i]).collect();
    let mut clusters = clusters;
    let mut active: Vec<usize> = (0..n).collect();
    while active.len() > 1 {
        let mut best = (usize::MAX, usize::MAX, f32::INFINITY);
        for a in 0..active.len() {
            for b in (a + 1)..active.len() {
                let (ca, cb) = (active[a], active[b]);
                let mut max_d = 0.0f32;
                for &i in &clusters[ca] {
                    for &j in &clusters[cb] {
                        max_d = max_d.max(dist[i * n + j]);
                    }
                }
                if max_d < best.2 {
                    best = (a, b, max_d);
                }
            }
        }
        let (a, b, d) = best;
        let done = if num_clusters > 0 {
            active.len() <= num_clusters
        } else {
            d > threshold
        };
        if done {
            break;
        }
        let (ia, ib) = (active[a], active[b]);
        let moved = std::mem::take(&mut clusters[ib]);
        clusters[ia].extend(moved);
        active.remove(b);
    }
    let mut out = vec![0usize; n];
    let mut ordered: Vec<usize> = active.clone();
    ordered.sort_by_key(|&ci| clusters[ci][0]);
    for (label, ci) in ordered.iter().enumerate() {
        for &i in &clusters[*ci] {
            out[i] = label;
        }
    }

    // ── 微簇回收（仅自动模式；碎片=段数 <5%）──
    if num_clusters == 0 {
        let k = out.iter().cloned().max().map_or(1, |m| m + 1);
        if k > 1 {
            let cnt = |l: usize| out.iter().filter(|&&x| x == l).count();
            let tiny: Vec<usize> = (0..k).filter(|&l| cnt(l) * 20 < n).collect();
            for tl in tiny {
                if out.iter().all(|&x| x != tl) {
                    continue; // 已被回收过
                }
                // 质心
                let (c, m) = centroid_of(&normed, &out, tl);
                if m == 0 {
                    continue;
                }
                // 找最相似的非自身簇（余弦 >0.5 才并）
                let mut best = (usize::MAX, 0.5f32);
                for l in 0..k {
                    if l == tl || out.iter().all(|&x| x != l) {
                        continue;
                    }
                    let (cl, ml) = centroid_of(&normed, &out, l);
                    if ml == 0 {
                        continue;
                    }
                    let sim = dot(&c, &cl);
                    if sim > best.1 {
                        best = (l, sim);
                    }
                }
                let (target, _) = best;
                if target != usize::MAX {
                    for x in out.iter_mut() {
                        if *x == tl {
                            *x = target;
                        }
                    }
                }
            }
            relabel_sequential(&mut out);
        }
    }

    // ── Lloyd 精修（质心重指派 ×3）──
    for _ in 0..3 {
        let k = out.iter().cloned().max().map_or(1, |m| m + 1);
        let mut centroids = Vec::new();
        let mut valid_k = 0usize;
        for l in 0..k {
            let (c, m) = centroid_of(&normed, &out, l);
            if m > 0 {
                centroids.push(c);
                valid_k += 1;
            }
        }
        if valid_k <= 1 {
            break;
        }
        let mut changed = false;
        for (i, v) in normed.iter().enumerate() {
            let mut best = (out[i], -2.0f32);
            for (c, cen) in centroids.iter().enumerate() {
                let sim = dot(v, cen);
                if sim > best.1 {
                    best = (c, sim);
                }
            }
            if best.0 != out[i] {
                out[i] = best.0;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    relabel_sequential(&mut out);
    out
}

/// 标号重排为 0..k-1（按首次出现顺序）。
fn relabel_sequential(labels: &mut [usize]) {
    let mut remap = std::collections::HashMap::new();
    for l in labels.iter_mut() {
        let next = remap.len();
        *l = *remap.entry(*l).or_insert(next);
    }
}

/// 某簇的 L2 归一化质心与成员数。
fn centroid_of(normed: &[Vec<f32>], labels: &[usize], l: usize) -> (Vec<f32>, usize) {
    let dim = normed.first().map_or(0, |v| v.len());
    let mut c = vec![0.0f32; dim];
    let mut m = 0usize;
    for (v, &lab) in normed.iter().zip(labels) {
        if lab == l {
            for (cc, x) in c.iter_mut().zip(v) {
                *cc += x;
            }
            m += 1;
        }
    }
    if m > 0 {
        let nrm = norm(&c);
        for x in c.iter_mut() {
            *x /= nrm;
        }
    }
    (c, m)
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn norm(a: &[f32]) -> f32 {
    dot(a, a).sqrt().max(1e-8)
}

/// 便捷入口：给两个模型路径直接分离一段 PCM（num_speakers=0 自动聚类）。
pub fn diarize(
    segmentation_model: &Path,
    embedding_model: &Path,
    pcm: &[f32],
) -> Result<Vec<SpeakerSegment>, String> {
    let d = SherpaDiarization::new(&DiarizationParams {
        segmentation_model: segmentation_model.to_path_buf(),
        embedding_model: embedding_model.to_path_buf(),
        num_speakers: 0,
        threshold: 0.5,
        num_threads: 4,
    })?;
    d.process(pcm)
}
