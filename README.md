# Miband HR Mac

在 macOS 上读取小米手环「运动心率广播」，实时显示心率，并可记录 CSV、查看趋势图、叠加到 OBS、或以原生透明浮窗常驻桌面。

不登录小米账号、不需要 auth key、不上传任何数据。全部在本机通过蓝牙完成。

## 特性

| 能力 | 说明 |
| --- | --- |
| 厂商广播解析 | 监听 Xiaomi / Huami 广播（Company ID `0x0157`），不做 GATT 连接，不需要配对 |
| 原生浮窗 | AppKit 透明浮窗，置顶显示、可拖动、可缩放、可点击穿透、支持纯透明背景 |
| 网页面板 | 实时 BPM、本次最低 / 平均 / 最高、5–60 分钟趋势图、数据表、CSV 导出 |
| OBS 悬浮层 | 透明背景的浏览器源，适合叠加到直播画面 |
| 数据记录 | 按天写入 `data/heart-rate-YYYY-MM-DD.csv` |
| 广播稀疏自适应 | 手环广播间隔较大时继续显示上次心率并标注时间，不闪 `--` |
| 开机自启 | 原生浮窗右键菜单可开关登录自启（LaunchAgent） |

## 支持范围

| 项目 | 说明 |
| --- | --- |
| 支持手环 | 小米手环 4 / 5 / 6 / 7 的「运动心率广播」 |
| 系统要求 | macOS 12 或以上（浮窗为 arm64 构建） |
| 网络与账号 | 全程本地 BLE，不需要登录，不需要 auth key |
| 使用前提 | 官方 App 中开启「运动心率广播」，并在手环上开始一项运动 |

心率来自小米厂商广播：Company ID `0x0157`，payload 第 4 个字节（偏移 `3`）。手环未进入运动模式时该字节通常为 `255` 或 `0`，不会产生有效心率。

## 目录

```
miband-hr-mac/
├── src/                      Rust 后台服务（BLE、状态、HTTP）
├── web/                      网页面板与 OBS 悬浮层
├── native/                   原生浮窗 AppKit 源码与 Info.plist
├── docs/protocol.md          广播协议与调试笔记
├── start.command             双击后台启动（同时打开原生浮窗）
├── stop.command              双击停止（同时关闭浮窗）
├── status.command            双击查看运行状态与当前心率
├── run.command               双击前台启动（日志显示在终端）
├── mock.command              双击启动（模拟数据，预览面板）
├── diagnose.command          双击启动（打印 BLE 原始广播）
├── build.sh                  编译 Rust 服务 → bin/
├── build-float.sh            编译原生浮窗 → dist/MibandFloat.app
├── data/                     CSV 与运行日志（运行时自动创建，不入库）
└── README.md
```

## 快速开始

### 1. 手环准备

1. 打开手机上的 **小米运动健康** 或 **Zepp Life（原小米运动）**。
2. 进入 **我的 → 设备 → 小米手环 5**。
3. 找到 **运动心率广播**，打开开关；如果同一页面还有 **蓝牙广播**，一并打开。
4. 在手机 App 中把自动心率检测设为较高频率（可选，能加快数据更新）。
5. 把手环戴紧，选择一项运动并开始，例如 **自由训练** 或 **户外跑**。

> 心率广播只在运动进行中输出心率。只开广播、不开始运动时，广播仍在，但心率字节为 `255`。

### 2. 释放手环

关闭手机蓝牙，或至少退出小米运动健康 / Zepp Life。手环同一时间只服务一个连接对象；手机占用时，Mac 可能收不到广播。

### 3. 启动

日常使用可以直接双击 **`dist/MibandFloat.app`**，App 会自动拉起后台服务；也可以双击 **`start.command`**，两者一起启动。

- 停止：双击 **`stop.command`**，后台服务和浮窗一起关闭；也可在浮窗菜单选择 **退出并停止后台服务**；
- 查看状态：双击 **`status.command`**，显示 PID、当前心率和数据时间；
- 首次运行 macOS 会请求蓝牙权限，选择 **允许**；
- 重复启动 App 或 `start.command` 不会启动多个实例，只会重新打开浮窗；
- 需要网页仪表盘或 CSV 时，在浮窗菜单里选择 **打开网页面板**。

需要在前台看日志时，改用 **`run.command`**：日志直接输出到终端，按 `Ctrl-C` 停止。

预期结果：

- 浮窗状态从“正在扫描”变为“实时”；
- 大号 BPM 持续显示最近一次心率，广播间隔较大时显示“保持中”并继续保留数值；
- 网页面板中可以看到心率曲线；
- `data/heart-rate-YYYY-MM-DD.csv` 持续写入。

> 本机实测小米手环 5 的广播间隔约 6–37 秒（多数约 10 秒），远低于协议文档常写的 1 Hz。程序默认把 15 秒内的数据视为实时，15–45 秒显示“保持中”，超过 45 秒才判定信号中断；这段时间内数值不会变成 `--`。


后台启动时用 `stop.command` 停止；前台运行 `run.command` 时按 `Ctrl-C` 停止。

### 4. 没有手环时预览

双击 **`mock.command`**，使用生成的数据预览完整面板与 OBS 悬浮层，不访问蓝牙。地址为 `http://127.0.0.1:3031/`。

## 面板与输出

- 实时 BPM、本次最低 / 平均 / 最高、样本数；
- 状态“实时 / 保持中 / 信号中断”：广播稀疏时继续显示最近一次心率，并在更新时间标注距今秒数；
- 最近 5 / 10 / 30 / 60 分钟趋势；
- 鼠标悬停或键盘方向键查看具体时刻；
- “数据表”展开最近 20 条记录；
- “导出 CSV”下载当前文件；
- 设备名称、设备 ID、RSSI、原始广播字节、CSV 路径。

CSV 字段：

```
timestamp,epoch_ms,device,device_id,rssi,bpm,source,raw_hex
```

`source` 取值：`adv`（运动心率广播）、`gatt`（标准心率服务）、`mock`（模拟数据）。

默认路径：`data/heart-rate-YYYY-MM-DD.csv`。按天自动新建文件。

## 原生浮窗

`dist/MibandFloat.app` 是 AppKit 原生浮窗，读取本机服务 `http://127.0.0.1:3030/api/state`，与网页面板、CSV 共用同一份数据。

- 无边框、半透明圆角，始终浮在其他窗口之上，可出现在所有桌面空间和全屏应用上方；
- 按住任意位置拖动，位置自动保存；
- 支持「锁定位置（点击穿透）」：锁定后鼠标点击会穿透到下层应用，按 **⌘⇧L** 解除锁定；
- 拖动右下角的斜线手柄可连续缩放，也可以在右键菜单的 **大小** 中选择小 / 中 / 大 / 特大；
- 状态与网页一致：实时 / 保持中 / 信号中断；广播稀疏时保留最近一次心率并变暗，不闪 `--`；
- 右键菜单提供：显示 / 隐藏、锁定位置（点击穿透）、纯透明背景、开机自动启动、大小、启动 / 停止 / 重启后台服务、蓝牙权限设置、打开网页面板、重置位置、退出浮窗、退出并停止后台服务；
- 没有 Dock 图标，也没有菜单栏图标。浮窗隐藏后，再次双击 `dist/MibandFloat.app` 即可重新显示。

启动方式：

- 直接双击 `dist/MibandFloat.app`：检测到本机服务未运行时会自动启动 `bin/miband-hr-mac`；
- 双击 `start.command`：后台服务与浮窗一起启动；
- 重新编译：`./build-float.sh`，需要 Xcode Command Line Tools，产物为 arm64、macOS 12+。

直接启动 App 时，macOS 首次会询问“MibandFloat.app 想要使用蓝牙”，选择 **允许**。如果当时点了不允许，可在浮窗菜单选择 **蓝牙权限设置** 重新授权，再选择 **重启后台服务**。`stop.command` 仍会同时关闭后台服务和浮窗。

## OBS 悬浮层

在 OBS 中添加 **浏览器** 源：

```
http://127.0.0.1:3030/overlay
```

建议尺寸 `600 × 220`，背景透明。页面只包含心形与 BPM，适合叠加在摄像头画面或直播场景上。

可选参数：

| 参数 | 示例 | 说明 |
| --- | --- | --- |
| `scale` | `?scale=1.5` | 整体缩放，范围 0.4–4 |
| `color` | `?color=%23ff3b5c` | 心形颜色，6 位十六进制 |
| `label=0` | `?label=0` | 隐藏 BPM 字样 |
| `heart=0` | `?heart=0` | 隐藏心形 |
| `bg=1` | `?bg=1` | 显示半透明深色底 |
| `hide-idle=1` | `?hide-idle=1` | 超过保持时长仍无心率时完全隐藏 |

示例：

```
http://127.0.0.1:3030/overlay?scale=1.4&color=%23e66767
```

超过保持时长仍无新数据时，保留最近一次心率并降低透明度；从未收到有效心率或手环明确上报 `255` 时显示 `--`。恢复广播后自动回到实时数字。

## 命令行

`run.command` 和 `start.command` 都会把参数原样传给程序。以下命令需先执行 `./build.sh` 生成 `bin/miband-hr-mac`：

```bash
# 换端口
./bin/miband-hr-mac --port 3031

# 只接收名称或 ID 包含指定文本的设备
./bin/miband-hr-mac --device "Mi Smart Band 5"

# 调整实时判定与保持显示时长（秒）
./bin/miband-hr-mac --stale 20 --hold 60

# 心率字节偏移不是 3 时（先用 diagnose.command 确认）
./bin/miband-hr-mac --offset 4

# 标准心率服务回退（0x180D / 0x2A37）
./bin/miband-hr-mac --mode gatt --device "Mi Smart Band 5"

# 打印每条有效广播
./bin/miband-hr-mac --verbose

# 完整帮助
./bin/miband-hr-mac --help
```

`--mode gatt` 是回退路径：连接设备并订阅标准心率服务。小米手环 5 的运动心率广播默认走厂商广播，优先使用默认的 `adv` 模式。

## 诊断

双击 **`diagnose.command`**，终端会打印附近 BLE 设备的广播：

```
[诊断] name="Mi Smart Band 5" id=... rssi=-52dBm company=0x0157 len=... payload=[...] b0=... b1=... b2=... b3=...
```

排查顺序：

1. 手环开始运动后，是否出现 `company=0x0157` 的记录；
2. `b3` 是否为 20–250 之间的合理心率；
3. 若 `b3=255` 或 `0`，确认已开始运动、佩戴贴合；
4. 若 `b3` 明显不是心率，查看其它 `bN`，用 `--offset N` 指定正确偏移；
5. 找不到手环时，先关闭手机蓝牙，再运行 `diagnose.command all` 查看所有广播。

诊断日志保存在 `data/diagnose-YYYYMMDD-HHMMSS.log`。

## 硬件实测清单

按顺序执行，约 5 分钟：

1. 手环充电至 50% 以上，戴紧，传感器贴住皮肤。
2. 手机蓝牙关闭；确认小米运动健康 / Zepp Life 不在后台占用。
3. 手机 App 中“运动心率广播”为开启状态。
4. 手环上开始 **自由训练**（若异常，换 **户外跑** 再试）。
5. 双击 `start.command`（或前台运行 `run.command`），允许蓝牙权限。
6. 观察面板：状态是否在 5 秒内进入“实时”，BPM 是否在 10 秒内出现。
7. 记录 RSSI；正常应在 `-40 ~ -75 dBm`。低于 `-85 dBm` 时靠近 Mac。
8. 停止运动后，超过保持时长（默认 45 秒）仍无新心率时状态变为“信号中断”并降低数值透明度；手环明确上报 `255` 时立即显示“等待心率”和 `--`。重新开始运动应自动恢复。
9. 运行 2 分钟，点击“导出 CSV”，确认行数与 BPM 连续。
10. OBS 添加 `http://127.0.0.1:3030/overlay`，确认透明背景与实时刷新。

失败时：

- 一直“正在扫描”：运行 `diagnose.command`，看是否有 `company=0x0157`；
- 有广播但“等待心率”：看 `b3` 是否为 `255`，检查运动模式与佩戴；
- 数字异常：用 `diagnose.command` 对照 `bN`，调整 `--offset`；
- 权限问题：见下一节。

## 常见问题

**首次运行没有弹权限，或没有数据**

打开 **系统设置 → 隐私与安全性 → 蓝牙**，确认 **Terminal**（或你使用的终端）已允许。直接双击原生浮窗时，还需要允许 **MibandFloat / 心率浮窗**。修改后退出终端或重启浮窗再试。`tccutil reset Bluetooth` 会重置所有应用的蓝牙权限，非必要不要使用。

**端口 3030 被占用**

`start.command` 检测到端口被占用时不会重复启动。换端口：

```bash
./start.command --port 3031
```

再访问 `http://127.0.0.1:3031/`。`start.command` 会把同一个端口传给浮窗；单独双击 `dist/MibandFloat.app` 时默认连接 3030。

**浮窗不见了，或显示“后端未运行”**

浮窗没有 Dock 图标，也没有菜单栏图标。如果之前用右键菜单隐藏了浮窗，再次双击 `dist/MibandFloat.app` 即可重新显示。

直接启动 App 会自动尝试启动后台服务；如果仍显示“后端未运行”，检查 `dist/MibandFloat.app` 是否放在项目目录内，或改用 `start.command` 启动。

**直接启动 App 后显示“需要蓝牙权限”或一直“正在扫描”**

首次直接启动时 macOS 会弹出“MibandFloat.app 想要使用蓝牙”，需要点 **允许**。错过提示时，在浮窗菜单选择 **蓝牙权限设置**，打开 **系统设置 → 隐私与安全性 → 蓝牙** 允许 MibandFloat，然后选择 **重启后台服务**。后台服务和浮窗必须配对运行；后台服务即 `bin/miband-hr-mac`（由 `build.sh` 生成）。

**开了开机自启，想关掉**

右键菜单里取消「开机自动启动」即可，也可以手动删除 `~/Library/LaunchAgents/local.miband.float.plist`。

注意：系统设置「通用 → 登录项」里可能仍有一条以可执行文件路径命名的记录，那是 macOS 为运行中的无 Dock 应用登记的活跃状态，不是自启动项，退出 App 后会自动消失。

**锁定位置后浮窗拖不动**

按 **⌘⇧L** 解除锁定，或在右键菜单里取消「锁定位置（点击穿透）」。锁定后鼠标点击会穿透到下层应用，适合只用来观看。

**双击 `start.command` 后窗口立刻关闭**

这是后台启动的正常表现，程序仍在运行。双击 `status.command` 可确认 PID 与当前心率；启动失败时窗口会保留错误与最近日志。

**双击脚本没有反应，或提示没有执行权限**

在终端进入本目录，补一次权限：

```bash
chmod +x start.command stop.command status.command run.command mock.command diagnose.command build.sh build-float.sh
```

如果系统提示“无法验证开发者”，右键对应脚本选择“打开”，或执行：

```bash
xattr -dr com.apple.quarantine .
```

**状态一直是“等待心率”**

广播已收到，但没有有效心率。确认：

- 手环已开始运动，而不是停在表盘；
- 手环戴紧，背面传感器贴合皮肤；
- 手机 App 中的“运动心率广播”已开启；
- 不是“户外跑”刚启动的预热阶段，可换“自由训练”。

**状态是“信号中断”**

超过保持时长（默认 45 秒，可用 `--hold` 调整）没有收到新广播。常见原因：手环停止运动、手环离开范围、手机重新占用了手环、Mac 蓝牙被其他应用占用。若只是广播稀疏，状态会先显示“保持中”，数值不会变成 `--`。

**诊断输出里的 b3 是 255、0 或明显不合理的值**

`255` / `0` 表示当前没有心率，不是真实 BPM，面板会显示 `--`。若 `b3` 是其他异常值，运行 `diagnose.command`，把 `payload` 与 `b0…b15` 记下来，用 `--offset` 指定心率所在字节。

**找不到标准心率服务（GATT 模式）**

小米手环 5 的运动心率广播不保证暴露标准 `0x180D` 服务。默认的 `adv` 模式不依赖该服务，应优先使用。

**终端窗口关闭后看不到日志**

日志追加在 `data/app.log`；诊断日志在 `data/diagnose-*.log`。

**换一台 Mac**

可执行文件和浮窗均为 Apple Silicon（arm64）构建，浮窗要求 macOS 12+。Intel Mac 或其他 macOS 版本请在目标机器上运行 `./build.sh` 和 `./build-float.sh` 重新编译。

## 技术说明

- 广播：Xiaomi / Huami Company ID `0x0157`；payload 第 4 字节为心率；实测间隔 6–37 秒，随固件与屏幕状态变化。
- 无效值：`0`、`255`；有效范围按 `20–250` 处理。
- macOS 通过 CoreBluetooth 读取 `CBAdvertisementDataManufacturerDataKey`，使用 Rust `bluest`。
- 标准心率回退：服务 `0x180D`，特征 `0x2A37`，兼容标准心率带。
- 同一时间只跟踪一个目标设备；可用 `--device` 固定。
- 所有服务只监听 `127.0.0.1`，不对外网开放。
- 协议与调试细节见 [`docs/protocol.md`](docs/protocol.md)。

## 从源码构建

需要 Rust 工具链与 Xcode Command Line Tools。

```bash
# macOS 上安装依赖
xcode-select --install
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 构建
./build.sh          # cargo build --release，产物复制到 bin/
./build-float.sh    # swiftc 编译原生浮窗，产物在 dist/MibandFloat.app
cargo test          # 广播解析、标准心率解析、CSV 转义等单元测试
```

构建产物（`bin/`、`dist/`）与运行时数据（`data/`）都不纳入版本控制。

前端为单个 HTML 文件，无 CDN、无外部字体、无构建步骤；修改 `web/` 后重新执行 `./build.sh` 即可（HTML 通过 `include_str!` 编译进二进制）。原生浮窗源码在 `native/`，修改后执行 `./build-float.sh`。

## 参考

- [Tnze/miband-heart-rate](https://github.com/Tnze/miband-heart-rate)
- [小米手环 OBS 直播心率简明教程](https://www.bilibili.com/read/cv27510579/)
- [小米手环 5 无线心率广播应用](https://zhuanlan.zhihu.com/p/591331326)
- [Gadgetbridge](https://github.com/Freeyourgadget/Gadgetbridge)（Android 端小米手环协议参考）

## 致谢

本项目受 [Tnze/miband-heart-rate](https://github.com/Tnze/miband-heart-rate)（MIT）启发。该项目的 Rust + `bluest` 蓝牙思路为本项目提供了起点；本项目在此之上改为解析小米厂商广播（`0x0157`），并新增网页面板、OBS 悬浮层、原生浮窗等能力，代码为独立实现。

本项目同样以 MIT 协议发布，见 [LICENSE](LICENSE)。

## 免责声明

本项目与小米、华米无任何关联，未获其授权或背书。「小米」「Mi Band」等商标归各自所有者所有。使用本软件产生的任何后果由使用者自行承担。
