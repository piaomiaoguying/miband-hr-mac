mod ble;
mod config;
mod service;
mod state;
mod web;

use std::sync::Arc;
use std::time::Duration;

use config::{Config, Mode, ParseOutcome, VERSION};
use state::SharedState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = match Config::parse() {
        Ok(ParseOutcome::Run(cfg)) => cfg,
        Ok(ParseOutcome::Help) => {
            print!("{}", config::help_text());
            return Ok(());
        }
        Ok(ParseOutcome::Version) => {
            println!("miband-hr-mac {VERSION}");
            return Ok(());
        }
        Err(error) => {
            eprintln!("参数错误：{error}\n");
            print!("{}", config::help_text());
            std::process::exit(2);
        }
    };

    println!("miband-hr-mac {VERSION}");
    println!(
        "模式：{}（{}）",
        cfg.mode.as_str(),
        state::mode_hint(cfg.mode)
    );
    if let Some(device) = &cfg.device {
        println!("设备过滤：{device}");
    }
    if cfg.mode != Mode::Mock {
        println!("心率字节偏移：{}", cfg.offset);
        println!("首次运行如弹出蓝牙权限请求，请选择“允许”");
    }
    println!();

    if cfg.mode == Mode::Dump {
        let shared = SharedState::new(cfg);
        ble::run(shared).await;
        return Ok(());
    }

    let shared = SharedState::new(cfg);
    let web_state = service::WebServiceState::new();

    // 控制端口常开：浮窗靠它订阅心率、并开关网页面板。
    let control_port = shared.cfg.port.saturating_add(1);
    let (control_address, control_server) =
        match web::bind_control(shared.clone(), web_state.clone(), control_port) {
            Ok(value) => value,
            Err(error) => {
                eprintln!(
                    "[错误] 无法监听 127.0.0.1:{control_port}：{error}（可用 --port 换一个端口）"
                );
                std::process::exit(1);
            }
        };
    println!("[控制] http://{control_address}/api/events");
    tokio::spawn(control_server);

    // 网页服务默认关闭，收到 /api/service?action=on 时再启动。
    if shared.cfg.web_on_start {
        start_web_service(
            shared.clone(),
            web_state.clone(),
            shared.cfg.port,
        );
        if shared.cfg.open_browser {
            let url = format!("http://127.0.0.1:{}/", shared.cfg.port);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(600)).await;
                let _ = std::process::Command::new("open").arg(url).status();
            });
        }
    } else {
        println!("[面板] 未启动（浮窗右键菜单可开启）");
    }
    println!("[数据] {}", shared.csv_path());
    println!();

    spawn_service_watcher(shared.clone(), web_state.clone());

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            println!("\n[退出] 已停止");
        }
        _ = ble::run(shared.clone()) => {
            eprintln!("[退出] 蓝牙任务意外结束");
        }
    }

    Ok(())
}

/// 轮询开关状态，需要启动时绑定端口并等待停止信号。
fn spawn_service_watcher(shared: Arc<SharedState>, web_state: Arc<service::WebServiceState>) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(200)).await;
            // start() 返回 true 且当前未运行时，真正绑定端口。
            if web_state.is_running() {
                continue;
            }
            if !web_state.claim_start() {
                continue;
            }
            start_web_service(shared.clone(), web_state.clone(), shared.cfg.port);
        }
    });
}

fn start_web_service(
    shared: Arc<SharedState>,
    web_state: Arc<service::WebServiceState>,
    port: u16,
) {
    let (address, server) = match web::bind(shared.clone(), port) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[错误] 无法监听 127.0.0.1:{port}：{error}");
            web_state.force_stopped();
            return;
        }
    };
    println!("[面板] http://{address}/");
    println!("[OBS ] http://{address}/overlay");

    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    web_state.mark_started(stop_tx);

    tokio::spawn(async move {
        tokio::select! {
            _ = server => {}
            _ = stop_rx => {
                println!("[面板] 已关闭");
            }
        }
    });
}
