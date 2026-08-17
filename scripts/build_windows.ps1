# simple-asr Windows x64 构建脚本（未在真实 Windows 环境验证——首次使用
# 按 CI 日志迭代）。流程对齐 build_macos.sh / build-linux-appimage.sh：
#   引擎（audio.cpp，Vulkan 主路径 / CPU 兜底）→ sherpa-onnx 预编译库
#   → CAM++ 随包 → flutter build windows → 收集产物 + zip 到 dist/。
#
# 前置要求：
#   - Visual Studio 2022 Build Tools（C++ 工作负载 + CMake + Ninja + OpenMP
#     组件；上游 scripts/build_windows.ps1 自动探测 cl/cmake/ninja/mt/rc）
#   - Vulkan 主路径需 Vulkan SDK（glslc，https://vulkan.lunarg.com/）；
#     无 SDK 时 -Backend cpu 兜底（GPU 推理不可用）
#   - Flutter（PATH 上可执行）+ rustup（cargokit 要求）
#
# 用法：powershell -File scripts\build_windows.ps1 [-Backend vulkan|cpu]
# 产物：dist\simple-asr-windows-x64.zip
param(
    [ValidateSet("vulkan", "cpu")]
    [string]$Backend = "vulkan",
    [string]$Models = "qwen3_asr;sortformer_diar;qwen3_forced_aligner"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Src = Join-Path $Root "rust\vendor\audiocpp"
$Preset = "windows-$Backend-release"
$Build = Join-Path $Src "build\$Preset"
$Dist = Join-Path $Root "dist"

function Info($msg) { Write-Host "[win-build] $msg" -ForegroundColor Green }

# ---- 1) audio.cpp 源码（pin 锁定，浅克隆 + 重试）----
$Pin = (Get-Content (Join-Path $Root "rust\vendor\AUDIOCPP_PIN") -Raw).Trim()
if (-not (Test-Path (Join-Path $Src ".git"))) {
    Info "克隆 audio.cpp（pin $Pin）"
    foreach ($i in 1..3) {
        git clone --depth 1 https://github.com/0xShug0/audio.cpp $Src
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -eq 3) { throw "git clone 失败（GitHub 限流？稍后重试）" }
        Start-Sleep -Seconds 10
    }
}
Push-Location $Src
git fetch --depth 1 --force origin $Pin
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "fetch pin $Pin 失败" }
git checkout --force $Pin
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "checkout $Pin 失败" }
Pop-Location

# ---- 2) 引擎（上游脚本：VS/MSVC/Vulkan SDK 自动探测；AVX2 基线保证
#      产物可在任意 x64 机器运行——不跟随构建机的新指令集）----
if (-not (Test-Path (Join-Path $Build "engine_runtime.lib")) ) {
    Info "构建引擎（$Preset，部署内嵌 + AVX2 基线）"
    & (Join-Path $Src "scripts\build_windows.ps1") `
        -Preset $Preset -Target audiocpp_gguf -DeploymentBuild `
        -ModelSet custom -Models $Models -CpuArch avx2
    if ($LASTEXITCODE -ne 0) { throw "引擎构建失败" }
}
foreach ($f in @("engine_runtime.lib", "bin\audiocpp_gguf.exe")) {
    if (-not (Test-Path (Join-Path $Build $f))) {
        throw "引擎产物缺失：$Build\$f"
    }
}

# ---- 3) sherpa-onnx（说话人分离；win-x64 预编译 tar.bz2，Win10+ 自带 tar）----
$Sh = Join-Path $Root "rust\vendor\sherpa-onnx"
$ShLib = Join-Path $Sh "lib"
if (-not (Test-Path (Join-Path $ShLib "sherpa-onnx-c-api.dll"))) {
    Info "拉取 sherpa-onnx win-x64 预编译库"
    $asset = "sherpa-onnx-v1.13.5-win-x64-shared-MD-Release-no-tts-lib"
    $tmp = Join-Path $env:TEMP "$asset.tar.bz2"
    curl.exe -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o $tmp `
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/$asset.tar.bz2"
    if ($LASTEXITCODE -ne 0) { throw "sherpa 下载失败" }
    New-Item -ItemType Directory -Force -Path $Sh | Out-Null
    tar -xjf $tmp -C $Sh
    if ($LASTEXITCODE -ne 0) { throw "sherpa 解压失败" }
    # tar 包内带一层资产名目录（<asset>\lib\...）——拷出到 vendor 约定布局
    # （对齐 fetch-sherpa-onnx.sh 的 cp 语义；v0.1.6 假设解压直出 lib/ 踩空）
    $extracted = Join-Path $Sh $asset
    if (-not (Test-Path $extracted)) { throw "sherpa 包布局异常：$extracted 不存在" }
    New-Item -ItemType Directory -Force -Path $ShLib | Out-Null
    Copy-Item (Join-Path $extracted "lib\*") $ShLib -Force
    if (Test-Path (Join-Path $extracted "include")) {
        Copy-Item (Join-Path $extracted "include") $Sh -Recurse -Force
    }
    Remove-Item $extracted -Recurse -Force
}
if (-not (Test-Path (Join-Path $ShLib "sherpa-onnx-c-api.dll"))) {
    throw "sherpa 库布局异常：$ShLib（缺 sherpa-onnx-c-api.dll）"
}

# ---- 4) CAM++ 声纹模型（随包，exe 同级 models\）----
$Bundled = Join-Path $Root "rust\vendor\bundled-models"
$Campp = Join-Path $Bundled "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
if (-not (Test-Path $Campp)) {
    Info "拉取 CAM++ 声纹模型（随包）"
    New-Item -ItemType Directory -Force -Path $Bundled | Out-Null
    curl.exe -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o $Campp `
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
    if ($LASTEXITCODE -ne 0) { throw "CAM++ 下载失败" }
}

# ---- 5) flutter build windows（cargokit 经 env 链接真引擎）----
$env:AUDIOCPP_SRC = $Src
$env:AUDIOCPP_BUILD = $Build
Info "flutter build windows（引擎：$Build）"
Push-Location (Join-Path $Root "app")
flutter config --enable-windows-desktop | Out-Null
flutter build windows --release
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "flutter build 失败" }
Pop-Location

$Out = Join-Path $Root "app\build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $Out "simple_asr.exe"))) { throw "产物缺失：$Out" }

# ---- 6) 收集：Q8 转换工具 + sherpa dll + CAM++（exe 同级）----
Copy-Item (Join-Path $Build "bin\audiocpp_gguf.exe") $Out -Force
foreach ($dll in @("sherpa-onnx-c-api.dll", "onnxruntime.dll")) {
    $p = Join-Path $ShLib $dll
    if (Test-Path $p) { Copy-Item $p $Out -Force }
    else { Info "warn: $dll 不在预编译包内（onnxruntime 可能内嵌）" }
}
# sherpa dll 的间接依赖（同包内的 MSVC 运行库伴生 dll，存在则一并带走）
Get-ChildItem $ShLib -Filter "*.dll" | Where-Object {
    $_.Name -notin @("sherpa-onnx-c-api.dll", "onnxruntime.dll")
} | ForEach-Object { Copy-Item $_.FullName $Out -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Out "models") | Out-Null
Copy-Item $Campp (Join-Path $Out "models") -Force

# ---- 7) zip 发布（保留目录名，解压即用）----
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Zip = Join-Path $Dist "simple-asr-windows-x64.zip"
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path $Out -DestinationPath $Zip
Info "完成：$Zip（$([Math]::Round((Get-Item $Zip).Length / 1MB, 1)) MB）"
