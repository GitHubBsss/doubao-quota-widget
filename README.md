# doubao-quota-widget

给豆包（Doubao）Windows 桌面客户端加一个「打开就在」的悬浮额度球：环形显示剩余额度、悬停展开明细面板、双击打开额度管理页。全程不额外启动窗口程序，靠 CDP 把挂件注入到豆包自己的聊天页面里。

## 效果

- **环形额度球**：满圈 = 当前积分总量，亮色弧 = 剩余占比，圈内直接写剩余积分。剩余低于 50% 转琥珀色，低于 20% 转红色。
- **两格套圈**：账号带「5 小时 / 周」窗口限额时，外层金色 = 周限额、内层蓝色 = 5 小时限额，各自按自己的剩余百分比点亮。没有这类窗口时只有一格。
- **悬停面板**：当前模型（含推理档位）、可用额度、已用 / 总额及百分比、今日新增消耗、最近窗口归零时间、额度档位、30 秒刷新时间，底部是今日消耗趋势折线。
- **双击**球体打开豆包官方「订阅与额度管理」页面。
- **可拖动**：按住球拖动，位置落到 `widget-pos.json`，重启客户端/重建挂件后仍然复用；球在左半边时面板自动向右展开。

## 工作原理

1. 豆包客户端带 `--remote-debugging-port=9222` 启动，Chromium 的调试端口可用。
2. 主聊天页是 `doubao://doubao-chat/chat/...` 私有协议，浏览器扩展匹配不到；但 CDP 不看协议，因此走 CDP 注入。
3. `doubao-widget-daemon.ps1` 常驻（无控制台窗口），每 2.5 秒检查页面里挂件是否还在，不在就重新注入 `widget.js`；每 30 秒通过页面内的 `drive-iframe` 上下文调额度接口刷新数据，并原地更新 DOM。
4. 挂件是纯 DOM + SVG，无依赖、无外部资源。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）
- 豆包桌面客户端（在 Chromium 147 上验证）
- Node.js 仅 `tools/` 下的调试脚本需要，主程序不需要

## 安装

### 1. 让豆包带调试端口启动

找到豆包快捷方式（桌面或开始菜单），右键 → 属性 → 目标，在原有路径后追加参数：

```
--remote-debugging-port=9222
```

例如：

```
"D:\Soft\Doubao\app\Doubao.exe" --remote-debugging-port=9222
```

指向 `app\Doubao.exe` 而不是外层启动器，避免启动器不透传参数。改完重新打开豆包，访问 `http://127.0.0.1:9222/json/version` 能看到 JSON 即成功。

### 2. 填写账号参数

复制 `config.example.json` 为 `config.json`，填入自己的 `aid`：

```json
{ "aid": "你的aid" }
```

`aid` 是额度请求 URL 里的账号维度参数。打开豆包额度管理页，在开发者工具的网络面板里找 `alice/commerce/sale/subscription/overview/` 这条请求，URL 上的 `aid=` 就是。也可以用环境变量 `DOUBAO_AID` 代替配置文件。

### 3. 启动守护进程

```powershell
wscript.exe start-daemon.vbs
```

`wscript` 是 GUI 子系统，不会弹出控制台窗口。启动后右侧出现额度球，日志写在 `daemon.log`。

### 4. 开机自启（可选）

```powershell
$vbs = "D:\path\to\doubao-quota-widget\start-daemon.vbs"
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DoubaoWidget' `
  -Value ('"C:\Windows\System32\wscript.exe" "{0}"' -f $vbs) -PropertyType String -Force
```

删除该值即可取消自启。

## 目录结构

```
widget.js                 注入到页面的挂件（环形球 + 面板 + 拖动 + 原地更新）
doubao-widget-daemon.ps1  守护进程：CDP 连接、注入保活、额度拉取、数据落盘
start-daemon.vbs          无窗口启动器
config.example.json       账号参数模板
tools/cdp-eval.js         调试用：在页面里执行表达式，可截图
tools/quota-fetch.js      调试用：直接调额度接口看返回
tools/capture-quota.js    调试用：抓额度接口响应
tools/capture-stream.js   调试用：抓对话流响应（用于分析 token/缓存字段）
tools/inject.js           早期一次性注入载荷，保留作参考
```

运行时产物（`data.json`、`quota-history.json`、`widget-pos.json`、`daemon.log` 等）已在 `.gitignore` 中排除。

## 数据格式

`data.json` 是守护进程写给挂件的数据，字段如下：

| 字段 | 说明 |
| --- | --- |
| `badge` | 紧凑额度文本（如 `2.7k`） |
| `gauge.center` | 圈内文字，通常是完整剩余积分 |
| `gauge.rings[]` | 每格圆环：`pct` 剩余百分比，`color` 可选 |
| `rows` | 面板行 `[[标签, 值], ...]` |
| `trend` | 今日累计消耗采样点，用于折线 |
| `openUrl` | 双击打开的地址 |
| `left` / `top` | 用户拖动后的坐标（存在时优先于默认位置） |

## 已知限制

- 额度接口不是公开 API，字段和路径可能随客户端版本变化；脚本对缺失字段做了兜底，但接口改版后仍需调整。
- 5 小时 / 周限额只在有对应权益的账号上出现，免费账号的 `window_limit_section` 为空，此时只有一圈。
- 依赖页面 cookie 调接口，登录态失效时额度会刷新失败（日志里是 `quota error`），重新登录即可。
- 仅适配 Windows；其它平台的窗口/进程模型不同。

## 说明

本项目只在本机做注入和展示，不向外部服务上传任何数据；额度请求走的是豆包客户端自己的会话。修改客户端启动参数、注入页面属于非官方用法，客户端升级后可能失效。
