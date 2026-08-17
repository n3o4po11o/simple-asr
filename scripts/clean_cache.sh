#!/usr/bin/env bash
# 清除编译缓存（回收磁盘空间 / 排查增量构建异常）。
# 用法: bash scripts/clean_cache.sh [--vendor-build] [--all] [--dry-run]
#   默认            Flutter/Rust 增量缓存（下次构建全量重编，约 4-5 GB）
#   --vendor-build  追加 audio.cpp 引擎**编译产物**（rust/vendor/audiocpp/build，
#                   源码保留——下次本地重编，无需重新下载）
#   --all           连 vendor 源码与预编译库一起清（下次构建需重跑
#                   fetch-audiocpp.sh / fetch-sherpa-onnx.sh，走网络下载）
#   --dry-run       只显示将删除的内容，不实际删除
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VENDOR_BUILD=0
ALL=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --vendor-build) VENDOR_BUILD=1 ;;
    --all) ALL=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "未知参数：${arg}（可用 --vendor-build / --all / --dry-run）" >&2; exit 1 ;;
  esac
done

# 档一：增量缓存（日常清理即可释放大部分空间）
CLEAN=(
  "app/build"                    # Flutter 构建产物
  "app/macos/build"              # Xcode DerivedData 本地日志
  "app/.dart_tool"               # Dart 分析/代码生成缓存
  "app/rust/target"              # asr_bridge（cargokit）产物
  "rust/target"                  # workspace（asr-core 等）产物
)

# 档二：引擎编译产物（源码保留，本地重编即可）
if [ "$VENDOR_BUILD" = 1 ]; then
  CLEAN+=(
    "rust/vendor/audiocpp/build"        # CMake 构建树（含预编译引擎静态库）
    "rust/vendor/audiocpp/build-metal.log"
  )
fi

# 档三：连源码与下载物一起清（需网络重新 fetch）
if [ "$ALL" = 1 ]; then
  CLEAN+=(
    "rust/vendor/audiocpp"       # 引擎源码（fetch-audiocpp.sh）
    "rust/vendor/sherpa-onnx"    # 声纹预编译库（fetch-sherpa-onnx.sh）
    "dist/AppDir"                # Linux 打包中间产物
  )
fi

# 删除单个目录，容忍瞬时占用（构建进程正在写入时 rm 会报
# Directory not empty）：小睡后重试一次。
rm_one() {
  rm -rf "$1" 2>/dev/null && return 0
  sleep 1
  rm -rf "$1" 2>/dev/null && return 0
  return 1
}

failed=()
for rel in "${CLEAN[@]}"; do
  dir="$ROOT/$rel"
  [ -e "$dir" ] || continue
  size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] 将删除 ${rel}（${size}）"
    continue
  fi
  if rm_one "$dir"; then
    echo "已删除 ${rel}（${size}）"
  else
    failed+=("$rel")
    echo "未能删除 ${rel}（${size}）" >&2
  fi
done

if [ "$DRY" = 1 ]; then
  echo "（--dry-run：未做任何删除）"
elif [ "${#failed[@]}" -gt 0 ]; then
  echo
  echo "以下目录被占用未删干净（多半有 app/Xcode/flutter 构建进程仍在运行），关闭后重跑本脚本：" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
else
  echo "完成。--vendor-build 清引擎编译产物（保留源码），--all 连源码全清。"
fi
