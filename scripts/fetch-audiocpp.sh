#!/usr/bin/env bash
# 拉取 audio.cpp 引擎源码到 rust/vendor/audiocpp（gitignored，可复现）。
# 浅克隆（--depth 1 + 指定 commit 的 depth-1 fetch）：源码树与普通 clone
# 完全一致，但 .git 从 ~108MB 降到几 MB——本仓库对上游零修改（定制全在
# 构建参数里），无需上游历史。版本锁定 = rust/vendor/AUDIOCPP_PIN（入库）。
# 用法: bash scripts/fetch-audiocpp.sh [pin-commit]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/rust/vendor/audiocpp"
REPO="https://github.com/0xShug0/audio.cpp"
PIN="${1:-$(cat "$ROOT/rust/vendor/AUDIOCPP_PIN" 2>/dev/null || echo main)}"

if [ ! -d "$DEST/.git" ]; then
  # CI 共享出口 IP 会被 GitHub 二级限流（429），git 自带无重试——手退三连
  for i in 1 2 3; do
    if git clone --depth 1 "$REPO" "$DEST"; then break; fi
    [ "$i" = 3 ] && exit 1
    sleep 10
  done
fi
cd "$DEST"
# 浅 fetch 目标 commit（GitHub 允许任意 SHA 的 depth-1 fetch）
git fetch --depth 1 --force origin "$PIN"
git checkout --force "$PIN"
echo "audiocpp pinned at $(git rev-parse HEAD) → $DEST"
echo "构建（Linux 主路径 = Vulkan；macOS 用 build_metal.sh）："
echo "  (cd $DEST && bash scripts/build_linux.sh --backend vulkan --deployment-build --model-set custom --models 'qwen3_asr;sortformer_diar;qwen3_forced_aligner' --native-cpu OFF --target audiocpp_gguf)"
echo "  （HIP 仅特定 ROCm 环境备选：--backend hip，产物目录需与 audiocpp-ffi 默认名一致）"
echo "Rust 侧构建环境变量:"
echo "  AUDIOCPP_SRC=<源码目录> AUDIOCPP_BUILD=<构建目录>"
