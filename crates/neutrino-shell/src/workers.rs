// SPDX-License-Identifier: MPL-2.0
//! Removable native module executables. UI and process admission remain in the host.
use serde_json::{json, Value};
use std::io::{self, Read, Write};

pub fn reader() -> io::Result<()> {
    let mut input = Vec::new();
    let response = match io::stdin()
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut input)
    {
        Err(_) => json!({"text":"","error":"Reader could not read the page snapshot."}),
        Ok(_) if input.len() > 2 * 1024 * 1024 => {
            json!({"text":"","error":"Reader received too much page data."})
        }
        Ok(_) => match serde_json::from_slice::<Value>(&input)
            .ok()
            .and_then(|r| r.get("html").and_then(Value::as_str).map(str::to_owned))
        {
            None => json!({"text":"","error":"Reader received an invalid page snapshot."}),
            Some(html) => match crate::core::reader(&html) {
                Ok(text) => json!({"text":text}),
                Err(error) => json!({"text":"","error":error}),
            },
        },
    };
    serde_json::to_writer(io::stdout().lock(), &response).map_err(io::Error::other)
}

fn metric(
    name: &str,
    value: String,
    detail: &str,
    fraction: Option<f64>,
    samples: &[f64],
) -> Value {
    json!({"name":name,"value":value,"detail":detail,"fraction":fraction,"samples":samples})
}
fn bytes(value: u64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut amount = value as f64;
    let mut unit = 0;
    while amount >= 1024.0 && unit < units.len() - 1 {
        amount /= 1024.0;
        unit += 1;
    }
    format!("{amount:.1} {}", units[unit])
}
struct Memory {
    total: u64,
    active: u64,
    wired: u64,
    compressed: u64,
    inactive: u64,
    free: u64,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Memory;
    unsafe extern "C" {
        fn mach_port_deallocate(
            task: libc::mach_port_t,
            name: libc::mach_port_t,
        ) -> libc::kern_return_t;
    }
    struct Host(libc::mach_port_t);
    impl Host {
        #[allow(deprecated)]
        fn new() -> Self {
            Self(unsafe { libc::mach_host_self() })
        }
    }
    impl Drop for Host {
        #[allow(deprecated)]
        fn drop(&mut self) {
            unsafe {
                mach_port_deallocate(libc::mach_task_self(), self.0);
            }
        }
    }
    pub fn cpu_ticks() -> Option<[u32; 4]> {
        let host = Host::new();
        let mut info: libc::host_cpu_load_info_data_t = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        let status = unsafe {
            libc::host_statistics(
                host.0,
                libc::HOST_CPU_LOAD_INFO,
                (&mut info as *mut libc::host_cpu_load_info_data_t).cast(),
                &mut count,
            )
        };
        (status == libc::KERN_SUCCESS && count >= 4).then_some(info.cpu_ticks)
    }
    pub fn memory() -> Option<Memory> {
        let host = Host::new();
        let mut info: libc::vm_statistics64_data_t = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        let status = unsafe {
            libc::host_statistics64(
                host.0,
                libc::HOST_VM_INFO64,
                (&mut info as *mut libc::vm_statistics64_data_t).cast(),
                &mut count,
            )
        };
        let mut total = 0u64;
        let mut size = std::mem::size_of::<u64>();
        let physical = unsafe {
            libc::sysctlbyname(
                c"hw.memsize".as_ptr(),
                (&mut total as *mut u64).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        if status != libc::KERN_SUCCESS
            || count
                < ((std::mem::offset_of!(libc::vm_statistics64_data_t, compressor_page_count)
                    + std::mem::size_of::<u32>())
                    / std::mem::size_of::<libc::integer_t>()) as u32
            || physical != 0
            || size != 8
            || total == 0
            || page_size <= 0
        {
            return None;
        }
        let page = page_size as u64;
        Some(Memory {
            total,
            active: u64::from(info.active_count) * page,
            wired: u64::from(info.wire_count) * page,
            compressed: u64::from(info.compressor_page_count) * page,
            inactive: u64::from(info.inactive_count) * page,
            free: u64::from(info.free_count) * page,
        })
    }
}
#[cfg(not(target_os = "macos"))]
mod platform {
    pub fn cpu_ticks() -> Option<[u32; 4]> {
        None
    }
    pub fn memory() -> Option<super::Memory> {
        None
    }
}

pub fn resources(memory_only: bool) -> io::Result<()> {
    // EOF is the owning panel's lifetime, including an app crash. Discard input
    // without accumulating it and stop the worker independently of sampling.
    std::thread::spawn(|| {
        let _ = io::copy(&mut io::stdin(), &mut io::sink());
        std::process::exit(0);
    });
    let mut previous: Option<[u32; 4]> = None;
    let mut samples = Vec::new();
    let mut output = io::stdout().lock();
    loop {
        let mut metrics = Vec::new();
        if !memory_only {
            let value = if let Some(ticks) = platform::cpu_ticks() {
                let value = if let Some(old) = previous {
                    let differences: Vec<f64> = ticks
                        .iter()
                        .zip(old)
                        .map(|(new, old)| new.wrapping_sub(old) as f64)
                        .collect();
                    let total: f64 = differences.iter().sum();
                    let fraction = if total > 0.0 {
                        ((total - differences[2]) / total).clamp(0.0, 1.0)
                    } else {
                        0.0
                    };
                    if samples.len() == 30 {
                        samples.remove(0);
                    }
                    samples.push(fraction);
                    format!("{:.1}%", fraction * 100.0)
                } else {
                    "Sampling…".into()
                };
                previous = Some(ticks);
                value
            } else {
                "Unavailable".into()
            };
            metrics.push(metric("System CPU", value, "", None, &samples));
        }
        if let Some(memory) = platform::memory() {
            if memory_only {
                for (name, value, detail) in [
                    ("Active", memory.active, "Recently used physical pages."),
                    (
                        "Wired",
                        memory.wired,
                        "Pages that must remain in physical memory.",
                    ),
                    (
                        "Compressed",
                        memory.compressed,
                        "Physical memory occupied by the compressor.",
                    ),
                    (
                        "Inactive",
                        memory.inactive,
                        "Pages available for reuse when needed.",
                    ),
                    ("Free", memory.free, "Unallocated physical pages."),
                ] {
                    metrics.push(metric(
                        name,
                        bytes(value),
                        detail,
                        Some((value as f64 / memory.total as f64).min(1.0)),
                        &[],
                    ));
                }
            } else {
                let used = memory
                    .active
                    .saturating_add(memory.wired)
                    .saturating_add(memory.compressed)
                    .min(memory.total);
                metrics.push(metric(
                    "System memory in use",
                    bytes(used),
                    &format!(
                        "of {} · active, wired, and compressed pages",
                        bytes(memory.total)
                    ),
                    Some(used as f64 / memory.total as f64),
                    &[],
                ));
            }
        } else {
            metrics.push(metric("System memory", "Unavailable".into(), "", None, &[]));
        }
        let (title, detail) = if memory_only {
            ("Memory Breakdown","Updates every 2 seconds. Each bar is a fraction of total physical memory; these categories are not a complete accounting.")
        } else {
            (
                "Resource Monitor",
                "Updates every 2 seconds. Sampling stops when this panel closes.",
            )
        };
        serde_json::to_writer(
            &mut output,
            &json!({"title":title,"detail":detail,"metrics":metrics}),
        )
        .map_err(io::Error::other)?;
        output.write_all(b"\n")?;
        output.flush()?;
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}
