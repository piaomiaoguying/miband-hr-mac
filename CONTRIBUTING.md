# 贡献指南

感谢你考虑为本项目做贡献。以下约定能让协作更顺畅。

## 开发环境

- macOS 12 或以上
- Rust 工具链（`rustup`）
- Xcode Command Line Tools（`xcode-select --install`）

## 构建与测试

```bash
./build.sh        # 编译 Rust 后台服务，产物在 bin/
./build-float.sh  # 编译原生浮窗，产物在 dist/MibandFloat.app
cargo test        # 运行单元测试
```

提交前请确认 `cargo test` 全绿，且没有新增编译警告。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `src/ble.rs` | 蓝牙扫描、厂商广播解析、标准心率服务回退 |
| `src/state.rs` | 心率状态机、样本缓冲、CSV 写入 |
| `src/web.rs` | 本地 HTTP 路由（面板、API、CSV 导出） |
| `src/config.rs` | 命令行参数 |
| `web/index.html` | 网页面板（单文件，无外部依赖） |
| `web/overlay.html` | OBS 悬浮层（单文件） |
| `native/main.swift` | AppKit 原生浮窗 |

## 改动约定

- **不引入前端构建步骤**：`web/` 下的 HTML 需保持零依赖，通过 `include_str!` 编入二进制。
- **浮窗渲染保持整块重绘**：`FloatView` 的绘制必须先清空整个区域再重画，避免残留旧帧。
- **不新增网络请求**：所有服务只监听 `127.0.0.1`，不上传任何数据。
- **不引入追踪或统计**。

## 提交信息

使用 `类型: 简述` 的格式，类型取 `feat` / `fix` / `docs` / `refactor` / `test` / `chore`。

```
feat(float): 右键菜单增加开机自动启动开关
fix(state): 广播稀疏时不再清空心率数值
```

## 问题反馈

提交 Issue 时请附上：

- macOS 版本与芯片架构
- 手环型号
- `diagnose.command` 的输出（隐藏设备 ID）
- 期望行为与实际行为
