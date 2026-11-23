use std::collections::HashMap;
use std::error::Error;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bluest::{btuuid::bluetooth_uuid_from_u16, Adapter, AdvertisingDevice, Device, Uuid};
use futures_lite::stream::StreamExt;

use crate::config::{Config, Mode};
use crate::state::{hex, mock_bpm, SharedState, XIAOMI_COMPANY_ID};

const HRS_UUID: Uuid = bluetooth_uuid_from_u16(0x180D);
const HRM_UUID: Uuid = bluetooth_uuid_from_u16(0x2A37);

pub async fn run(shared: Arc<SharedState>) {
    match shared.cfg.mode {
        Mode::Adv => run_adv(shared).await,
        Mode::Gatt => run_gatt(shared).await,
        Mode::Mock => run_mock(shared).await,
        Mode::Dump => run_dump(shared).await,
    }
}

async fn run_adv(shared: Arc<SharedState>) {
    loop {
        if let Err(error) = adv_scan(&shared).await {
            let message = format!("广播扫描：{error}");
            eprintln!("[蓝牙] {message}");
            shared.note_error(message);
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
}

async fn adv_scan(shared: &SharedState) -> Result<(), Box<dyn Error>> {
    let adapter = Adapter::default()
        .await
        .ok_or("未找到蓝牙适配器，请确认系统蓝牙已开启")?;
    wait_for_adapter(&adapter).await?;
    shared.clear_error();
    println!("[蓝牙] 开始扫描运动心率广播");
    println!("[蓝牙] 在手环上开启任一运动模式后，心率才会广播");

    let mut scan = adapter.scan(&[]).await?;
    while let Some(advertisement) = scan.next().await {
        let Some(manufacturer) = advertisement.adv_data.manufacturer_data.as_ref() else {
            continue;
        };
        if manufacturer.company_id != XIAOMI_COMPANY_ID {
            if shared.cfg.verbose {
                let name = display_name(&advertisement);
                println!(
                    "[广播] {name} company=0x{:04X} payload={}",
                    manufacturer.company_id,
                    hex(&manufacturer.data)
                );
            }
            continue;
        }

        let name = display_name(&advertisement);
        let id = advertisement.device.id().to_string();
        let rssi = advertisement.rssi;
        let offset = shared.cfg.offset;
        let payload = &manufacturer.data;
        shared.observe_advert(&name, &id, rssi, manufacturer.company_id, payload, offset);

        if shared.cfg.verbose {
            let value = payload
                .get(offset)
                .map(|byte| format!("{byte}"))
                .unwrap_or_else(|| "-".into());
            println!(
                "[广播] {name} ({id}) rssi={}dBm len={} hr@{offset}={value} raw={}",
                rssi.map(|v| v.to_string()).unwrap_or_else(|| "?".into()),
                payload.len(),
                hex(payload)
            );
        }
    }
    Err("扫描流已结束".into())
}

async fn run_dump(shared: Arc<SharedState>) {
    if let Err(error) = dump_scan(&shared).await {
        eprintln!("[诊断] {error}");
        shared.note_error(format!("诊断：{error}"));
    }
}

async fn dump_scan(shared: &SharedState) -> Result<(), Box<dyn Error>> {
    let adapter = Adapter::default()
        .await
        .ok_or("未找到蓝牙适配器，请确认系统蓝牙已开启")?;
    wait_for_adapter(&adapter).await?;
    shared.clear_error();
    println!("[诊断] 开始扫描。靠近手环，并在手环上开启任一运动模式。");
    println!("[诊断] 每台设备最多每 2 秒打印一次；Ctrl-C 结束。");
    println!("[诊断] 重点看 company=0x0157 的设备，以及 payload 中各字节的值。");

    let mut scan = adapter.scan(&[]).await?;
    let mut last_print: HashMap<String, Instant> = HashMap::new();
    while let Some(advertisement) = scan.next().await {
        let name = display_name(&advertisement);
        let id = advertisement.device.id().to_string();
        let manufacturer = advertisement.adv_data.manufacturer_data.as_ref();
        let looks_like_band = is_band_name(&name);
        let is_xiaomi = manufacturer
            .map(|data| data.company_id == XIAOMI_COMPANY_ID)
            .unwrap_or(false);
        if !shared.cfg.dump_all && !looks_like_band && !is_xiaomi {
            continue;
        }

        let now = Instant::now();
        if last_print
            .get(&id)
            .map(|last| now.duration_since(*last) < Duration::from_secs(2))
            .unwrap_or(false)
        {
            continue;
        }
        last_print.insert(id.clone(), now);

        let rssi = advertisement
            .rssi
            .map(|value| format!("{value}dBm"))
            .unwrap_or_else(|| "?dBm".into());
        let services = advertisement
            .adv_data
            .services
            .iter()
            .map(|uuid| uuid.to_string())
            .collect::<Vec<_>>()
            .join(",");
        match manufacturer {
            Some(data) => {
                let mut bytes = String::new();
                for (index, byte) in data.data.iter().take(16).enumerate() {
                    if index > 0 {
                        bytes.push(' ');
                    }
                    bytes.push_str(&format!("b{index}={byte}"));
                }
                println!(
                    "[诊断] name=\"{name}\" id={id} rssi={rssi} company=0x{:04X} len={} payload=[{}] {bytes} services=[{services}]",
                    data.company_id,
                    data.data.len(),
                    hex(&data.data)
                );
            }
            None => {
                println!(
                    "[诊断] name=\"{name}\" id={id} rssi={rssi} company=- payload=- services=[{services}]"
                );
            }
        }
        let _ = std::io::stdout().flush();
    }
    Err("扫描流已结束".into())
}

async fn run_gatt(shared: Arc<SharedState>) {
    loop {
        if let Err(error) = gatt_session(&shared).await {
            let message = format!("GATT：{error}");
            eprintln!("[GATT] {message}");
            shared.note_error(message);
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
}

async fn gatt_session(shared: &SharedState) -> Result<(), Box<dyn Error>> {
    let adapter = Adapter::default()
        .await
        .ok_or("未找到蓝牙适配器，请确认系统蓝牙已开启")?;
    wait_for_adapter(&adapter).await?;
    shared.clear_error();
    println!("[GATT] 搜索目标设备（最多 30 秒）");
    let device = find_target(&adapter, &shared.cfg).await?;
    let name = device.name().unwrap_or_else(|_| "未知设备".into());
    let id = device.id().to_string();
    println!("[GATT] 连接 {name} ({id})");
    adapter.connect_device(&device).await?;
    println!("[GATT] 已连接，查找标准心率服务 0x180D");

    let services = device.discover_services_with_uuid(HRS_UUID).await?;
    let service = services.first().ok_or("设备未提供标准心率服务 0x180D")?;
    let characteristics = service.discover_characteristics_with_uuid(HRM_UUID).await?;
    let characteristic = characteristics.first().ok_or("未找到心率测量特征 0x2A37")?;

    let mut updates = characteristic.notify().await?;
    println!("[GATT] 已订阅心率通知，等待数据");
    while let Some(packet) = updates.next().await {
        match packet {
            Ok(data) => {
                if let Some(bpm) = parse_standard_hr(&data) {
                    shared.observe_gatt(&name, &id, bpm);
                    if shared.cfg.verbose {
                        println!("[GATT] {name} bpm={bpm} raw={}", hex(&data));
                    }
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
    Err("心率通知流已结束".into())
}

async fn find_target(adapter: &Adapter, cfg: &Config) -> Result<Device, Box<dyn Error>> {
    let mut scan = adapter.scan(&[]).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(
                "30 秒内未找到目标设备；可用 --device 指定名称，或先用 dump 模式确认设备".into(),
            );
        }
        let item = tokio::time::timeout(remaining, scan.next()).await;
        let advertisement = match item {
            Err(_) => {
                return Err(
                    "30 秒内未找到目标设备；可用 --device 指定名称，或先用 dump 模式确认设备"
                        .into(),
                );
            }
            Ok(None) => return Err("扫描流已结束".into()),
            Ok(Some(advertisement)) => advertisement,
        };

        let name = display_name(&advertisement);
        let id = advertisement.device.id().to_string();
        let has_hr_service = advertisement.adv_data.services.contains(&HRS_UUID);
        let candidate = if cfg.device.is_some() {
            cfg.matches_device(&name, &id)
        } else {
            has_hr_service || is_band_name(&name)
        };

        if candidate || cfg.verbose {
            println!(
                "[GATT] 发现 name=\"{name}\" id={id} rssi={:?} hr_service={has_hr_service}",
                advertisement.rssi
            );
        }
        if candidate {
            let device = advertisement.device.clone();
            drop(scan);
            return Ok(device);
        }
    }
}

async fn run_mock(shared: Arc<SharedState>) {
    shared.seed_mock_history(600);
    println!("[模拟] 已预填 10 分钟历史数据，每秒追加新数据");
    let start = Instant::now();
    let mut ticker = tokio::time::interval(Duration::from_secs(1));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        let bpm = mock_bpm(start.elapsed().as_secs_f64());
        shared.observe_mock(bpm);
    }
}

async fn wait_for_adapter(adapter: &Adapter) -> Result<(), Box<dyn Error>> {
    match tokio::time::timeout(Duration::from_secs(8), adapter.wait_available()).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err(error.into()),
        Err(_) => Err("蓝牙不可用或未授权。请在 系统设置 → 隐私与安全性 → 蓝牙 中允许心率浮窗或终端访问蓝牙，并确认系统蓝牙已开启".into()),
    }
}

fn display_name(advertisement: &AdvertisingDevice) -> String {
    advertisement
        .adv_data
        .local_name
        .clone()
        .or_else(|| advertisement.device.name().ok())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "未知设备".into())
}

fn is_band_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.contains("band")
        || lower.contains("手环")
        || lower.contains("xiaomi")
        || lower.contains("miband")
        || lower.starts_with("mi ")
}

fn parse_standard_hr(data: &[u8]) -> Option<u16> {
    let flags = *data.first()?;
    let value = if flags & 0x01 != 0 {
        u16::from_le_bytes([*data.get(1)?, *data.get(2)?])
    } else {
        *data.get(1)? as u16
    };
    (20..=250).contains(&value).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_hr_u8() {
        assert_eq!(parse_standard_hr(&[0x00, 72]), Some(72));
        assert_eq!(parse_standard_hr(&[0x02, 90]), Some(90));
    }

    #[test]
    fn parses_standard_hr_u16() {
        assert_eq!(parse_standard_hr(&[0x01, 0xB4, 0x00]), Some(180));
    }

    #[test]
    fn rejects_invalid_standard_hr() {
        assert_eq!(parse_standard_hr(&[0x00, 255]), None);
        assert_eq!(parse_standard_hr(&[0x00]), None);
        assert_eq!(parse_standard_hr(&[0x01, 0x00, 0x01]), None);
    }

    #[test]
    fn recognises_band_names() {
        assert!(is_band_name("Mi Smart Band 5"));
        assert!(is_band_name("小米手环 5"));
        assert!(is_band_name("Xiaomi Smart Band 6"));
        assert!(!is_band_name("Keyboard"));
    }
}
