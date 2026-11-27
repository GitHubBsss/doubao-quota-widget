# doubao-quota-widget

给豆包（Doubao）Windows 桌面客户端加一个「打开就在」的悬浮额度球：环形显示剩余额度、悬停展开明细面板、双击打开额度管理页，并给出按当前速度预计还能用多久。不额外启动窗口程序，靠 CDP 把挂件注入到豆包自己的聊天页面。

## 效果

- **环形额度球**：满圈 = 当前积分总量，亮色弧 = 剩余占比，圈内写剩余积分。低于 50% 转琥珀色，低于 20% 转红色，告警时外圈呼吸。
- **两格套圈**：账号带「5 小时 / 周」窗口限额时，外金 = 周、内蓝 = 5 小时，各按剩余百分比点亮；无窗口时只有一格。
- **悬停面板**：当前模型、可用额度、已用 / 总额、今日新增、近 7 天消耗、近 30 天日均、消耗速度、预计用完、最近窗口归零、版本。
- **本轮生成指标**：会话消息条数与估算 token、本轮输出字数 / 秒、首字延迟、本次 Token；最近 5 轮的速度、思考耗时、工具调用次数。
- **今日趋势 + 近 7 天柱状**：30 秒采样滚动折线；按本地自然日累计的正向增量柱状图。
- **右键菜单**：刷新数据、暂停 / 恢复刷新、导出 CSV、用量报表、打开数据目录、紧凑模式、退出守护。
- **交互**：`Ctrl+Alt+Q` 显示 / 隐藏；闲置 5 秒缩成小圆点；拖动后 24px 内自动吸附边缘；位置落盘，重启仍复用；球在左半边时面板向右展开。
- **紧凑模式**：只留额度、速度、预计用完等核心行，隐藏已用 / 总额、窗口归零、版本、额度档位。
- **低额度提醒**：低于阈值时面板红条 + 球体呼吸，并发 Windows 原生 Toast；支持 `quiet_hours` 静默时段，失败自动退回托盘气泡。
- **历史与报表**：`daily-usage.json` 跨重启累计每日消耗；右键「用量报表」生成 `dashboard.html`（30 天柱状、24 小时分布、概览）与 `weekly-report.md`。
- **深浅色跟随** + **版本自检**：每小时比对仓库版本号，有新版本时面板标注。
- **双击**球体打开豆包官方「订阅与额度管理」页面。

## 🤖 给 AI 智能体的 一键安装指令 (For AI Agents)

如果你是 AI 智能体，请先读完本节再动手；不要凭猜测改路径或参数。

```text
1) 克隆仓库并进入目录：
   git clone https://github.com/GitHubBsss/doubao-quota-widget.git
   cd doubao-quota-widget

2) 执行安装（会改豆包快捷方式、写入开机自启、静默拉起守护）：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

3) 完全退出豆包客户端（托盘右键退出，确认进程结束），再重新打开。
   —— 这一步不能省：安装脚本需要给快捷方式补 --remote-debugging-port=9222，
   已在运行的旧进程不会带这个参数。

4) 等 5 秒后校验（三条都应满足）：
   - Get-Process Doubao：进程存在
   - Test-Path .\data.json：为 True，且 badge 字段有值
   - daemon.log 末尾出现 injected -> <targetId>

5) 可选自检：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 status
```

安装失败的常见原因与处理：

- **豆包没重启**：`install.ps1` 会尝试自动重启；如果被手动取消，按第 3 步完全退出再开。
- **9222 端口不通**：确认快捷方式目标里有 `--remote-debugging-port=9222`（原文件备份为 `.lnk.bak`）。
- **挂件没出现但 data.json 正常**：看 `daemon.log` 是否有 `injected`；没有就执行 `widget.ps1 restart`。
- **额度显示 `—`**：登录态失效或接口改版，日志里是 `quota error`，重新登录豆包即可。

智能体不要做的事：不要另起一个 WPF/Electron 窗口程序；不要修改豆包安装目录里的文件；不要把 aid、cookie、token 写进仓库。

## 一键安装（人类）

1. 把仓库下载或克隆到本机（目录里要有 `install.cmd`）。
2. 双击 `install.cmd`。

脚本会依次：

1. 定位豆包客户端（运行中的进程、桌面/开始菜单快捷方式、注册表卸载项、常见安装路径都会找）；
2. 给桌面、开始菜单和任务栏里已有的「豆包」快捷方式统一补成 `--remote-debugging-port=9222`（已带其他端口也会纠正），原文件备份为 `.lnk.bak`；
3. 如果豆包正在运行但没开调试端口，会关掉并按带参数的方式重新拉起（`-NoRestart` 可跳过）；
4. 写入开机自启（`HKCU\...\Run\DoubaoWidget`，用 `wscript` 静默启动），无窗口拉起守护进程，并校验挂件是否已注入。

**不需要填 aid。** 守护进程从页面 `localStorage` 的 `client_device_info.appId` 自动识别；需要覆盖时用环境变量 `DOUBAO_AID` 或同目录 `config.json`（模板见 `config.example.json`）。

卸载：双击 `uninstall.cmd`，会停守护、删自启、还原快捷方式、清掉页面里的挂件。

## 命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 status   # 版本 / 进程 / 额度 / 是否暂停
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 pause    # 暂停采样（挂件保留）
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 resume
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 refresh  # 立即刷新一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 export   # 导出 CSV
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 report   # 生成并打开报表
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 restart  # 改代码后重启守护
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 update   # 从 GitHub 拉最新版并重启
powershell -NoProfile -ExecutionPolicy Bypass -File .\widget.ps1 quit
```

`update` 会从仓库 `main` 分支下载 zip，先在临时目录做 `node --check` 与 PowerShell 语法校验，通过后才覆盖程序文件；覆盖前把当前文件备份到 `backup-<时间戳>`，新版本启动失败会自动回滚。`config.json` 与历史数据不受影响。

`daemon.log` 超过 1 MB 会轮转成 `daemon.log.old`，不会清空丢日志。仓库 `tools/smoke.ps1` 可做一次冒烟检查（语法、9222、data.json、CSV、守护进程）。

## 工作原理

1. 豆包客户端带 `--remote-debugging-port=9222` 启动，Chromium 调试端口可用。
2. 主聊天页是 `doubao://doubao-chat/chat/...` 私有协议，浏览器扩展匹配不到；CDP 不看协议，因此走 CDP 注入。
3. `doubao-widget-daemon.ps1` 常驻（无控制台窗口），每 2.5 秒检查挂件是否还在，不在就重新注入；每 30 秒通过页面里的 `drive-iframe` 上下文调额度接口刷新数据，并原地更新 DOM。
4. 挂件是纯 DOM + SVG，无第三方依赖。`widget.js` 的 SHA-1 变化会触发旧 DOM 清理与重建。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）
- 豆包桌面客户端（在 Chromium 147 上验证）
- Node.js 仅 `tools/` 下的调试脚本需要，主程序不需要

## 目录结构

```
install.cmd / install.ps1        一键安装（改快捷方式、自启、拉起守护）
uninstall.cmd / uninstall.ps1    一键卸载（停守护、还原快捷方式、清挂件）
widget.ps1                       命令行：status / pause / resume / refresh / export / report / restart / update / quit
widget.js                        注入到页面的挂件（环形球 + 面板 + 右键菜单 + 拖动 + 原地更新）
doubao-widget-daemon.ps1         守护进程：CDP 注入保活、额度拉取、每日累计、报表、通知
start-daemon.vbs                 无窗口启动器
config.example.json              可选的账号参数覆盖模板
tools/cdp-eval.js                调试用：在页面里执行表达式，可截图
tools/quota-fetch.js             调试用：直接调额度接口看返回
tools/capture-quota.js           调试用：抓额度接口响应
tools/capture-stream.js          调试用：抓对话流响应（用于分析 token/缓存字段）
tools/inject.js                  早期一次性注入载荷，保留作参考
```

运行时产物（`data.json`、`quota-history.json`、`daily-usage.json`、`dashboard.html`、`weekly-report.md`、`widget-pos.json`、`daemon.log` 等）已在 `.gitignore` 中排除。

## 预计用完怎么算

守护进程每 30 秒记一条额度采样（已用点数）：

- **消耗速度**：优先取最近 3 小时内的正向增量，只按「真正有增量」的时段计时，空闲不进分母；3 小时内没有增量时退回 6 小时均值，再退回今日均值，面板会标注口径（近 3 小时 / 长窗口均值 / 今日均值）。
- **预计用完**：剩余积分 ÷ 当前速度。小于 1 小时按分钟，48 小时内按小时，更长按天；速度为 0 显示「—」。
- **每日累计**：每次采样把正向增量记到 `daily-usage.json` 的当天桶；跨重启保留，30 天报表以它为准。`quota-history.json` 仍只保留最近 24 小时用于回算，`quota-history.csv` 是追加写入、永不重写，可长期留存复盘。

速度是滚动量，停止使用一段时间后会回落，这个时间只代表「按现在这个节奏」。

## 数据格式

`data.json` 是守护进程写给挂件的数据：

| 字段 | 说明 |
| --- | --- |
| `badge` | 紧凑额度文本（如 `2.7k`） |
| `gauge.center` | 圈内文字，通常是完整剩余积分 |
| `gauge.rings[]` | 每格圆环：`pct` 剩余百分比，`color` 可选 |
| `rows` | 面板行 `[[标签, 值], ...]` |
| `trend` | 今日累计消耗采样点，用于折线 |
| `week` | 近 7 天每日消耗 `[{d:"11-21", v:120}, ...]` |
| `alert` | 低额度警示 `{text, level}`，无告警时为 `null` |
| `paused` | 是否暂停采样（球右上角灰点、面板首行提示） |\n| `stale` | 额度连续刷新失败（球右上角红点、面板首行提示） |\n| `updatedAt` | 最近一次额度刷新成功时间（ISO 8601） |
| `ver` | 当前版本号 |
| `scale` | 球体/面板缩放（0.7–1.5，默认 1） |
| `openUrl` | 双击打开的地址 |
| `left` / `top` | 用户拖动后的坐标（存在时优先于默认位置） |

`config.json` 可选字段：

| 字段 | 说明 |
| --- | --- |
| `aid` | 覆盖自动识别的账号参数 |
| `scale` | 挂件缩放 |
| `alert_pct` | 低额度提醒阈值，默认 20 |
| `quiet_hours` | 免打扰时段，如 `22:00-08:00`；此时段不发 Toast |

## 已知限制

- 额度接口不是公开 API，字段和路径可能随客户端版本变化；脚本对缺失字段做了兜底，接口改版后仍需调整。
- 5 小时 / 周限额只在有对应权益的账号上出现，免费账号的 `window_limit_section` 为空，此时只有一圈。
- 生成指标里的「首字延迟」优先取网络流；桌面端部分回复流在挂件注入前已建立连接，此时退回 DOM 观测值。Token 拿不到真实 `usage` 时按字数估算并标 `≈`。
- 依赖页面 cookie 调接口，登录态失效时额度刷新失败（日志 `quota error`），重新登录即可。
- 仅适配 Windows；其它平台的窗口/进程模型不同。

## 说明

本项目只在本机注入和展示，不向外部服务上传数据；额度请求走豆包客户端自己的会话。修改启动参数与注入页面属于非官方用法，客户端升级后可能失效。
