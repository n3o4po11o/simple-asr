#!/usr/bin/env bash
# 拉取 sherpa-onnx 预编译库（说话人分离：sortformer 分段 + CAM++ 声纹 + 聚类）
# 到 rust/vendor/sherpa-onnx/{lib,include}。模型文件不在此脚本范围——
# 由 App 内置下载器（asr-core download.rs）按需拉取。
# 用法: bash scripts/fetch-sherpa-onnx.sh [version]   默认 1.13.5
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${1:-1.13.5}"
DEST="$ROOT/rust/vendor/sherpa-onnx"

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ASSET="sherpa-onnx-v${V}-osx-arm64-shared-no-tts-lib" ;;
  Darwin/x86_64) ASSET="sherpa-onnx-v${V}-osx-x64-shared-no-tts-lib" ;;
  Linux/x86_64)  ASSET="sherpa-onnx-v${V}-linux-x64-shared-no-tts-lib" ;;
  Linux/aarch64) ASSET="sherpa-onnx-v${V}-linux-aarch64-shared-no-tts-lib" ;;
  *) echo "不支持的平台: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
# 头文件包（版本随主包发布；部分平台/版本没有，见下方可选下载）
ORT_TAG="v${V}"
ORT_VER="1.17.1"
case "$(uname -s)" in
  Darwin) ORT="sherpa-onnx-v${V}-onnxruntime-${ORT_VER}-osx-$(uname -m | sed 's/arm64/arm64/;s/x86_64/x64/')-shared" ;;
  Linux)  ORT="sherpa-onnx-v${V}-onnxruntime-${ORT_VER}-linux-$(uname -m | sed 's/x86_64/x64/;s/aarch64/aarch64/')-shared" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/${ORT_TAG}"
echo "== 下载 ${ASSET}（+ 可选头文件包 ${ORT}）=="
# -f：HTTP 错误不落盘（否则 "Not Found" 错误页会被当压缩包）；--retry-all-errors：
# CI 偶发断流曾产出半截文件且 curl exit 0、tar exit 2
CURL=(curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors)
"${CURL[@]}" -o "$TMP/a.tar.bz2" "$BASE/$ASSET.tar.bz2"

mkdir -p "$DEST"
rm -rf "$DEST/lib" "$DEST/include" "$DEST"/sherpa-onnx-v*
tar xjf "$TMP/a.tar.bz2" -C "$DEST"
# 主包自带全部运行库（onnxruntime + c-api；v1.13.5 各平台核实一致）
mkdir -p "$DEST/lib" "$DEST/include"
cp "$DEST/$ASSET"/lib/* "$DEST/lib/"

# 头文件包可选：如 v1.13.5 linux-x64 没有独立 onnxruntime 包——
# sherpa-ffi 只链接库不编头文件，缺失时警告跳过。macOS 上该包还含
# 版本化 onnxruntime dylib，存在则合并（保持历史行为）
if "${CURL[@]}" -o "$TMP/b.tar.bz2" "$BASE/$ORT.tar.bz2"; then
  tar xjf "$TMP/b.tar.bz2" -C "$DEST"
  cp "$DEST/$ORT"/lib/* "$DEST/lib/"
  cp -R "$DEST/$ORT"/include/. "$DEST/include/"
else
  echo "warn: 头文件包不存在（${ORT}），跳过——sherpa-ffi 仅链接库"
fi
rm -rf "$DEST/$ASSET" "$DEST/$ORT"
echo "完成: $DEST/lib"
ls "$DEST/lib"
