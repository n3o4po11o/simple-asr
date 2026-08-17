#!/usr/bin/env bash
# macOS .app 构建：flutter build macos + audio.cpp Metal 引擎（audiocpp-ffi
# 经 AUDIOCPP_SRC/BUILD 链接真引擎）+ audiocpp_gguf 转换工具入包
#（engine.rs 按可执行文件同级查找，Q8 一键转换用）。
# 产物复制到仓库根目录 dist/（与 Linux AppImage 同一发布目录）。
# 用法: bash scripts/build_macos.sh [--debug]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/rust/vendor/audiocpp"
BUILD="$SRC/build/macos-metal-release"
DIST="$ROOT/dist"

[ -f "$BUILD/libengine_runtime.a" ] || {
  echo "未找到 Metal 引擎树：$BUILD" >&2
  echo "先运行: bash scripts/fetch-audiocpp.sh && (cd $SRC && bash scripts/build_metal.sh --model-set custom --models qwen3_asr --target audiocpp_cli --target audiocpp_gguf)" >&2
  exit 1
}

MODE="release"
[ "${1:-}" = "--debug" ] && MODE="debug"
# xcodebuild -configuration 与产物目录用首字母大写；不能用 ${MODE^}（Bash 4+，
# macOS 系统 bash 是 3.2——曾致 pods 预构建被静默跳过）
CFG="Release"
[ "$MODE" = "debug" ] && CFG="Debug"

export AUDIOCPP_SRC="$SRC"
export AUDIOCPP_BUILD="$BUILD"

cd "$ROOT/app"
# 清洁构建后需先预构建 pods 框架（Runner 不直接依赖 pods 目标，Xcode 26 的
# 规划期模块解析要求产物已存在；用与 flutter 相同的 workspace/参数）
for s in desktop_drop file_selector_macos url_launcher_macos; do
  (cd macos && xcodebuild -workspace Runner.xcworkspace -scheme "$s" \
    -configuration "$CFG" -derivedDataPath "$ROOT/app/build/macos" \
    -destination generic/platform=macOS \
    OBJROOT="$ROOT/app/build/macos/Build/Intermediates.noindex" \
    SYMROOT="$ROOT/app/build/macos/Build/Products" \
    COMPILER_INDEX_STORE_ENABLE=NO build >/dev/null 2>&1) \
    || echo "warn: pods 预构建 $s 失败（若为增量构建可忽略）"
done

echo "== flutter build macos ($MODE)，引擎: $BUILD =="
flutter build macos --${MODE}

APP="$(ls -d build/macos/Build/Products/$CFG/*.app | head -1)"
echo "== 打包 audiocpp_gguf → $APP/Contents/MacOS/ =="
cp "$BUILD/bin/audiocpp_gguf" "$APP/Contents/MacOS/"

# sherpa-onnx 说话人分离（@rpath install_name；Runner 自带 Frameworks rpath）
SH="$ROOT/rust/vendor/sherpa-onnx/lib"
if [ -d "$SH" ]; then
  echo "== 打包 sherpa-onnx dylib → $APP/Contents/Frameworks/ =="
  mkdir -p "$APP/Contents/Frameworks"
  cp "$SH/libsherpa-onnx-c-api.dylib" "$APP/Contents/Frameworks/"
  cp "$SH/libonnxruntime.1.17.1.dylib" "$APP/Contents/Frameworks/"
fi

# CAM++ 声纹模型随包（~27MB；Resources 布局——codesign 不允许 MacOS/ 下
# 放数据文件，engine 侧按 exe 同级 models/ 与 ../Resources/models/ 双候选
# 解析）。缺则拉取，幂等。
BUNDLED="$ROOT/rust/vendor/bundled-models"
CAMPP="$BUNDLED/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
if [ ! -f "$CAMPP" ]; then
  echo "== 拉取 CAM++ 声纹模型（随包）=="
  mkdir -p "$BUNDLED"
  for i in 1 2 3 4 5; do
    if curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors -o "$CAMPP" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"; then
      break
    fi
    [ "$i" = 5 ] && exit 1
    echo "CAM++ 下载失败（第 $i 轮），15s 后重试" >&2
    sleep 15
  done
fi
mkdir -p "$APP/Contents/Resources/models"
cp "$CAMPP" "$APP/Contents/Resources/models/"
# flutter 已签名后才拷入转换工具，需重新 ad-hoc 签名（否则封签失效）
codesign --force -s - "$APP"

# ditto 保留 bundle 元数据/签名；覆盖旧产物
mkdir -p "$DIST"
rm -rf "$DIST/$(basename "$APP")"
ditto "$APP" "$DIST/$(basename "$APP")"
echo "完成：$DIST/$(basename "$APP")（$(du -sh "$DIST/$(basename "$APP")" | cut -f1)）"
