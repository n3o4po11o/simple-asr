// sherpa-ffi 构建：链接预编译的 libsherpa-onnx-c-api 共享库。
// 库由 scripts/fetch-sherpa-onnx.sh 拉取到 rust/vendor/sherpa-onnx/
//（lib/ + include/，按平台选资产）。缺库时编译 C 桩，链接不失败、
// 运行期报错——与 audiocpp-ffi 的缺省行为一致。

use std::env;
use std::path::PathBuf;

fn main() {
    let vendor = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../vendor/sherpa-onnx");
    let lib = vendor.join("lib");
    let dylib = lib.join("libsherpa-onnx-c-api.dylib");
    let so = lib.join("libsherpa-onnx-c-api.so");
    // Windows：k2-fsa win 包的 lib/ 含 sherpa-onnx-c-api.lib（导入库）+ dll
    let dll = lib.join("sherpa-onnx-c-api.dll");

    if !dylib.exists() && !so.exists() && !dll.exists() {
        println!("cargo:warning=SHERPA_STUB: 未找到预编译库，编译桩（先运行 scripts/fetch-sherpa-onnx.sh 或 build_windows.ps1）");
        let mut build = cc::Build::new();
        build.file("cshim/stub.c").compile("sherpa_stub");
        return;
    }
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=dylib=sherpa-onnx-c-api");
    // 运行期 @rpath 解析由消费方负责：asr_bridge 的 build.rs（debug 直跑）
    // 与打包脚本（.app Frameworks / AppImage lib / Windows exe 同目录 dll）。
}
