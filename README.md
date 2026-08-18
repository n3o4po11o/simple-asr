# simple-asr

**English** | [中文](README.cn.md)

Cross-platform (macOS / Linux / Windows) **Qwen3-ASR speech-to-text desktop app**: Rust backend + Flutter frontend.

A complete workflow built around "long-recording transcription + manual proofreading": streaming transcription, speaker diarization, word-level timestamps, lyrics-style proofreading editor, project files and subtitle export.

## Features

- **Streaming transcription**: incremental output as audio is imported; 8-43x real-time measured (depending on backend / quantization)
- **Speaker diarization**: hybrid pipeline of sortformer segmentation + CAM++ voiceprint clustering — correct turn attribution even in overlapping-speech scenarios (e.g. call-center recordings); speakers can be manually corrected / renamed
- **Proofreading mode** (music-player style):
  - media_kit player + clip-style waveform (click/drag to seek, section looping)
  - lyrics-style timeline view with current-line highlight and auto-scroll
  - in-line text editing (Enter splits the line at the cursor, timestamps snap to word anchors), global undo across lines (Cmd/Ctrl+Z)
  - vim-style shortcuts: Space play/pause, ←/→ ±5s, `i` edit, `ESC` leave
- **Word-level timestamps**: qwen3_forced_aligner refinement, automatic segmented alignment for long recordings
- **Project files** (`.asrproj`): lines / anchors / speaker names / audio reference saved & reloaded; timeline can be re-aligned
- **Export**: SRT subtitles / LRC lyrics (both share the same line splitting); optional external OpenAI-compatible API for text polishing
- **Model management**: in-app downloads (ModelScope as China-friendly default / Hugging Face), one-click Q8 conversion (faster, less VRAM), optional components (diarization, word aligner) installed on demand

## Platforms & Inference Backends

| Platform | Backend | Status |
|---|---|---|
| macOS (Apple Silicon) | audio.cpp + Metal | ✅ Tested (M1 Max, 7.9x real-time) |
| Linux (AMD / Intel / NVIDIA) | audio.cpp + Vulkan | ✅ Tested (RX 9070 XT, 43x real-time Q8) |
| Linux (AMD ROCm) | audio.cpp + HIP | ✅ Tested (33.7x real-time Q8) |
| Windows | audio.cpp | 🚧 Build scripts ready, untested on real hardware |

The inference engine is [audio.cpp](https://github.com/0xShug0/audio.cpp) (ggml family, statically linked). `-hf` safetensors weights load directly — no GGUF conversion needed (in-app one-click Q8 quantization available).

## Architecture

```
app/                        Flutter UI (frb bridge)
├── lib/                    Dart: state, proofreading views, settings
├── rust/                   asr_bridge (flutter_rust_bridge Rust side)
│   └── src/align.rs        Word-level alignment refinement (anchors / segmentation / re-layout)
rust/
├── crates/asr-core         Audio decode & resample, dual-source downloader, SRT/LRC, settings (pure Rust, well tested)
├── crates/audiocpp-ffi     Direct FFI to audio.cpp via a hand-written C shim
└── crates/sherpa-ffi       sherpa-onnx voiceprint embedding / clustering FFI
scripts/                    Builds (macOS .app / Linux AppImage), engine fetch, cache cleaning
```

## Building

Dependencies: Flutter 3.44+, Rust (stable), CMake, git.

```bash
# 1. Fetch and prebuild the audio.cpp engine (macOS Metal example)
bash scripts/fetch-audiocpp.sh
(cd rust/vendor/audiocpp && bash scripts/build_metal.sh \
    --model-set custom --models 'qwen3_asr;sortformer_diar;qwen3_forced_aligner' \
    --target audiocpp_cli --target audiocpp_gguf)
# On Linux the main path is Vulkan (--backend vulkan; build dir name: linux-vulkan-release)

# 2. Run (debug)
cd app && flutter run -d macos

# 3. Release builds (artifacts in dist/)
bash scripts/build_macos.sh            # macOS .app
bash scripts/build-linux-appimage.sh   # Linux AppImage (on Linux)
```

Models are downloaded in the app's Settings page (ModelScope source by default) — no manual placement required.

## Development

```bash
cd app && flutter test           # Dart: state machine / proofreading views / diff, 16 tests
cd app/rust && cargo test --lib  # Rust: anchor mapping / chunk splitting / undo stack, 6 tests
bash scripts/clean_cache.sh --dry-run   # Inspect/clean build caches (~5GB by default, --all includes engine tree)
```

Alignment refinement on real long recordings has `#[ignore]` manual end-to-end tests (set the `SIMPLE_ASR_TEST_AUDIO` / `SIMPLE_ASR_TEST_PROJECT` env vars to point at an audio file and a project file, then run them individually).

## Third-Party Components

| Component | Purpose | License |
|---|---|---|
| [audio.cpp](https://github.com/0xShug0/audio.cpp) | Inference engine (Qwen3-ASR / ForcedAligner implementations) | Apache-2.0 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Voiceprint embedding (CAM++) | Apache-2.0 |
| [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf) | Speech recognition model | Apache-2.0 (model weights under their own license) |
| Flutter / flutter_rust_bridge / media_kit | UI & bridging | BSD-3 / MIT / MIT |

## License

[Apache-2.0](LICENSE) © 2026 The simple-asr Authors
