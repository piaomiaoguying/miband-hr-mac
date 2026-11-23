use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::oneshot;

/// 主网页服务（面板 / OBS / CSV）的开关状态。
pub struct WebServiceState {
    running: AtomicBool,
    requested: AtomicBool,
    stop_tx: Mutex<Option<oneshot::Sender<()>>>,
}

impl WebServiceState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            running: AtomicBool::new(false),
            requested: AtomicBool::new(false),
            stop_tx: Mutex::new(None),
        })
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// 标记为已启动，并保存停止信号。
    pub fn mark_started(&self, stop_tx: oneshot::Sender<()>) {
        *self.stop_tx.lock().unwrap() = Some(stop_tx);
        self.running.store(true, Ordering::SeqCst);
    }

    /// 停止网页服务。未运行时无副作用。
    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(tx) = self.stop_tx.lock().unwrap().take() {
            let _ = tx.send(());
        }
    }

    /// 请求启动（由控制端口调用）。真正绑定由 watcher 完成。
    pub fn start(&self) {
        self.requested.store(true, Ordering::SeqCst);
    }

    /// watcher 抢占启动权：只有请求过且当前未运行才返回 true。
    pub fn claim_start(&self) -> bool {
        if self.is_running() {
            return false;
        }
        self.requested.swap(false, Ordering::SeqCst)
    }

    /// 绑定失败时复位状态，避免卡在“运行中”。
    pub fn force_stopped(&self) {
        self.running.store(false, Ordering::SeqCst);
    }
}
