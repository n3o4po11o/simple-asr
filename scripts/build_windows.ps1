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

# VC++ 运行库随包：asr_bridge.dll 导入 MSVCP140/VCRUNTIME140/VCRUNTIME140_1/
# VCOMP140（OpenMP）——干净系统无 redist 时 DLL 加载失败 = 启动即闪退
# （v0.1.7 真机首验实测）。
# 取材双保险：① vswhere 定位 VS 安装树的 Redist 目录（edition/工具集版本
# 无关——硬编码 ...\2022\... 在新版 runner 镜像上整树不存在，v0.1.8/v0.1.9
# 实测连诊断清单都打不出）；② 未命中则静默安装 VC++ redist 本体，从
# System32 拷同名 DLL（redist 文件即官方可再分发件）。
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$crt = $null; $omp = $null
if (Test-Path $vswhere) {
    $install = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
    if ($install) {
        $redistRoot = Join-Path $install "VC\Redist\MSVC"
        $crt = Get-Item "$redistRoot\*\x64\Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        $omp = Get-Item "$redistRoot\*\x64\Microsoft.VC*.OpenMP" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
    }
}
if ($crt -and $omp) {
    Copy-Item (Join-Path $crt.FullName "*") $Out -Force
    Copy-Item (Join-Path $omp.FullName "*") $Out -Force
    Info "VC++ 运行库已随包（VS Redist：$($crt.Parent.Parent.Name)）"
} else {
    Info "VS Redist 目录未命中——安装 VC++ redist 后从 System32 取"
    $redistExe = "$env:TEMP\vc_redist.x64.exe"
    curl.exe -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o $redistExe `
        "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    if ($LASTEXITCODE -ne 0) { throw "vc_redist 下载失败" }
    $p = Start-Process -FilePath $redistExe -ArgumentList "/install","/quiet","/norestart" `
        -Wait -PassThru
    if ($p.ExitCode -notin @(0, 3010)) { throw "vc_redist 安装失败 exit=$($p.ExitCode)" }
    foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "vcomp140.dll")) {
        $src = Join-Path $env:SystemRoot "System32\$dll"
        if (-not (Test-Path $src)) { throw "System32 缺 $dll（redist 安装后仍未就位）" }
        Copy-Item $src $Out -Force
    }
    Info "VC++ 运行库已随包（vc_redist + System32）"
}

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

# ---- 8) Portable 单文件（NSIS 静默自解压：解临时目录→运行→退出清理）----
# makensis 缺席时降级跳过（CI 已装 NSIS 并入 PATH；本机 choco/winget 装，
# 默认安装路径不在 PATH 时也兜底直取）
$mkCmd = Get-Command makensis -ErrorAction SilentlyContinue
$makensis = if ($mkCmd) { $mkCmd.Source }
elseif (Test-Path "C:\Program Files (x86)\NSIS\makensis.exe") {
    "C:\Program Files (x86)\NSIS\makensis.exe"
} else { $null }
if (-not $makensis) {
    Info "warn: makensis 不可用，跳过单文件产物（choco/winget 安装 NSIS 后重跑）"
} else {
    Info "构建 Portable 单文件（NSIS）"
    $Portable = Join-Path $Dist "simple-asr-windows-x64-portable.exe"
    if (Test-Path $Portable) { Remove-Item $Portable }
    # 路径经 -D 传绝对值：NSIS 的 File/OutFile 相对路径按 .nsi 所在目录解析
    # （非 makensis 工作目录——v0.1.14 实测 "no files found"），彻底消除歧义。
    # 退出码 0=成功 1=警告或中止（真实错误也可能 1，靠下方产物存在性兜底）2=错误
    # 参数整体入数组、末位 splat——PS 5.1 对原生命令参数列表中段插数组
    # 展开有解析坑（v0.1.16 实测：后续参数丢失，makensis 读 <stdin> 报
    # "Can't open script D"）
    $AppIcon = Join-Path $Root "app\windows\runner\resources\app_icon.ico"
    $nsisArgs = @("-DAPP_DIR=$Out", "-DOUT_EXE=$Portable")
    if (Test-Path $AppIcon) { $nsisArgs += "-DAPP_ICON=$AppIcon" }
    $nsisArgs += "scripts\launcher.nsi"
    & $makensis @nsisArgs
    if ($LASTEXITCODE -ge 2) { throw "makensis 失败（exit=$LASTEXITCODE）" }
    if ($LASTEXITCODE -eq 1) { Info "makensis exit=1（警告或中止，产物存在性为准）" }
    if (-not (Test-Path $Portable)) { throw "单文件产物缺失：$Portable" }
    Info "完成：$Portable（$([Math]::Round((Get-Item $Portable).Length / 1MB, 1)) MB）"
}
