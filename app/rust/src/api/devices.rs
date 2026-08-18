//! 设备与后端枚举：cpu / metal（macOS）/ vulkan（Linux）。
//! audiocpp 引擎的 GPU 择卡在内部完成（vulkan 下无需枚举设备）。

#[derive(Clone, Debug)]
pub struct GpuDeviceDto {
    pub ordinal: u32,
    pub name: String,
    pub memory_bytes: u64,
}

#[derive(Clone, Debug)]
pub struct BackendDto {
    /// "cpu" | "metal" | "vulkan"
    pub id: String,
    /// 展示名，如 "CPU"、"Metal (Apple)"
    pub label: String,
    pub available: bool,
    /// 不可用时的说明。
    pub note: String,
    pub devices: Vec<GpuDeviceDto>,
}

#[derive(Clone, Debug)]
pub struct SystemInfoDto {
    pub total_memory_bytes: u64,
    pub cpu_count: u32,
    pub cpu_brand: String,
    pub backends: Vec<BackendDto>,
}

#[cfg(target_os = "macos")]
fn metal_devices() -> Vec<GpuDeviceDto> {
    use objc2_metal::{MTLCopyAllDevices, MTLDevice};
    let all = MTLCopyAllDevices();
    all.iter()
        .enumerate()
        .map(|(i, d)| GpuDeviceDto {
            ordinal: i as u32,
            name: d.name().to_string(),
            // Apple Silicon 上即统一内存上限（GPU 可用工作集）
            memory_bytes: d.recommendedMaxWorkingSetSize(),
        })
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn metal_devices() -> Vec<GpuDeviceDto> {
    Vec::new()
}

pub fn system_info() -> SystemInfoDto {
    use sysinfo::System;
    let mut sys = System::new();
    sys.refresh_memory();
    sys.refresh_cpu_all();
    let cpu_brand = sys
        .cpus()
        .first()
        .map(|c| c.brand().trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "CPU".to_string());

    let metal_devices = metal_devices();
    let mut backends = vec![BackendDto {
        id: "cpu".to_string(),
        label: format!("CPU（{cpu_brand}）"),
        available: true,
        note: String::new(),
        devices: Vec::new(),
    }];
    backends.push(BackendDto {
        id: "metal".to_string(),
        label: "Metal（Apple GPU）".to_string(),
        available: cfg!(target_os = "macos") && !metal_devices.is_empty(),
        note: if cfg!(target_os = "macos") {
            String::new()
        } else {
            "仅 macOS 构建可用".to_string()
        },
        devices: metal_devices,
    });
    backends.push(BackendDto {
        id: "vulkan".to_string(),
        label: "Vulkan（AMD / Intel 等独显）".to_string(),
        available: cfg!(target_os = "linux"),
        note: if cfg!(target_os = "linux") {
            String::new()
        } else {
            "仅 Linux 构建可用（macOS 用 Metal）".to_string()
        },
        // 引擎内部经 Vulkan 枚举择卡（RADV/NVIDIA 驱动），应用层不列设备
        devices: Vec::new(),
    });

    SystemInfoDto {
        total_memory_bytes: sys.total_memory(),
        cpu_count: std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1),
        cpu_brand,
        backends,
    }
}
