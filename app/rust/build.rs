// asr_bridge 构建附加参数。sherpa-onnx 共享库（@rpath install_name）的
// 运行期解析：debug 构建（flutter run 直跑 .app）加 vendor 绝对 rpath；
// release 打包由 build_macos.sh 把 dylib 拷进 Contents/Frameworks（Runner
// 自带 @executable_path/../Frameworks rpath），无需绝对路径。

fn main() {
    let profile = std::env::var("PROFILE").unwrap_or_default();
    if profile != "debug" {
        return;
    }
    let vendor = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../rust/vendor/sherpa-onnx/lib");
    if vendor.is_dir() {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", vendor.display());
    }
}
