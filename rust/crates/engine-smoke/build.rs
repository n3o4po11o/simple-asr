// engine-smoke 链接附加参数。
// macOS：引擎 ObjC 对象在部署目标 < API 版本时引用 ___isPlatformVersionAtLeast
//（clang_rt 助手）。rustc 用 -nodefaultlibs 链接不含它，传绝对路径补上——
// 不走 -l static（会被打包进 rlib，与 Xcode 侧自动注入的 clang_rt 重复）。

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    if let Ok(out) = std::process::Command::new("clang")
        .arg("-print-resource-dir")
        .output()
    {
        if out.status.success() {
            let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
            let rt = format!("{dir}/lib/darwin/libclang_rt.osx.a");
            if std::path::Path::new(&rt).exists() {
                println!("cargo:rustc-link-arg={rt}");
            }
        }
    }
}
