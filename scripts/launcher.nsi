; simple-asr Windows Portable 单文件（NSIS 静默自解压运行器）。
; 用法：仓库根目录执行 makensis scripts\launcher.nsi（build_windows.ps1
; 第 8 步自动调用；路径相对仓库根）。
; 行为：双击 → 解压到 %TEMP%\ns*.tmp\app（每次运行独立目录）→ 启动
; simple_asr.exe 并等待 → 应用退出后临时目录由 NSIS 自动清理。
; 取舍：每次启动先解压 ~85MB（SSD 约 1-3 秒）；无签名单 exe 可能被
; SmartScreen 提示（点「仍要运行」）；设置/模型缓存在用户目录，跨次
; 运行保留，不随临时目录销毁。zip 产物保留作透明排障入口。

RequestExecutionLevel user
SilentInstall silent
Unicode true
SetCompressor /SOLID lzma
!ifndef APP_DIR
    !error "用法：makensis -DAPP_DIR=<Release 绝对路径> -DOUT_EXE=<产物绝对路径>（build_windows.ps1 第 8 步传入）"
!endif
OutFile "${OUT_EXE}"

Section
    InitPluginsDir
    SetOutPath "$PLUGINSDIR\app"

    ; 嵌入 Release 全部产物（exe/dll/data/models）。用 * 而非 *.*——
    ; flutter_assets 存在无扩展名文件
    File /r "${APP_DIR}\*"

    ; 运行主程序并等待；退出后 $PLUGINSDIR 由 NSIS 自动清理
    ExecWait '"$PLUGINSDIR\app\simple_asr.exe"'
SectionEnd
