// audiocpp-ffi 构建：只编译 C shim，链接预构建的 audio.cpp 引擎库。
// 重活（CMake 编译引擎，含 HIP/CUDA/Metal 后端矩阵）由外部脚本完成
// （scripts/build-linux-appimage.sh / 手动 scripts/build_linux.sh），
// 这里通过环境变量对接：
//   AUDIOCPP_SRC   引擎源码目录（含 include/），默认 ../../vendor/audiocpp
//   AUDIOCPP_BUILD 已构建的 CMake 目录（含 libengine_runtime.a 与 ggml 静态库）
// 缺 AUDIOCPP_BUILD 时编译为空实现桩（cargo metadata/docs 不至于挂）。

use std::env;
use std::path::{Path, PathBuf};

/// 引擎源码默认位置：rust/vendor/audiocpp（fetch-audiocpp.sh 拉取）。
fn default_src() -> PathBuf {
    PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../vendor/audiocpp")
}

/// 平台默认引擎构建树——不设环境变量也能链接真引擎（flutter run/IDE 构建
/// 与脚本构建行为一致；曾因 flutter run 无 env 链了桩、运行期才报错）。
fn default_build() -> PathBuf {
    let dir = if cfg!(target_os = "macos") {
        "macos-metal-release"
    } else if cfg!(target_os = "windows") {
        // 上游 scripts/build_windows.ps1 的预设名（-Preset windows-vulkan-release）
        "windows-vulkan-release"
    } else {
        "linux-vulkan-release"
    };
    default_src().join("build").join(dir)
}

fn main() {
    let src = env::var("AUDIOCPP_SRC")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_src());
    println!("cargo:rerun-if-env-changed=AUDIOCPP_SRC");
    println!("cargo:rerun-if-env-changed=AUDIOCPP_BUILD");
    // 注意：一旦打印任何 rerun-if 指令，cargo 就只认这些——必须显式跟踪 shim 源码
    println!("cargo:rerun-if-changed=cshim/audiocpp_c.cpp");
    println!("cargo:rerun-if-changed=cshim/audiocpp_c.h");
    println!("cargo:rerun-if-changed=cshim/stub.cpp");

    let build = env::var_os("AUDIOCPP_BUILD")
        .map(PathBuf::from)
        .unwrap_or_else(default_build);
    // 静态库扩展名随工具链：GNU/Ninja 风格 .a；Windows Ninja+MSVC 为 .lib
    let engine_lib = if cfg!(target_os = "windows") {
        "libengine_runtime.lib"
    } else {
        "libengine_runtime.a"
    };
    let Some(build) = Some(build)
        .filter(|p: &PathBuf| p.join(engine_lib).exists())
    else {
        println!(
            "cargo:warning=AUDIOCPP_STUB: env_build={:?} default_build={:?} exists={}",
            std::env::var_os("AUDIOCPP_BUILD"),
            default_build(),
            default_build().join(engine_lib).exists()
        );
        compile_shim(&src, true);
        return;
    };
    // 静态库内容不进 cargo 指纹——按 mtime 追踪引擎库，重编后强制重链
    println!("cargo:rerun-if-changed={}", build.join(engine_lib).display());

    compile_shim(&src, false);

    // 链接清单与 audiocpp_cli 链接行一致；按构建树内容自动适配后端：
    // Vulkan（零 ROCm 依赖）/ HIP（ROCm 运行库族）/ Metal（macOS 框架）。
    enum BackendTree { Vulkan, Hip, Metal }
    let tree = if build.join("ggml/src/ggml-vulkan").is_dir() {
        BackendTree::Vulkan
    } else if build.join("ggml/src/ggml-hip").is_dir() {
        BackendTree::Hip
    } else {
        BackendTree::Metal
    };

    let mut search_dirs = vec![
        build.clone(),
        build.join("ggml/src"),
        build.join("external/sentencepiece/src"),
    ];
    let mut static_libs: Vec<&str> = vec![
        "engine_runtime", "ggml", "ggml-base", "ggml-cpu",
        "sentencepiece", "cjson_vendor", "yaml_vendor",
    ];
    match tree {
        BackendTree::Vulkan => {
            search_dirs.push(build.join("ggml/src/ggml-vulkan"));
            static_libs.insert(1, "ggml-vulkan");
            // Debian 系把 libomp 的链接名放在 /usr/lib/llvm-*/lib（rustc 默认
            // 搜索路径之外，Fedora 在 /usr/lib64 直接可见）
            if let Ok(entries) = std::fs::read_dir("/usr/lib") {
                for e in entries.flatten() {
                    let name = e.file_name();
                    if name.to_string_lossy().starts_with("llvm-")
                        && e.path().join("lib/libomp.so").exists()
                    {
                        search_dirs.push(e.path().join("lib"));
                    }
                }
            }
        }
        BackendTree::Hip => {
            search_dirs.push(build.join("ggml/src/ggml-hip"));
            static_libs.insert(1, "ggml-hip");
        }
        BackendTree::Metal => {
            search_dirs.push(build.join("ggml/src/ggml-metal"));
            search_dirs.push(build.join("ggml/src/ggml-blas"));
            static_libs.insert(1, "ggml-metal");
            static_libs.insert(2, "ggml-blas");
        }
    }
    for dir in &search_dirs {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }
    // 静态库顺序有依赖性：engine_runtime 依赖 ggml 系，先列依赖方
    for lib in &static_libs {
        println!("cargo:rustc-link-lib=static={lib}");
    }
    match tree {
        BackendTree::Vulkan => {
            if cfg!(target_os = "windows") {
                // MSVC：vulkan loader 是 vulkan-1.lib；OpenMP 运行库 vcomp
                //（引擎经 /openmp:experimental 编译，静态库带 vcomp 符号）。
                // C++/CRT 由 MSVC 工具链默认链接（/MD，与 sherpa MD 版一致）。
                for lib in ["vulkan-1", "vcomp"] {
                    println!("cargo:rustc-link-lib=dylib={lib}");
                }
            } else {
                for lib in ["stdc++", "m", "dl", "pthread", "omp", "vulkan"] {
                    println!("cargo:rustc-link-lib=dylib={lib}");
                }
            }
        }
        BackendTree::Hip => {
            // LLVM OpenMP（__kmpc_*，clang 构建的引擎用 libomp 非 libgomp）+ ROCm 族
            for lib in ["stdc++", "m", "dl", "pthread", "omp",
                        "amdhip64", "rocblas", "hipblas", "hipblaslt"] {
                println!("cargo:rustc-link-lib=dylib={lib}");
            }
        }        BackendTree::Metal => {
            println!("cargo:rustc-link-lib=dylib=c++");
            for fw in ["Metal", "Foundation", "Accelerate", "CoreGraphics"] {
                println!("cargo:rustc-link-lib=framework={fw}");
            }
            // 注意：ObjC @available() 的 ___isPlatformVersionAtLeast（clang_rt）
            // 不能在这里 -l static——rustc 会把静态库打包进 rlib/staticlib，
            // Xcode 链接器又自动注入自己的 clang_rt → 重复符号。App 侧 Xcode
            // 自带无需处理；Rust 侧二进制（engine-smoke）在各自 build.rs 用
            // rustc-link-arg 传绝对路径。
        }
    }
}

fn compile_shim(src: &Path, stub: bool) {
    let mut build = cc::Build::new();
    build.cpp(true).opt_level(2).std("c++17");
    for inc in [
        src.join("include"),
        src.join("external/ggml/include"),
    ] {
        build.include(inc);
    }
    let file = if stub { "cshim/stub.cpp" } else { "cshim/audiocpp_c.cpp" };
    build.file(file).compile("audiocpp_c");
}
