//! FFI 冒烟：acpp-smoke <model-dir-or-gguf> <raw-f32le-16k-mono.pcm> [backend] [threads]
//! PCM 由 `ffmpeg -i <audio> -f f32le -ac 1 -ar 16000 out.pcm` 生成。

use std::path::Path;

fn main() {
    let mut args = std::env::args().skip(1);
    let model = args.next().expect("usage: acpp-smoke <model> <pcm> [backend] [threads]");
    let pcm_path = args.next().expect("usage: acpp-smoke <model> <pcm> [backend] [threads]");
    let backend = args.next().unwrap_or_else(|| "hip".into());
    let threads: u32 = args.next().and_then(|s| s.parse().ok()).unwrap_or(4);
    let family = args.next().unwrap_or_else(|| "qwen3_asr".into());

    let raw = std::fs::read(&pcm_path).expect("read pcm");
    let pcm: Vec<f32> = raw
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    println!("samples   : {} ({:.1}s @16k)", pcm.len(), pcm.len() as f32 / 16000.0);
    {
        extern "C" {
            fn acpp_families() -> *const std::ffi::c_char;
        }
        unsafe {
            println!(
                "families  : {}",
                std::ffi::CStr::from_ptr(acpp_families()).to_string_lossy()
            );
        }
    }

    let t0 = std::time::Instant::now();
    let m = match audiocpp_ffi::AcppModel::load(Path::new(&model), &family) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("LOAD FAILED: {e}");
            std::process::exit(1);
        }
    };
    println!("model load: {:.1}s", t0.elapsed().as_secs_f32());

    let t1 = std::time::Instant::now();
    match m.transcribe(&pcm, &backend, 0, threads, "") {
        Ok((text, lang)) => {
            println!(
                "elapsed   : {:.2}s ({:.1}x 实时)",
                t1.elapsed().as_secs_f32(),
                pcm.len() as f32 / 16000.0 / t1.elapsed().as_secs_f32()
            );
            println!("language  : {lang}");
            println!("chars     : {}", text.chars().count());
            println!("TEXT      : {text}");
        }
        Err(e) => {
            eprintln!("TRANSCRIBE FAILED: {e}");
            std::process::exit(2);
        }
    }
}
