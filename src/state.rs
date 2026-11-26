use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

use chrono::{DateTime, Local, NaiveDate, SecondsFormat};
use serde::Serialize;

use crate::config::{Config, Mode};

pub const XIAOMI_COMPANY_ID: u16 = 0x0157;
const SAMPLE_MIN_INTERVAL: Duration = Duration::from_millis(800);
const MAX_SAMPLES: usize = 6 * 3600;

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Sample {
    pub t: i64,
    pub bpm: u16,
}

#[derive(Serialize)]
pub struct SessionStats {
    pub min: Option<u16>,
    pub max: Option<u16>,
    pub avg: Option<f64>,
    pub count: u64,
}

#[derive(Serialize)]
pub struct DeviceSummary {
    pub name: String,
    pub id: String,
    pub rssi: Option<i16>,
    pub age_ms: i64,
    pub company_id: u16,
    pub payload_hex: String,
    pub hr_byte: Option<u8>,
    pub target: bool,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub status: &'static str,
    pub status_label: &'static str,
    pub bpm: Option<u16>,
    pub raw_byte: Option<u8>,
    pub device_name: Option<String>,
    pub device_id: Option<String>,
    pub rssi: Option<i16>,
    pub source: &'static str,
    pub mode: &'static str,
    pub offset: usize,
    pub stale_secs: u64,
    pub hold_secs: u64,
    pub last_packet_age_ms: Option<i64>,
    pub last_valid_age_ms: Option<i64>,
    pub samples: Vec<Sample>,
    pub session: SessionStats,
    pub packet_count: u64,
    pub invalid_count: u64,
    pub started_at: String,
    pub raw_hex: String,
    pub csv_path: String,
    pub last_error: Option<String>,
    pub devices: Vec<DeviceSummary>,
}

struct SeenDevice {
    name: String,
    id: String,
    rssi: Option<i16>,
    company_id: u16,
    payload_hex: String,
    hr_byte: Option<u8>,
    last_seen: Instant,
}

struct Inner {
    device_name: Option<String>,
    device_id: Option<String>,
    rssi: Option<i16>,
    bpm: Option<u16>,
    raw_byte: Option<u8>,
    raw_hex: String,
    source: &'static str,
    last_packet: Option<Instant>,
    last_valid: Option<Instant>,
    last_sample_at: Option<Instant>,
    samples: VecDeque<Sample>,
    session_min: Option<u16>,
    session_max: Option<u16>,
    session_sum: u64,
    session_count: u64,
    packet_count: u64,
    invalid_count: u64,
    target_id: Option<String>,
    devices: BTreeMap<String, SeenDevice>,
    csv: CsvLogger,
    last_error: Option<String>,
}

pub struct SharedState {
    pub cfg: Config,
    pub started: DateTime<Local>,
    inner: RwLock<Inner>,
    /// 每次心率/状态变化时递增。等待推送的订阅者据此判断是否要发新事件。
    revision: AtomicU64,
    /// 变化通知：订阅者 await 后拿到当前 revision。
    notify: Arc<Notify>,
}

/// 推送给浮窗的精简状态，只含渲染所需字段。
#[derive(Clone, Serialize)]
pub struct StatusEvent {
    pub revision: u64,
    pub status: &'static str,
    pub status_label: &'static str,
    pub bpm: Option<u16>,
    pub last_valid_age_ms: Option<i64>,
    pub last_error: Option<String>,
    pub csv_path: String,
}

impl SharedState {
    pub fn new(cfg: Config) -> Arc<Self> {
        Arc::new(Self {
            started: Local::now(),
            inner: RwLock::new(Inner {
                device_name: None,
                device_id: None,
                rssi: None,
                bpm: None,
                raw_byte: None,
                raw_hex: String::new(),
                source: "adv",
                last_packet: None,
                last_valid: None,
                last_sample_at: None,
                samples: VecDeque::new(),
                session_min: None,
                session_max: None,
                session_sum: 0,
                session_count: 0,
                packet_count: 0,
                invalid_count: 0,
                target_id: None,
                devices: BTreeMap::new(),
                csv: CsvLogger::new(cfg.data_dir.clone()),
                last_error: None,
            }),
            revision: AtomicU64::new(0),
            notify: Arc::new(Notify::new()),
            cfg,
        })
    }

    /// 标记状态已变化并唤醒所有等待的订阅者。
    fn bump(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    /// 当前状态版本号，用于订阅者判断是否有新事件。
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }

    /// 返回当前精简状态，供推送使用。
    pub fn status_event(&self) -> StatusEvent {
        let minutes = 10;
        let snapshot = self.snapshot(minutes);
        StatusEvent {
            revision: self.revision.load(Ordering::SeqCst),
            status: snapshot.status,
            status_label: snapshot.status_label,
            bpm: snapshot.bpm,
            last_valid_age_ms: snapshot.last_valid_age_ms,
            last_error: snapshot.last_error,
            csv_path: snapshot.csv_path,
        }
    }

    /// 等待下一次状态变化。返回变化后的精简状态。
    ///
    /// 状态不仅随数据到达变化，也会随时间自然过期（实时 → 保持中 → 信号中断）。
    /// 过期时没有新广播触发 bump，因此这里额外按距离下一次过期的剩余时间唤醒，
    /// 保证手环断联后订阅端能按时收到状态降级。
    pub async fn wait_for_change(&self, last_seen: u64) -> StatusEvent {
        loop {
            // 先登记等待，再检查 revision，避免丢失通知。
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.revision.load(Ordering::SeqCst) != last_seen {
                return self.status_event();
            }
            match self.next_transition_in() {
                Some(remaining) => {
                    tokio::select! {
                        _ = notified => {}
                        _ = tokio::time::sleep(remaining + Duration::from_millis(1)) => {
                            return self.status_event();
                        }
                    }
                }
                None => notified.await,
            }
            if self.revision.load(Ordering::SeqCst) != last_seen {
                return self.status_event();
            }
        }
    }

    /// 距离下一次状态随时间过期的剩余时间，用于推送端的定时唤醒。
    /// 判定条件与 snapshot() 保持一致：
    /// 有可显示心率时，last_valid 超过 stale 由实时降为保持中，超过 hold 判为信号中断；
    /// 无心率时，last_packet 超过 stale 判为信号中断。
    fn next_transition_in(&self) -> Option<Duration> {
        let now = Instant::now();
        let inner = self.inner.read().unwrap();
        let stale = Duration::from_secs(self.cfg.stale_secs);
        let hold = Duration::from_secs(self.cfg.hold_secs.max(self.cfg.stale_secs));
        let valid_age = inner.last_valid.map(|last| now.duration_since(last));
        let packet_age = inner.last_packet.map(|last| now.duration_since(last));

        if inner.bpm.is_some() {
            if let Some(age) = valid_age {
                if age <= stale {
                    return Some(stale - age);
                }
                if age <= hold {
                    return Some(hold - age);
                }
            }
        }
        if let Some(age) = packet_age {
            if age <= stale {
                return Some(stale - age);
            }
        }
        None
    }

    pub fn observe_advert(
        &self,
        name: &str,
        id: &str,
        rssi: Option<i16>,
        company_id: u16,
        payload: &[u8],
        offset: usize,
    ) {
        let now = Instant::now();
        let mut inner = self.inner.write().unwrap();
        inner.record_device(name, id, rssi, company_id, payload, offset, now);

        if company_id != XIAOMI_COMPANY_ID || !self.cfg.matches_device(name, id) {
            return;
        }
        if !inner.accept_target(id, now, self.cfg.stale_secs) {
            return;
        }

        inner.device_name = Some(name.to_string());
        inner.device_id = Some(id.to_string());
        inner.rssi = rssi;
        inner.source = "adv";
        inner.raw_hex = hex(payload);
        inner.raw_byte = payload.get(offset).copied();
        inner.last_packet = Some(now);
        inner.packet_count += 1;
        inner.last_error = None;

        match inner.raw_byte {
            Some(bpm) if (20..=250).contains(&bpm) => {
                inner.record_valid(bpm.into(), now);
            }
            _ => {
                inner.invalid_count += 1;
                inner.bpm = None;
            }
        }
        drop(inner);
        self.bump();
    }

    pub fn observe_gatt(&self, name: &str, id: &str, bpm: u16) {
        if !self.cfg.matches_device(name, id) || !(20..=250).contains(&bpm) {
            return;
        }
        let now = Instant::now();
        let mut inner = self.inner.write().unwrap();
        inner.record_device(name, id, None, 0, &[], 0, now);
        inner.device_name = Some(name.to_string());
        inner.device_id = Some(id.to_string());
        inner.source = "gatt";
        inner.raw_hex.clear();
        inner.raw_byte = None;
        inner.last_packet = Some(now);
        inner.packet_count += 1;
        inner.target_id = Some(id.to_string());
        inner.last_error = None;
        inner.record_valid(bpm, now);
        drop(inner);
        self.bump();
    }

    pub fn observe_mock(&self, bpm: u16) {
        let now = Instant::now();
        let payload = [0xAA, 0xBB, 0xCC, bpm as u8, 0x00, 0x00];
        let mut inner = self.inner.write().unwrap();
        inner.record_device(
            "Mock Band 5",
            "MOCK-0001",
            Some(-48),
            XIAOMI_COMPANY_ID,
            &payload,
            3,
            now,
        );
        inner.device_name = Some("Mock Band 5".into());
        inner.device_id = Some("MOCK-0001".into());
        inner.rssi = Some(-48);
        inner.source = "mock";
        inner.raw_hex = hex(&payload);
        inner.raw_byte = Some(bpm as u8);
        inner.last_packet = Some(now);
        inner.packet_count += 1;
        inner.last_error = None;
        inner.record_valid(bpm, now);
        drop(inner);
        self.bump();
    }

    pub fn seed_mock_history(&self, seconds: u32) {
        let seconds = seconds.clamp(1, 3600);
        let now = Instant::now();
        let wall = Local::now();
        let mut inner = self.inner.write().unwrap();
        inner.device_name = Some("Mock Band 5".into());
        inner.device_id = Some("MOCK-0001".into());
        inner.rssi = Some(-48);
        inner.source = "mock";
        inner.target_id = Some("MOCK-0001".into());
        inner.last_packet = Some(now);
        inner.last_valid = Some(now);

        for index in (0..seconds).rev() {
            let bpm = mock_bpm(-(index as f64));
            let timestamp = wall.timestamp_millis() - index as i64 * 1000;
            inner.samples.push_back(Sample { t: timestamp, bpm });
            inner.session_count += 1;
            inner.session_sum += bpm as u64;
            inner.session_min = Some(inner.session_min.map_or(bpm, |value| value.min(bpm)));
            inner.session_max = Some(inner.session_max.map_or(bpm, |value| value.max(bpm)));
        }
        while inner.samples.len() > MAX_SAMPLES {
            inner.samples.pop_front();
        }

        let last = inner.samples.back().map(|sample| sample.bpm).unwrap_or(74);
        let payload = [0xAA, 0xBB, 0xCC, last as u8, 0x00, 0x00];
        inner.bpm = Some(last);
        inner.raw_byte = Some(last as u8);
        inner.raw_hex = hex(&payload);
        inner.last_sample_at = Some(now);
        inner.record_device(
            "Mock Band 5",
            "MOCK-0001",
            Some(-48),
            XIAOMI_COMPANY_ID,
            &payload,
            3,
            now,
        );
    }

    pub fn note_error(&self, error: impl Into<String>) {
        self.inner.write().unwrap().last_error = Some(error.into());
        self.bump();
    }

    pub fn clear_error(&self) {
        self.inner.write().unwrap().last_error = None;
        self.bump();
    }

    pub fn snapshot(&self, minutes: u32) -> Snapshot {
        let minutes = minutes.clamp(1, 360);
        let now = Instant::now();
        let inner = self.inner.read().unwrap();
        let stale = Duration::from_secs(self.cfg.stale_secs);
        let hold = Duration::from_secs(self.cfg.hold_secs.max(self.cfg.stale_secs));
        let packet_age = inner.last_packet.map(|t| now.duration_since(t));
        let valid_age = inner.last_valid.map(|t| now.duration_since(t));
        let has_bpm = inner.bpm.is_some();

        // 手环广播间隔可能远大于 1 秒：实时窗口之后先进入“保持”，继续显示
        // 上一次心率；超过 hold 才判定为信号中断。数值本身不因超时置空。
        let (status, status_label) = if packet_age.is_none() && !has_bpm {
            ("scanning", "正在扫描")
        } else if has_bpm && valid_age.map(|age| age <= stale).unwrap_or(false) {
            ("live", "实时")
        } else if has_bpm && valid_age.map(|age| age <= hold).unwrap_or(false) {
            ("holding", "保持中")
        } else if packet_age.map(|age| age <= stale).unwrap_or(false) {
            ("waiting", "等待心率")
        } else {
            ("stale", "信号中断")
        };

        let bpm = inner.bpm;
        let cutoff = Local::now().timestamp_millis() - minutes as i64 * 60_000;
        let mut samples: Vec<Sample> = inner
            .samples
            .iter()
            .filter(|sample| sample.t >= cutoff)
            .copied()
            .collect();
        if samples.len() > 600 {
            let step = (samples.len() as f64 / 600.0).ceil() as usize;
            let last = samples.last().copied();
            let mut reduced = Vec::with_capacity(600);
            for (index, sample) in samples.iter().enumerate() {
                if index % step == 0 {
                    reduced.push(*sample);
                }
            }
            if let Some(last) = last {
                if reduced.last().map(|sample| sample.t) != Some(last.t) {
                    reduced.push(last);
                }
            }
            samples = reduced;
        }

        let mut devices: Vec<DeviceSummary> = inner
            .devices
            .values()
            .map(|device| DeviceSummary {
                name: device.name.clone(),
                id: device.id.clone(),
                rssi: device.rssi,
                age_ms: now.duration_since(device.last_seen).as_millis() as i64,
                company_id: device.company_id,
                payload_hex: device.payload_hex.clone(),
                hr_byte: device.hr_byte,
                target: inner.device_id.as_deref() == Some(device.id.as_str()),
            })
            .collect();
        devices.sort_by_key(|device| device.age_ms);
        devices.truncate(12);

        Snapshot {
            status,
            status_label,
            bpm,
            raw_byte: inner.raw_byte,
            device_name: inner.device_name.clone(),
            device_id: inner.device_id.clone(),
            rssi: inner.rssi,
            source: inner.source,
            mode: self.cfg.mode.as_str(),
            offset: self.cfg.offset,
            stale_secs: self.cfg.stale_secs,
            hold_secs: self.cfg.hold_secs.max(self.cfg.stale_secs),
            last_packet_age_ms: packet_age.map(|age| age.as_millis() as i64),
            last_valid_age_ms: valid_age.map(|age| age.as_millis() as i64),
            samples,
            session: SessionStats {
                min: inner.session_min,
                max: inner.session_max,
                avg: if inner.session_count > 0 {
                    Some(inner.session_sum as f64 / inner.session_count as f64)
                } else {
                    None
                },
                count: inner.session_count,
            },
            packet_count: inner.packet_count,
            invalid_count: inner.invalid_count,
            started_at: self.started.to_rfc3339_opts(SecondsFormat::Secs, false),
            raw_hex: inner.raw_hex.clone(),
            csv_path: inner.csv.display_path(),
            last_error: inner.last_error.clone(),
            devices,
        }
    }

    pub fn csv_bytes(&self) -> Vec<u8> {
        let path = self.inner.read().unwrap().csv.current_path();
        match fs::read(path) {
            Ok(bytes) => bytes,
            Err(_) => b"timestamp,epoch_ms,device,device_id,rssi,bpm,source,raw_hex\n".to_vec(),
        }
    }

    pub fn csv_path(&self) -> String {
        self.inner.read().unwrap().csv.display_path()
    }
}

impl Inner {
    fn accept_target(&mut self, id: &str, now: Instant, stale_secs: u64) -> bool {
        match self.target_id.as_deref() {
            Some(target) if target != id => {
                let stale = Duration::from_secs(stale_secs);
                let target_fresh = self
                    .last_packet
                    .map(|last| now.duration_since(last) < stale)
                    .unwrap_or(false);
                let target_has_recent_hr = self
                    .last_valid
                    .map(|last| now.duration_since(last) < stale)
                    .unwrap_or(false);
                if target_fresh && target_has_recent_hr {
                    false
                } else {
                    self.target_id = Some(id.to_string());
                    true
                }
            }
            Some(_) => true,
            // 未锁定前不急于选设备：先观察所有小米广播，等第一条有效心率出现后再锁定。
            None => true,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn record_device(
        &mut self,
        name: &str,
        id: &str,
        rssi: Option<i16>,
        company_id: u16,
        payload: &[u8],
        offset: usize,
        now: Instant,
    ) {
        let entry = self
            .devices
            .entry(id.to_string())
            .or_insert_with(|| SeenDevice {
                name: name.to_string(),
                id: id.to_string(),
                rssi,
                company_id,
                payload_hex: String::new(),
                hr_byte: None,
                last_seen: now,
            });
        if !name.trim().is_empty() && name != "未知设备" {
            entry.name = name.to_string();
        }
        entry.rssi = rssi;
        entry.company_id = company_id;
        entry.payload_hex = hex(payload);
        entry.hr_byte = payload.get(offset).copied();
        entry.last_seen = now;
    }

    fn record_valid(&mut self, bpm: u16, now: Instant) {
        self.bpm = Some(bpm);
        self.last_valid = Some(now);
        self.last_packet = Some(now);
        self.target_id = self.device_id.clone();

        let append = self
            .last_sample_at
            .map(|last| now.duration_since(last) >= SAMPLE_MIN_INTERVAL)
            .unwrap_or(true);
        if !append {
            return;
        }

        self.last_sample_at = Some(now);
        self.session_count += 1;
        self.session_sum += bpm as u64;
        self.session_min = Some(self.session_min.map_or(bpm, |value| value.min(bpm)));
        self.session_max = Some(self.session_max.map_or(bpm, |value| value.max(bpm)));

        let timestamp = Local::now();
        let sample = Sample {
            t: timestamp.timestamp_millis(),
            bpm,
        };
        self.samples.push_back(sample);
        while self.samples.len() > MAX_SAMPLES {
            self.samples.pop_front();
        }

        let name = self.device_name.clone().unwrap_or_default();
        let id = self.device_id.clone().unwrap_or_default();
        let rssi = self.rssi;
        let raw = self.raw_hex.clone();
        let source = self.source;
        if let Err(error) = self
            .csv
            .log(&timestamp, &name, &id, rssi, bpm, source, &raw)
        {
            self.last_error = Some(format!("CSV 写入失败：{error}"));
        }
    }
}

struct CsvLogger {
    dir: PathBuf,
    current: Option<(NaiveDate, PathBuf, File)>,
    last_path: Option<PathBuf>,
}

impl CsvLogger {
    fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            current: None,
            last_path: None,
        }
    }

    fn day_path(&self, date: NaiveDate) -> PathBuf {
        self.dir
            .join(format!("heart-rate-{}.csv", date.format("%Y-%m-%d")))
    }

    fn current_path(&self) -> PathBuf {
        self.last_path
            .clone()
            .unwrap_or_else(|| self.day_path(Local::now().date_naive()))
    }

    fn display_path(&self) -> String {
        self.current_path().to_string_lossy().to_string()
    }

    fn ensure(&mut self, timestamp: &DateTime<Local>) -> std::io::Result<()> {
        let date = timestamp.date_naive();
        if self.current.as_ref().map(|(day, _, _)| *day) == Some(date) {
            return Ok(());
        }

        fs::create_dir_all(&self.dir)?;
        let path = self.day_path(date);
        let is_new = fs::metadata(&path)
            .map(|metadata| metadata.len() == 0)
            .unwrap_or(true);
        let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
        if is_new {
            file.write_all(b"timestamp,epoch_ms,device,device_id,rssi,bpm,source,raw_hex\n")?;
        }
        self.last_path = Some(path.clone());
        self.current = Some((date, path, file));
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn log(
        &mut self,
        timestamp: &DateTime<Local>,
        name: &str,
        id: &str,
        rssi: Option<i16>,
        bpm: u16,
        source: &str,
        raw: &str,
    ) -> std::io::Result<()> {
        self.ensure(timestamp)?;
        let line = format!(
            "{},{},{},{},{},{},{},{}\n",
            timestamp.to_rfc3339_opts(SecondsFormat::Millis, false),
            timestamp.timestamp_millis(),
            csv_escape(name),
            csv_escape(id),
            rssi.map(|value| value.to_string()).unwrap_or_default(),
            bpm,
            source,
            csv_escape(raw)
        );
        if let Some((_, _, file)) = self.current.as_mut() {
            file.write_all(line.as_bytes())?;
            file.flush()?;
        }
        Ok(())
    }
}

fn csv_escape(value: &str) -> String {
    if value.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

pub fn hex(data: &[u8]) -> String {
    data.iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn mode_hint(mode: Mode) -> &'static str {
    match mode {
        Mode::Adv => "监听小米运动心率广播",
        Mode::Gatt => "连接设备读取标准心率服务",
        Mode::Mock => "模拟数据",
        Mode::Dump => "广播诊断",
    }
}

pub fn mock_bpm(seconds: f64) -> u16 {
    let wave = 8.0 * (seconds / 17.0).sin() + 3.5 * (seconds / 4.3).sin();
    let noise = 1.2 * (seconds * 13.7).sin();
    (74.0 + wave + noise).round().clamp(54.0, 120.0) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_csv_fields() {
        assert_eq!(csv_escape("plain"), "plain");
        assert_eq!(csv_escape("a,b"), "\"a,b\"");
        assert_eq!(csv_escape("a\"b"), "\"a\"\"b\"");
    }

    #[test]
    fn formats_hex_payload() {
        assert_eq!(hex(&[0x01, 0xAB, 0xFF]), "01 AB FF");
    }
}

#[cfg(test)]
mod advert_tests {
    use super::*;

    fn test_state(offset: usize) -> Arc<SharedState> {
        let dir = std::env::temp_dir().join(format!(
            "miband-hr-mac-test-{}-{}",
            std::process::id(),
            offset
        ));
        let _ = fs::remove_dir_all(&dir);
        let cfg = Config {
            mode: Mode::Adv,
            port: 0,
            device: None,
            offset,
            stale_secs: 6,
            hold_secs: 45,
            web_on_start: false,
            data_dir: dir.clone(),
            open_browser: false,
            verbose: false,
            dump_all: false,
        };
        SharedState::new(cfg)
    }

    #[test]
    fn parses_xiaomi_payload_at_offset_3() {
        let state = test_state(3);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 88, 0x00],
            3,
        );
        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.bpm, Some(88));
        assert_eq!(snapshot.status, "live");
        assert_eq!(snapshot.device_name.as_deref(), Some("Mi Smart Band 5"));
    }

    #[test]
    fn treats_255_as_waiting() {
        let state = test_state(3);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 255, 0x00],
            3,
        );
        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.bpm, None);
        assert_eq!(snapshot.status, "waiting");
    }

    #[test]
    fn honours_custom_offset() {
        let state = test_state(4);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 0x00, 91],
            4,
        );
        assert_eq!(state.snapshot(10).bpm, Some(91));
    }

    #[test]
    fn keeps_last_bpm_between_sparse_packets() {
        let state = test_state(3);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 80, 0x00],
            3,
        );
        {
            let mut inner = state.inner.write().unwrap();
            let aged = Instant::now() - Duration::from_secs(12);
            inner.last_packet = Some(aged);
            inner.last_valid = Some(aged);
        }

        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.status, "holding");
        assert_eq!(snapshot.bpm, Some(80));
    }

    #[test]
    fn dims_bpm_but_keeps_value_after_hold() {
        let state = test_state(3);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 76, 0x00],
            3,
        );
        {
            let mut inner = state.inner.write().unwrap();
            let aged = Instant::now() - Duration::from_secs(60);
            inner.last_packet = Some(aged);
            inner.last_valid = Some(aged);
        }

        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.status, "stale");
        assert_eq!(snapshot.bpm, Some(76));
    }

    #[test]
    fn invalid_packet_clears_bpm() {
        let state = test_state(3);
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 88, 0x00],
            3,
        );
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 255, 0x00],
            3,
        );

        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.status, "waiting");
        assert_eq!(snapshot.bpm, None);
    }
}

#[cfg(test)]
mod transition_tests {
    use super::*;

    fn test_state(stale_secs: u64, hold_secs: u64) -> Arc<SharedState> {
        let dir = std::env::temp_dir().join(format!(
            "miband-hr-mac-transition-test-{}-{stale_secs}-{hold_secs}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        SharedState::new(Config {
            mode: Mode::Adv,
            port: 0,
            device: None,
            offset: 3,
            stale_secs,
            hold_secs,
            web_on_start: false,
            data_dir: dir,
            open_browser: false,
            verbose: false,
            dump_all: false,
        })
    }

    fn observe(state: &SharedState) {
        state.observe_advert(
            "Mi Smart Band 5",
            "test-device",
            Some(-52),
            XIAOMI_COMPANY_ID,
            &[0xAA, 0xBB, 0xCC, 88, 0x00],
            3,
        );
    }

    fn age_last_data(state: &SharedState, seconds: u64) {
        let mut inner = state.inner.write().unwrap();
        let aged = Instant::now() - Duration::from_secs(seconds);
        inner.last_packet = Some(aged);
        inner.last_valid = Some(aged);
    }

    #[test]
    fn reports_next_expiry() {
        let state = test_state(6, 45);
        observe(&state);

        let remaining = state.next_transition_in().expect("刚收到数据应有过期时间");
        assert!(remaining <= Duration::from_secs(6));
        assert!(remaining > Duration::from_secs(5));

        age_last_data(&state, 12);
        let remaining = state.next_transition_in().expect("保持中仍应有过期时间");
        assert!(remaining <= Duration::from_secs(33));
        assert!(remaining > Duration::from_secs(32));

        age_last_data(&state, 60);
        assert!(state.next_transition_in().is_none());
    }

    #[tokio::test]
    async fn pushes_state_change_when_stream_goes_silent() {
        let state = test_state(1, 2);
        observe(&state);

        let mut last = state.revision();
        let mut statuses = Vec::new();
        for _ in 0..5 {
            let event = tokio::time::timeout(Duration::from_secs(3), state.wait_for_change(last))
                .await
                .expect("数据停止后应在过期时主动推送");
            last = event.revision;
            statuses.push(event.status);
            if event.status == "stale" {
                break;
            }
        }
        assert_eq!(statuses.last().copied(), Some("stale"));
    }
}

#[cfg(test)]
mod target_tests {
    use super::*;

    #[test]
    fn locks_only_after_valid_hr() {
        let state = test_state_for_target();
        state.observe_advert(
            "Mi Scale",
            "scale-id",
            Some(-40),
            XIAOMI_COMPANY_ID,
            &[0, 0, 0, 255],
            3,
        );
        assert_eq!(state.snapshot(10).bpm, None);

        state.observe_advert(
            "Mi Smart Band 5",
            "band-id",
            Some(-55),
            XIAOMI_COMPANY_ID,
            &[0, 0, 0, 77],
            3,
        );
        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.bpm, Some(77));
        assert_eq!(snapshot.device_name.as_deref(), Some("Mi Smart Band 5"));

        state.observe_advert(
            "Other Band",
            "other-id",
            Some(-30),
            XIAOMI_COMPANY_ID,
            &[0, 0, 0, 99],
            3,
        );
        let snapshot = state.snapshot(10);
        assert_eq!(snapshot.bpm, Some(77));
        assert_eq!(snapshot.device_name.as_deref(), Some("Mi Smart Band 5"));
    }

    fn test_state_for_target() -> Arc<SharedState> {
        let dir =
            std::env::temp_dir().join(format!("miband-hr-mac-target-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        SharedState::new(Config {
            mode: Mode::Adv,
            port: 0,
            device: None,
            offset: 3,
            stale_secs: 6,
            hold_secs: 45,
            web_on_start: false,
            data_dir: dir,
            open_browser: false,
            verbose: false,
            dump_all: false,
        })
    }
}
