#!/usr/bin/env bash
# Linux AppImage 构建。自包含：系统依赖、Flutter SDK、linuxdeploy
# 工具全部落在项目目录内（建议在容器/隔离环境运行，不污染宿主机）。
#
# 用法:  bash scripts/build-linux-appimage.sh [项目根]
# 产物:  <项目根>/dist/simple-asr-linux-<arch>.AppImage
# 环境变量:
#   FLUTTER_MIRROR   可选，Flutter SDK git 克隆镜像（默认 GitHub 官方）
#   FLUTTER_VERSION  可选，pin Flutter 版本 tag（如 3.44.8；缺省跟踪 stable）
#   CARGO_MIRROR     可选，rust crates 镜像：ustc（默认，境内）/ none（官方源）
# 支持 Fedora（dnf）与 Debian/Ubuntu（apt）两类构建环境。
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || { echo "仅支持 x86_64（当前 ${ARCH}）"; exit 1; }
# Flutter Linux 产物目录用 x64/arm64 命名，与 uname 不同
FLUTTER_ARCH="x64"

log() { printf '\033[1;32m[appimage]\033[0m %s\n' "$*"; }

# GitHub 下载统一重试：共享 runner 出口 IP 的二级限流会以 429/503/连接
# 重置（SIGPIPE=141）等形态间歇出现，curl 自带 --retry 覆盖不全——外层
# 再宽容五轮，间隔 15s
fetch_retry() {
  local url="$1" dest="$2" i rc
  for i in 1 2 3 4 5; do
    if curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors -o "$dest" "$url"; then
      return 0
    fi
    rc=$?
    log "下载失败（exit $rc，第 $i/5 轮），15s 后重试：$url"
    sleep 15
  done
  return 1
}

# ---- 0) cargo 镜像（项目内 CARGO_HOME，不动宿主 ~/.cargo）----
export CARGO_HOME="$ROOT/.cargo-home"
mkdir -p "$CARGO_HOME"
if [ "${CARGO_MIRROR:-ustc}" != "none" ] && ! grep -q "ustc" "$CARGO_HOME/config.toml" 2>/dev/null; then
  cat > "$CARGO_HOME/config.toml" <<'EOF'
[source.crates-io]
replace-with = "ustc"

[source.ustc]
registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"
EOF
fi

# ---- 1) 系统依赖（幂等；CI 中通常已预装，此处兜底）----
SUDO=""
command -v sudo >/dev/null 2>&1 && SUDO="sudo"
if command -v dnf >/dev/null 2>&1; then
  PKGS=(clang cmake ninja-build gtk3-devel pkgconf pcre2-devel)
  MISSING=()
  for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
  if [ ${#MISSING[@]} -gt 0 ]; then
    log "安装构建依赖：${MISSING[*]}"
    $SUDO dnf install -y -q "${MISSING[@]}"
  fi
elif command -v apt-get >/dev/null 2>&1; then
  PKGS=(clang cmake ninja-build libgtk-3-dev pkg-config libpcre2-dev)
  MISSING=()
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
  if [ ${#MISSING[@]} -gt 0 ]; then
    log "安装构建依赖：${MISSING[*]}"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq --no-install-recommends "${MISSING[@]}"
  fi
else
  echo "不支持的包管理器（需 dnf 或 apt-get）" >&2
  exit 1
fi

# ---- 2) Flutter SDK（stable，落在项目内）----
# 境内网络：Flutter 工件（Dart SDK/engine）走官方中国镜像，否则
# storage.googleapis.com 慢到不可用。可用环境变量覆盖。
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
FLUTTER_DIR="$ROOT/.flutter-sdk"
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  log "获取 Flutter stable → $FLUTTER_DIR"
  git clone --depth 1 -b stable "${FLUTTER_MIRROR:-https://github.com/flutter/flutter.git}" "$FLUTTER_DIR"
fi
# 版本 pin：浅 fetch 指定 tag（tag 名与 flutter --version 一致，如 3.44.8）
if [ -n "${FLUTTER_VERSION:-}" ]; then
  (cd "$FLUTTER_DIR" \
    && git fetch --depth 1 --force origin "refs/tags/${FLUTTER_VERSION}:refs/tags/${FLUTTER_VERSION}" \
    && git checkout --force -q "${FLUTTER_VERSION}")
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
flutter --version 2>/dev/null | head -1

# ---- 2.5) audio.cpp 引擎（可选）：AUDIOCPP_SRC + AUDIOCPP_BUILD 传入时启用 ----
# audiocpp-ffi 缺 AUDIOCPP_BUILD 时编译桩（candle 主引擎不受影响）。
if [ -n "${AUDIOCPP_BUILD:-}" ] && [ -f "${AUDIOCPP_BUILD:-}/libengine_runtime.a" ]; then
  : "${AUDIOCPP_SRC:?AUDIOCPP_BUILD 需与 AUDIOCPP_SRC 同时提供}"
  log "audio.cpp 引擎已启用：$AUDIOCPP_BUILD"
else
  log "未提供 AUDIOCPP_BUILD：仅构建 candle 引擎（audiocpp 为桩）"
  unset AUDIOCPP_BUILD AUDIOCPP_SRC
fi

# ---- 3) Flutter Linux Release 构建（cargokit 随之编译 Rust dylib）----
cd "$ROOT/app"
flutter config --enable-linux-desktop >/dev/null
flutter pub get
flutter build linux --release
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
test -x "$BUNDLE/simple_asr" || { echo "构建产物缺失：$BUNDLE/simple_asr"; exit 1; }
log "Flutter bundle 完成：$BUNDLE"

# ---- 4) linuxdeploy + AppDir ----
# 磁盘水位监控（runner ~14G 可用：flutter SDK 3G + cargo target + 引擎树
# 占大头；写满会让 tee 崩掉 → 全管道 SIGPIPE=141，此前误诊为网络限流）
log "磁盘水位：$(df -h "$ROOT" | tail -1 | awk '{print $4 " free"}')"
TOOLS="$ROOT/.tools"; mkdir -p "$TOOLS"
LD="$TOOLS/linuxdeploy-$ARCH.AppImage"
if [ ! -f "$LD" ]; then
  log "下载 linuxdeploy"
  fetch_retry "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage" "$LD"
  chmod +x "$LD"
fi

APPDIR="$ROOT/dist/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
# Flutter bundle 结构：可执行文件与 lib/、data/ 必须保持同级
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# 收录策略：宿主只承担「GUI 桌面必自带的栈」——GTK3/glib/pango/X11/Wayland
# 客户端/音频/系统服务（GTK3 自 2019 起 ABI 冻结，Ubuntu24.04/Debian12/
# Bazzite/SteamOS 等桌面发行版全部自带）与图形驱动接口（GL/EGL/gbm/drm，
# 必须匹配宿主驱动）。其余依赖（媒体/编解码/推理/引擎库、libbz2/brotli
# 等 SONAME 跨发行版分歧或非必装的库）全部随包。
# 注意：宿主 GTK 走宿主 libstdc++（Fedora 系 GTK 需要新版 GLIBCXX 符号，
# 捆绑 Debian 的 libstdc++ 会符号冲突），故 libstdc++ 也在宿主侧——
# glibc≥2.36 的人群宿主 libstdc++ 均满足构建基线。
is_host_only() {
  case "$1" in
    ld-linux*|libc.so*|libm.so*|libmvec*|libdl*|libpthread*|librt*|libresolv*|libanl*|libnsl*|libutil*|libcrypt*|libgcc_s*|libstdc++*|libGL*|libEGL*|libglapi*|libgbm*|libdrm*|libz.so*|libzstd*|liblzma*|liblz4*|libexpat*|libffi*|libpcre2*|libmd*|libacl*|libattr*|libcap*|libselinux*|libuuid*|libblkid*|libmount*|libseccomp*|libkeyutils*|libdbus*|libsystemd*|libudev*|libglib*|libgobject*|libgio*|libgmodule*|libgthread*|libpango*|libcairo*|libgdk*|libgtk*|libharfbuzz*|libfreetype*|libfontconfig*|libpixman*|libpng*|libjpeg*|libtiff*|libwebp*|libgraphite2*|libjbig*|liblcms*|libX11*|libXau*|libXdmcp*|libXext*|libXrender*|libxcb*|libxkbcommon*|libwayland*|libICE*|libSM*|libogg*|libvorbis*|libflac*|libopus*|libspeex*|libtheora*|libsndfile*|libsoxr*|libnuma*|libpipewire*|libspa*|libjack*|libpulse*|libasound*) return 0 ;;
    *) return 1 ;;
  esac
}
# libmpv 本体先入包（media_kit 运行时 dlopen，linuxdeploy/闭包收集均从
# NEEDED 看不见它）；其闭包由统一收集处理。路径经 ldconfig 解析
MPV_LIB="$({ ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | awk '/libmpv\.so\.2 \(/{print $NF; exit}')"
if [ -f "$APPDIR/usr/bin/lib/libmedia_kit_libs_linux_plugin.so" ] && [ -n "$MPV_LIB" ]; then
  log "打包 libmpv 播放内核（闭包由统一收集处理）"
  cp -Ln "$MPV_LIB" "$APPDIR/usr/bin/lib/$(basename "$MPV_LIB")" 2>/dev/null || true
fi

# LLVM OpenMP 运行库（audiocpp 引擎 __kmpc_*；ROCm 收集跳过时也必须打包，
# 宿主机未必有 libomp——曾遗漏导致 ldd not found）。soname 随编译器封装而异
# （Fedora libomp.so.1 / Debian libomp5.so.14），按 libasr_bridge 的实际
# NEEDED 经 ldd 解析，不再依赖发行版固定路径。
OMP_PATH="$(ldd "$APPDIR/usr/bin/lib/libasr_bridge.so" 2>/dev/null | awk '/libomp/{print $3; exit}')"
if [ -n "$OMP_PATH" ] && [ -f "$OMP_PATH" ]; then
  cp -Ln "$OMP_PATH" "$APPDIR/usr/bin/lib/"
fi

# Q8 一键转换工具（engine.rs 按可执行文件同级查找 audiocpp_gguf）
if [ -n "${AUDIOCPP_BUILD:-}" ] && [ -x "$AUDIOCPP_BUILD/bin/audiocpp_gguf" ]; then
  cp "$AUDIOCPP_BUILD/bin/audiocpp_gguf" "$APPDIR/usr/bin/"
  log "已打包 audiocpp_gguf（Q8 转换工具）"
fi

# sherpa-onnx 说话人分离（预编译共享库，说话人分离开关用；libasr_bridge.so
# 由 dlopen 加载，linuxdeploy 追不到 → 显式拷入。lib 目录名随 bundle_lib_dir）
SH_LIB="$ROOT/rust/vendor/sherpa-onnx/lib"
if [ -d "$SH_LIB" ]; then
  for f in "$SH_LIB"/libsherpa-onnx-c-api.so* "$SH_LIB"/libonnxruntime.so*; do
    [ -e "$f" ] && cp -Ln "$f" "$APPDIR/usr/bin/lib/"
  done
  log "已打包 sherpa-onnx 分离库"
fi

# CAM++ 声纹模型随包（~27MB，engine 侧 exe 同级 models/ 解析；境内用户
# 免直连 GitHub）。缺则拉取，幂等。
BUNDLED="$ROOT/rust/vendor/bundled-models"
CAMPP="$BUNDLED/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
if [ ! -f "$CAMPP" ]; then
  log "拉取 CAM++ 声纹模型（随包）"
  mkdir -p "$BUNDLED"
  fetch_retry "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx" "$CAMPP"
fi
mkdir -p "$APPDIR/usr/bin/models"
cp "$CAMPP" "$APPDIR/usr/bin/models/"

bundle_lib_dir="$APPDIR/usr/bin/lib"

# 统一闭包收集（可移动版核心）：主程序 + bundle 内已有全部库（含 dlopen
# 系：libmpv/libasr_bridge/sherpa——对 ldd 闭包收集器不可见的先手工入包了）
# 的全部依赖，除 is_host_only（glibc + 图形驱动接口）外一律随包。
collect_bundle_closure() {
  local round added so base target
  for round in 1 2 3 4 5; do
    added=0
    for target in "$APPDIR/usr/bin/simple_asr" "$bundle_lib_dir"/*.so*; do
      [ -f "$target" ] || continue
      while IFS= read -r so; do
        [ -f "$so" ] || continue
        base="$(basename "$so")"
        is_host_only "$base" && continue
        if [ ! -e "$bundle_lib_dir/$base" ]; then
          cp -Ln "$so" "$bundle_lib_dir/$base" && added=1
        fi
      done < <(LD_LIBRARY_PATH="$bundle_lib_dir" ldd "$target" 2>/dev/null | awk '/=> \// {print $3}')
    done
    [ "$added" -eq 0 ] && break
  done
}
log "统一闭包收集（除 glibc/图形驱动接口外全部随包）"
collect_bundle_closure

# 打包自检（全 bundle 闭包校验）：bundle 内每个库 + 主程序的依赖必须全部
# 可解析，且「从系统路径解析」的必须属于 is_host_only（桌面自带栈）——
# 否则在不满足假设的宿主上 dlopen 失败。大声失败好过静默带病。
bundle_check_failed=0
for f in "$APPDIR/usr/bin/simple_asr" "$bundle_lib_dir"/*.so*; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    dep_name="$(printf '%s\n' "$line" | awk '{print $1}')"
    dep_path="$(printf '%s\n' "$line" | awk '{print $3}')"
    if [ "$dep_path" = "not" ]; then
      echo "错误：$(basename "$f") 依赖未解析：$line" >&2
      bundle_check_failed=1
    elif ! [[ "$dep_path" == "$bundle_lib_dir"* ]] && ! is_host_only "$dep_name"; then
      echo "错误：$(basename "$f") 依赖 $dep_name 未随包（解析自 $dep_path）" >&2
      bundle_check_failed=1
    fi
  done < <(LD_LIBRARY_PATH="$bundle_lib_dir" ldd "$f" 2>/dev/null | awk '/=>/ {print}')
done
if [ "$bundle_check_failed" -ne 0 ]; then
  exit 1
fi
log "打包自检：全 bundle 依赖闭包校验通过（宿主仅承担桌面自带栈与驱动接口）"

# Vulkan loader 特殊处理：不直接进 LD 路径，运行时宿主优先。loader 与 ICD
# 是发行版配套关系——捆绑旧 loader（Debian 1.3.239）撞新 ICD 会 NULL 函数
# 指针段错误（bazzite/RADV 实测）；宿主没有 loader 的机器必然也没有 ICD，
# 无错配可能，才用包内 fallback（引擎 CPU 回退路径）。
mkdir -p "$APPDIR/usr/bin/lib-vulkan-fallback"
for f in "$bundle_lib_dir"/libvulkan.so*; do
  [ -e "$f" ] && mv "$f" "$APPDIR/usr/bin/lib-vulkan-fallback/"
done

# 关键补丁：linuxdeploy 自己的依赖部署不认识上面的 fallback 约定——它会
# 重新扫描 ELF 闭包，把构建环境的 libvulkan.so.1 再部署进 usr/lib（AppRun
# 的 LD_LIBRARY_PATH 里 usr/lib 排最前）→ 宿主 loader 被遮蔽，宿主优先
# 设计整个失效（v0.1.0 在 bazzite 崩溃的实锤路径）。排除之，让运行期
# 解析落到宿主系统路径或 lib-vulkan-fallback。
VULKAN_EXCLUDE_FLAG="--exclude-library=libvulkan.so.1"

cat > "$APPDIR/simple-asr.desktop" <<'EOF'
[Desktop Entry]
Name=simple-asr
Comment=Qwen3-ASR speech to text
Exec=simple_asr
Icon=simple-asr
Terminal=false
Type=Application
Categories=AudioVideo;Utility;
EOF
cp "$ROOT/scripts/simple-asr-512.png" "$APPDIR/simple-asr.png"

# 容器内无 FUSE：解包运行 AppImage 工具
export APPIMAGE_EXTRACT_AND_RUN=1
log "打包 AppImage（含 Rust 依赖树全量编译，首次较慢）"
cd "$ROOT"
"$LD" --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/simple_asr" \
  $VULKAN_EXCLUDE_FLAG \
  --desktop-file "$APPDIR/simple-asr.desktop" \
  --icon-file "$APPDIR/simple-asr.png" \
  --custom-apprun "$ROOT/scripts/AppRun-linux" \
  --output appimage

mkdir -p "$ROOT/dist"
# linuxdeploy 把产物写到当前目录（${ROOT}）
OUT="$(ls -t "$ROOT"/*.AppImage 2>/dev/null | head -1)"
FINAL="$ROOT/dist/simple-asr-linux-$ARCH.AppImage"
[ -n "$OUT" ] && mv "$OUT" "$FINAL"
rm -rf "$APPDIR"
log "完成：${FINAL}（$(du -h "$FINAL" | cut -f1)）"
