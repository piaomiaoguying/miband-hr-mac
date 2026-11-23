use std::path::PathBuf;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Adv,
    Gatt,
    Mock,
    Dump,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Adv => "adv",
            Mode::Gatt => "gatt",
            Mode::Mock => "mock",
            Mode::Dump => "dump",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub mode: Mode,
    pub port: u16,
    pub device: Option<String>,
    pub offset: usize,
    pub stale_secs: u64,
    pub hold_secs: u64,
    pub data_dir: PathBuf,
    pub open_browser: bool,
    pub verbose: bool,
    pub dump_all: bool,
}

pub enum ParseOutcome {
    Run(Config),
    Help,
    Version,
}

impl Config {
    pub fn parse() -> Result<ParseOutcome, String> {
        let mut mode = Mode::Adv;
        let mut port: u16 = 3030;
        let mut device: Option<String> = None;
        let mut offset: usize = 3;
        let mut stale_secs: u64 = 15;
        let mut hold_secs: u64 = 45;
        let mut data_dir: Option<PathBuf> = None;
        let mut open_browser = true;
        let mut verbose = false;
        let mut dump_all = false;

        let args: Vec<String> = std::env::args().skip(1).collect();
        let mut i = 0;
        while i < args.len() {
            let arg = args[i].as_str();
            match arg {
                "-h" | "--help" => return Ok(ParseOutcome::Help),
                "-V" | "--version" => return Ok(ParseOutcome::Version),
                "--mock" => mode = Mode::Mock,
                "--dump" => mode = Mode::Dump,
                "--dump-all" => {
                    mode = Mode::Dump;
                    dump_all = true;
                }
                "--verbose" | "-v" => verbose = true,
                "--no-open" => open_browser = false,
                "--mode" => {
                    i += 1;
                    let value = args.get(i).ok_or("--mode 缺少参数")?;
                    mode = match value.as_str() {
                        "adv" => Mode::Adv,
                        "gatt" => Mode::Gatt,
                        "mock" => Mode::Mock,
                        "dump" => Mode::Dump,
                        _ => {
                            return Err(format!(
                                "未知 mode：{value}（可选 adv / gatt / mock / dump）"
                            ))
                        }
                    };
                }
                "--device" => {
                    i += 1;
                    device = Some(args.get(i).ok_or("--device 缺少参数")?.clone());
                }
                "--offset" => {
                    i += 1;
                    offset = args
                        .get(i)
                        .ok_or("--offset 缺少参数")?
                        .parse()
                        .map_err(|_| "--offset 需要 0~31 的整数".to_string())?;
                    if offset > 31 {
                        return Err("--offset 需要 0~31 的整数".into());
                    }
                }
                "--port" => {
                    i += 1;
                    port = args
                        .get(i)
                        .ok_or("--port 缺少参数")?
                        .parse()
                        .map_err(|_| "--port 需要 1~65535 的整数".to_string())?;
                    if port == 0 {
                        return Err("--port 需要 1~65535 的整数".into());
                    }
                }
                "--stale" => {
                    i += 1;
                    stale_secs = args
                        .get(i)
                        .ok_or("--stale 缺少参数")?
                        .parse()
                        .map_err(|_| "--stale 需要 2~120 的整数秒".to_string())?;
                    if !(2..=120).contains(&stale_secs) {
                        return Err("--stale 需要 2~120 的整数秒".into());
                    }
                }
                "--hold" => {
                    i += 1;
                    hold_secs = args
                        .get(i)
                        .ok_or("--hold 缺少参数")?
                        .parse()
                        .map_err(|_| "--hold 需要 2~600 的整数秒".to_string())?;
                    if !(2..=600).contains(&hold_secs) {
                        return Err("--hold 需要 2~600 的整数秒".into());
                    }
                }
                "--data-dir" => {
                    i += 1;
                    data_dir = Some(PathBuf::from(args.get(i).ok_or("--data-dir 缺少参数")?));
                }
                other => return Err(format!("未知参数：{other}")),
            }
            i += 1;
        }

        let data_dir = data_dir.unwrap_or_else(|| match mode {
            Mode::Mock => PathBuf::from("data/mock"),
            _ => PathBuf::from("data"),
        });

        Ok(ParseOutcome::Run(Config {
            mode,
            port,
            device,
            offset,
            stale_secs,
            hold_secs,
            data_dir,
            open_browser,
            verbose,
            dump_all,
        }))
    }

    pub fn matches_device(&self, name: &str, id: &str) -> bool {
        match &self.device {
            None => true,
            Some(needle) => {
                let needle = needle.to_lowercase();
                name.to_lowercase().contains(&needle) || id.to_lowercase().contains(&needle)
            }
        }
    }
}

pub fn help_text() -> String {
    format!(
        r#"miband-hr-mac {VERSION}
macOS 小米手环心率监听（小米手环 4~7 运动心率广播）

用法：miband-hr-mac [选项]

选项：
  --mode adv|gatt|mock|dump  运行模式（默认 adv：监听运动心率广播）
  --mock                     模拟数据，用于预览面板
  --dump                     打印附近 BLE 广播原始数据，用于排障
  --dump-all                 打印所有 BLE 广播（不只小米设备）
  --device <文本>            只接收名称或 ID 包含该文本的设备
  --offset <0~31>            心率字节在厂商数据中的偏移（默认 3）
  --port <端口>              本地面板端口（默认 3030）
  --stale <秒>               超过多少秒没有新数据不再视为实时（默认 15）
  --hold <秒>                旧心率最多保留显示多少秒（默认 45）
  --data-dir <目录>          CSV 保存目录（默认 data/）
  --no-open                  启动后不自动打开浏览器
  -v, --verbose              输出每一条有效广播
  -h, --help                 显示帮助
  -V, --version              显示版本

面板：http://127.0.0.1:3030/
OBS：http://127.0.0.1:3030/overlay
"#
    )
}
