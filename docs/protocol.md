# 小米手环运动心率广播：协议与调试笔记

## 广播帧

小米手环 4/5/6/7 在“运动心率广播”开启并进入运动模式后，会以厂商自定义数据广播心率。

- Company ID：`0x0157`（Xiaomi / Huami）
- 心率位置：厂商 payload 的第 4 个字节，0-based 偏移 `3`
- 更新频率：受固件、屏幕与运动模式影响。协议文档常按约 1 Hz 估算；本机实测小米手环 5 在屏幕熄灭或运动界面不在前台时约 6–37 秒一包（多数约 10 秒），因此程序默认使用 15 秒实时窗口和 45 秒保持窗口
- 有效心率：`20–250`
- 无效值：`0`、`255`。未开始运动时通常为 `255`

注意：macOS `bluest` 与 Python `bleak` 的 `manufacturer_data[0x0157]` 都已去掉前 2 字节的 Company ID，因此代码中的 `payload[3]` 对应完整广播数据里的第 6 个字节。用通用 BLE 调试工具查看完整帧时，需要把 Company ID 的 2 字节算进去。

示例：

```
company=0x0157 payload=[0x??, 0x??, 0x??, 0x50, ...]
                                         ^^^^
                                         0x50 = 80 BPM
```

## 有效数据的前提

1. 官方 App 中“运动心率广播”已开启；
2. 手环上已开始一项运动（自由训练、户外跑等）；
3. 手环佩戴贴合，传感器有接触；
4. 手机没有占用与手环的连接。

只开广播不开始运动时，广播仍然存在，但心率字节为 `255`。运动停止后，广播可能继续一段时间，随后停止。

## macOS 读取方式

项目使用 Rust `bluest`，底层为 CoreBluetooth：

- `Adapter::scan(&[])` 获取所有广播；
- `AdvertisementData.manufacturer_data` 中读取 `company_id` 与 `data`；
- 只在 `company_id == 0x0157` 且 `data.len() > 3` 时解析；
- 不建立 GATT 连接，不修改手环状态，不写入任何特征。

首次运行需要 macOS 蓝牙权限。权限由启动程序的终端继承；在 **系统设置 → 隐私与安全性 → 蓝牙** 中允许 Terminal / iTerm / VS Code 等。

## 标准心率服务回退

部分设备会同时暴露标准心率服务：

- Service：`0000180d-0000-1000-8000-00805f9b34fb`
- Characteristic：`00002a37-0000-1000-8000-00805f9b34fb`

`--mode gatt` 会扫描设备、建立连接并订阅该特征。解析规则：

- flags 第 0 位为 1：心率为 uint16 little-endian；
- 否则为 uint8；
- flags 第 2 位表示传感器接触支持，第 1 位表示接触状态；
- 只接受 `20–250`。

小米手环 5 的运动心率广播不保证暴露该服务，`adv` 模式是主路径，`gatt` 仅作回退。

## 为什么不需要 auth key

`Gadgetbridge` 等 Android 项目在连接小米手环、读取传感器或同步数据时，需要使用配对时生成的 16 字节 auth key 完成 Huami 认证。本项目只监听手环主动发出的运动心率广播，不建立连接、不读取 GATT、不发送命令，因此不需要 auth key，也不需要登录小米账号。

如果手环固件或官方 App 没有“运动心率广播”选项，才需要改用基于 auth key 的连接方案。小米手环 5 不在该范围内。

## 诊断输出

`--dump` 会为每台设备打印一行，重点字段：

- `company=0x0157`：小米设备；
- `payload=[...]`：厂商数据；
- `b0=… b1=… b2=… b3=…`：各字节的十进制值。

判断方法：

1. `b3` 在 `20–250` 且随手环运动变化：偏移正确；
2. `b3=255`：广播正常，但手环未测量（未运动/未贴合）；
3. `b3` 固定不变或明显不是心率：查看 `b4`、`b5` 等，使用 `--offset N` 调整；
4. 没有 `company=0x0157`：手环未广播、被手机占用、距离过远，或该型号不支持。

## CSV

```
timestamp,epoch_ms,device,device_id,rssi,bpm,source,raw_hex
```

- `timestamp`：本地时区 ISO 8601；
- `epoch_ms`：Unix 毫秒；
- `source`：`adv` / `gatt` / `mock`；
- `raw_hex`：厂商 payload（空格分隔的十六进制）。

同一秒内的重复广播会被合并：距上一条样本不足 800 ms 时不重复写入。

## 参考实现

- [Tnze/miband-heart-rate](https://github.com/Tnze/miband-heart-rate)：Rust + `bluest`，读取 `0x0157` 广播，偏移 `3`；
- [DaBinQwQ/heartrate_webui](https://github.com/DaBinQwQ/heartrate_webui)：Python + `bleak`，同样使用 `manufacturer_data[0x0157][3]`；
- [minghao680/MiBandHeartRateMonitor](https://github.com/minghao680/MiBandHeartRateMonitor)：Python + `bleak`，同样使用偏移 `3`。
