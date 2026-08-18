//! Audio decode → mono f32 → resample to the model's 16 kHz.
//!
//! Qwen3-ASR's audio encoder takes 16 kHz mono PCM F32; chunking into 30 s
//! windows happens inside the engine, so we hand over the whole buffer.

use std::fs::File;
use std::path::Path;
use thiserror::Error;

use rubato::Resampler as _;

pub const TARGET_SAMPLE_RATE: u32 = 16000;

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("open/probe {path}: {source}")]
    Probe {
        path: String,
        source: symphonia::core::errors::Error,
    },
    #[error("decode {path}: {source}")]
    Decode {
        path: String,
        source: symphonia::core::errors::Error,
    },
    #[error("no audio track in {0}")]
    NoTrack(String),
    #[error("unknown sample rate in {0}")]
    UnknownSampleRate(String),
    #[error("unsupported input sample rate: {0}")]
    BadSampleRate(u32),
    #[error("resampler: {0}")]
    Resample(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Decode any supported container to mono f32 at its native sample rate.
/// Multi-channel audio is averaged down to mono.
pub fn load_audio_mono(path: &Path) -> Result<(u32, Vec<f32>), AudioError> {
    let display = path.display().to_string();
    let src = File::open(path)?;
    let mss = symphonia::core::io::MediaSourceStream::new(Box::new(src), Default::default());

    let probed = symphonia::default::get_probe()
        .format(&Default::default(), mss, &Default::default(), &Default::default())
        .map_err(|source| AudioError::Probe { path: display.clone(), source })?;
    let mut format = probed.format;

    let track = format
        .default_track()
        .ok_or_else(|| AudioError::NoTrack(display.clone()))?
        .clone();
    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| AudioError::UnknownSampleRate(display.clone()))?;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &Default::default())
        .map_err(|source| AudioError::Probe { path: display.clone(), source })?;

    let mut mono: Vec<f32> = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break // clean end of stream
            }
            Err(source) => return Err(AudioError::Decode { path: display.clone(), source }),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = decoder
            .decode(&packet)
            .map_err(|source| AudioError::Decode { path: display.clone(), source })?;

        let spec = *decoded.spec();
        let channels = spec.channels.count();
        let mut sbuf = symphonia::core::audio::SampleBuffer::<f32>::new(
            decoded.capacity() as u64,
            spec,
        );
        sbuf.copy_interleaved_ref(decoded);
        let interleaved = sbuf.samples();

        if channels == 1 {
            mono.extend_from_slice(interleaved);
        } else {
            for frame in interleaved.chunks(channels) {
                mono.push(frame.iter().sum::<f32>() / channels as f32);
            }
        }
    }
    Ok((sample_rate, mono))
}

/// Resample mono f32 from `sr_in` to 16 kHz.
///
/// Fixed-size blocks via `FftFixedInOut` (exact in/out ratio per call); the
/// final partial block is zero-padded and the result trimmed to the expected
/// length. (A previous single-pass `FftFixedIn` over the whole buffer only
/// processed half of power-of-two-padded chunks for 44.1k→16k.)
pub fn resample_to_16k(samples: &[f32], sr_in: u32) -> Result<Vec<f32>, AudioError> {
    if sr_in == TARGET_SAMPLE_RATE {
        return Ok(samples.to_vec());
    }
    if sr_in == 0 {
        return Err(AudioError::BadSampleRate(sr_in));
    }
    let expected_out =
        (samples.len() as u64 * TARGET_SAMPLE_RATE as u64 / sr_in as u64) as usize;

    // 每块输出 1 秒（16000 帧）；对应输入帧数由构造器按采样率比给出。
    let mut resampler = rubato::FftFixedInOut::<f32>::new(
        sr_in as usize,
        TARGET_SAMPLE_RATE as usize,
        TARGET_SAMPLE_RATE as usize,
        1,
    )
    .map_err(|e| AudioError::Resample(e.to_string()))?;
    let in_chunk = resampler.input_frames_max();
    let out_chunk = resampler.output_frames_max();

    let mut out = Vec::with_capacity(expected_out + out_chunk);
    let mut pos = 0usize;
    while pos < samples.len() {
        let end = (pos + in_chunk).min(samples.len());
        let mut buf = samples[pos..end].to_vec();
        if buf.len() < in_chunk {
            buf.resize(in_chunk, 0.0); // 尾块补零
        }
        let mut obuf = vec![vec![0f32; out_chunk]];
        let (_, written) = resampler
            .process_into_buffer(&[buf], &mut obuf, None)
            .map_err(|e| AudioError::Resample(e.to_string()))?;
        out.extend_from_slice(&obuf[0][..written]);
        pos = end;
    }
    out.truncate(expected_out);
    Ok(out)
}

/// Decode + downmix + resample in one go: what the engine consumes.
pub fn load_audio_16k_mono(path: &Path) -> Result<Vec<f32>, AudioError> {
    let (sr, samples) = load_audio_mono(path)?;
    resample_to_16k(&samples, sr)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal 16-bit PCM WAV writer for fixtures.
    fn wav_bytes(sr: u32, channels: u16, samples_per_ch: &[i16]) -> Vec<u8> {
        let data: Vec<u8> = samples_per_ch
            .chunks(channels as usize)
            .flat_map(|f| f.iter().flat_map(|s| s.to_le_bytes()))
            .collect();
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&((36 + data.len()) as u32).to_le_bytes());
        b.extend_from_slice(b"WAVEfmt ");
        b.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
        b.extend_from_slice(&1u16.to_le_bytes()); // PCM
        b.extend_from_slice(&channels.to_le_bytes());
        b.extend_from_slice(&sr.to_le_bytes());
        b.extend_from_slice(&(sr * channels as u32 * 2).to_le_bytes()); // byte rate
        b.extend_from_slice(&(channels * 2).to_le_bytes()); // block align
        b.extend_from_slice(&16u16.to_le_bytes()); // bits
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(data.len() as u32).to_le_bytes());
        b.extend_from_slice(&data);
        b
    }

    #[test]
    fn decodes_mono_wav_and_reports_native_rate() {
        let samples: Vec<i16> = (0..8000).map(|i| (i % 100) as i16).collect();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.wav");
        std::fs::write(&path, wav_bytes(8000, 1, &samples)).unwrap();

        let (sr, mono) = load_audio_mono(&path).unwrap();
        assert_eq!(sr, 8000);
        assert_eq!(mono.len(), 8000);
    }

    #[test]
    fn stereo_is_averaged_to_mono() {
        // L=1000, R=-1000 → 0; L=1000, R=1000 → 1000 (scaled by i16→f32)
        let samples: Vec<i16> = vec![1000, -1000, 1000, 1000];
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.wav");
        std::fs::write(&path, wav_bytes(16000, 2, &samples)).unwrap();

        let (sr, mono) = load_audio_mono(&path).unwrap();
        assert_eq!(sr, 16000);
        assert_eq!(mono.len(), 2);
        assert!(mono[0].abs() < 1e-6);
        assert!((mono[1] - 1000.0 / 32768.0).abs() < 1e-6);
    }

    #[test]
    fn resamples_8k_to_16k_doubling_length() {
        let samples = vec![0.5f32; 8000];
        let out = resample_to_16k(&samples, 8000).unwrap();
        assert_eq!(out.len(), 16000);
    }

    #[test]
    fn resamples_44100_to_16k_without_truncation() {
        // 回归：非整比采样率（44.1k→16k），任意长度（非 2 的幂、跨多块）
        let n = 44_100 * 2 + 12_345;
        let samples = vec![0.3f32; n];
        let out = resample_to_16k(&samples, 44_100).unwrap();
        assert_eq!(out.len(), n * 16_000 / 44_100);
    }

    #[test]
    fn resamples_22050_to_exact_ratio_length() {
        let n = 22_050 * 3;
        let out = resample_to_16k(&vec![0.5f32; n], 22_050).unwrap();
        assert_eq!(out.len(), n * 16_000 / 22_050); // 48000
    }

    #[test]
    fn passthrough_when_already_16k() {
        let samples = vec![0.25f32; 100];
        let out = resample_to_16k(&samples, 16000).unwrap();
        assert_eq!(out, samples);
    }
}
