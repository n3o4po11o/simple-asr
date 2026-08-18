# simple-asr

[English](README.md) | **中文**

跨平台（macOS / Linux / Windows）**Qwen3-ASR 语音转文字桌面应用**：Rust 后端 + Flutter 前端。

面向「长录音转写 + 人工校对」的完整工作流：流式转写、说话人分离、逐字时间戳、
歌词式校对编辑、项目文件与字幕导出。

## 功能

- **流式转写**：导入音频后增量上屏，识别速度实测 8-43x 实时（视后端/量化）
- **说话人分离**：sortformer 分段 + CAM++ 声纹聚类混合流水线，
  抢话场景（电话客服类录音）轮次归属正确；人工可修正/重命名说话人
- **校准模式**（音乐播放器式）：
  - media_kit 播放器 + 剪辑式波形（点击/拖动跳转、区段循环）
  - 歌词式时间轴行视图，当前行高亮、自动滚动跟随
  - 行内编辑文本（回车在光标处拆行、时间戳吸附逐字锚点）、跨行全局撤销（Cmd/Ctrl+Z）
  - vim 风格快捷键：空格播放/暂停、←/→ ±5s、`i` 编辑、`ESC` 退出
- **逐字时间戳**：qwen3_forced_aligner 词级对齐精修，长录音自动分段对齐
- **项目文件**（`.asrproj`）：行/锚点/说话人名/音频引用随存随载，可重新对齐时间轴
- **导出**：SRT 字幕 / LRC 歌词（行切分同源一致）；可选外接 OpenAI 兼容 API 做文本润色
- **模型管理**：应用内下载（ModelScope 境内源默认 / Hugging Face）、
  Q8 一键转换（更快更省显存）、可选组件（说话人分离、词级对齐）按需安装

## 平台与推理后端

| 平台 | 后端 | 状态 |
|---|---|---|
| macOS (Apple Silicon) | audio.cpp + Metal | ✅ 实测（M1 Max 7.9x 实时） |
| Linux (AMD / Intel / NVIDIA) | audio.cpp + Vulkan | ✅ 实测（RX 9070 XT 43x 实时 Q8） |
| Linux (AMD ROCm) | audio.cpp + HIP | ✅ 实测（33.7x 实时 Q8） |
| Windows | audio.cpp | 🚧 构建脚本就绪，未在真实硬件验证 |

推理引擎为 audio.cpp（ggml 系，静态链接），
`-hf` safetensors 权重直载、无需 GGUF 转换（Q8 量化可应用内一键转换）。

## 架构

```
app/                        Flutter UI（frb 桥接）
├── lib/                    Dart：状态、校准视图、设置
├── rust/                   asr_bridge（flutter_rust_bridge Rust 侧）
│   └── src/align.rs        词级对齐精修（锚点/分段/重铺）
rust/
├── crates/asr-core         音频解码重采样、双源下载器、SRT/LRC、设置（纯 Rust，单测齐）
├── crates/audiocpp-ffi     audio.cpp C shim 直连 FFI（自写 C ABI）
└── crates/sherpa-ffi       sherpa-onnx 声纹嵌入/聚类 FFI
scripts/                    构建（macOS .app / Linux AppImage）、引擎拉取、清缓存
```

## 构建

依赖：Flutter 3.44+、Rust（stable）、CMake、git。

```bash
# 1. 拉取并预构建 audio.cpp 引擎（macOS Metal 示例）
bash scripts/fetch-audiocpp.sh
(cd rust/vendor/audiocpp && bash scripts/build_metal.sh \
    --model-set custom --models 'qwen3_asr;sortformer_diar;qwen3_forced_aligner' \
    --target audiocpp_cli --target audiocpp_gguf)
# Linux 主路径为 Vulkan（--backend vulkan，产物目录名用 linux-vulkan-release）

# 2. 运行（debug）
cd app && flutter run -d macos

# 3. 发布构建（产物入 dist/）
bash scripts/build_macos.sh            # macOS .app
bash scripts/build-linux-appimage.sh   # Linux AppImage（在 Linux 上）
```

模型在应用内「设置」页下载（默认 ModelScope 源），无需手动放置。

## 开发

```bash
cd app && flutter test           # Dart：状态机/校准视图/diff 等 16 项
cd app/rust && cargo test --lib  # Rust：锚点对位/分段切块/撤销栈等 6 项
bash scripts/clean_cache.sh --dry-run   # 查看/清除编译缓存（默认 ~5GB，--all 连引擎树）
```

长录音真实音频的对齐精修有 `#[ignore]` 手动端到端测试（`SIMPLE_ASR_TEST_AUDIO`
/ `SIMPLE_ASR_TEST_PROJECT` 环境变量指定音频与项目文件后单独跑）。

## 第三方组件

| 组件 | 用途 | 许可 |
|---|---|---|
| [audio.cpp](https://github.com/0xShug0/audio.cpp) | 推理引擎（含 Qwen3-ASR/ForcedAligner 实现） | Apache-2.0 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 声纹嵌入（CAM++） | Apache-2.0 |
| [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf) | 语音识别模型 | Apache-2.0（模型权重按其许可使用） |
| Flutter / flutter_rust_bridge / media_kit | UI 与桥接 | BSD-3 / MIT / MIT |

## 许可

[Apache-2.0](LICENSE) © 2026 The simple-asr Authors
