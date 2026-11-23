mod ble;
mod config;
mod state;
mod web;

use std::process::Command;
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
    let (address, server) = match web::bind(shared.clone(), shared.cfg.port) {
        Ok(value) => value,
        Err(error) => {
            eprintln!(
                "[错误] 无法监听 127.0.0.1:{}：{error}（可用 --port 换一个端口）",
                shared.cfg.port
            );
            std::process::exit(1);
        }
    };
    println!("[面板] http://{address}/");
    println!("[OBS ] http://{address}/overlay");
    println!("[数据] {}", shared.csv_path());
    println!();

    tokio::spawn(server);

    if shared.cfg.open_browser {
        let url = format!("http://{address}/");
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(900)).await;
            let _ = Command::new("open").arg(url).status();
        });
    }

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
