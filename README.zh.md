# dsh-win-computer-use

> 状态：✅ 已交付 · 发布件就绪（尚未进社区目录）
>
> [English →](README.md)

Windows 原生的 DSH 电脑操控插件。**一个批量工具**把「找控件 → 点击 → 输入 → 等条件 → 截图」
整串放进**一次引擎请求**里跑完，并且默认走**免聚焦**通道 —— agent 在这台机器上干活，
**不占用你正在用的桌面**。

![在 ChatGPT 桌面端连跑两轮：工具调用打字发送，离屏抓取回复](assets/screenshot-3-rounds.png)

## 它凭什么不一样

| | |
|---|---|
| **一次调用做完一件事** | `computer` 吃 `steps` 数组，整串在一次引擎请求里执行。五个动作 = **一轮模型请求**，不是五轮 —— 而每多一轮，整个对话上下文都要重发一次。 |
| **不抢你的操作** | 输入默认走 UIA 模式与 Win32 消息，**窗口不在前台也能生效**；截图走 `PrintWindow`，**被遮挡也能拍**。万不得已要物理输入时，操作结束会把前台窗口和光标位置**还回去**。 |
| **常驻引擎** | 后台引擎把 PowerShell/UIA 的初始化留热，`Add-Type` 只付一次：实测 **~800 ms/次（一次性进程）→ 40–100 ms/次（常驻）**。空闲（默认 10 分钟）自行退出；带**脚本内容指纹**，改了引擎下一次调用自动换新。 |
| **截图直接变图片** | 路由到的模型声明支持图像输入时，PNG 直接附在工具结果里 —— 省掉一次 `read_image` 往返。 |

## 两个工具

刻意只有两个：一个动作一个工具，等于每轮请求都要为那些 schema 付一遍 token。

| 工具 | 作用 |
|---|---|
| `computer` | 传 `steps: [{op, …}, …]`：`find` / `click` / `type` / `key` / `wait` / `shot` / `windows` / `uia` / `mouse` / `focus` / `clipboard` / `process` / `display` / `sleep`。步骤可以用 `as:"ref"` 引用前面找到的控件，**按控件点击，不必换算坐标**；`shot` 放最后一步会把图片直接返回。 |
| `computer_shot` | 只截图。给 `window`/`pid` 走 `PrintWindow` **离屏抓取、不激活窗口**；也支持 `region` / `display` / `scale`。 |

```jsonc
// 一次调用：新开会话 → 打字 → 发送 → 等回复 → 截图
{"steps": [
  {"op": "click", "window": "ChatGPT", "name": "新聊天"},
  {"op": "wait",  "window": "ChatGPT", "type": "Edit", "timeout_ms": 8000},
  {"op": "type",  "window": "ChatGPT", "type": "Edit", "text": "你好", "mode": "background"},
  {"op": "key",   "keys": "enter", "window": "ChatGPT"},
  {"op": "sleep", "ms": 7000},
  {"op": "shot",  "window": "ChatGPT"}
]}
```

## 后台优先的三层策略

`mode` 缺省 `"auto"`：先试免聚焦层，不成才退回物理输入。`mode:"background"` **做不到就报错**，
绝不偷偷接管你的屏幕；`mode:"physical"` 才真的抢焦点，而且**会还回去**。

| 动作 | 第 1 层（免聚焦） | 第 2 层（免聚焦，老控件） | 第 3 层（借桌面） |
|---|---|---|---|
| 点击 | UIA `Invoke` / `SelectionItem` / `Toggle` / `ExpandCollapse` | `BM_CLICK`、`WM_LBUTTONDOWN+UP` 直发控件 | `SetCursorPos` + `mouse_event` |
| 输入 | UIA `ValuePattern.SetValue` | `WM_SETTEXT`，**写后读回校验**才认成功 | `SendInput` 逐字符（任意 Unicode，含中文） |
| 按键 | —（组合键必须过 OS 输入队列，**没有诚实的后台形式**） | — | `keybd_event` |
| 截图 | 指定窗口时 `PrintWindow(PW_RENDERFULLCONTENT)` | — | `CopyFromScreen` |

后台层每次都要**自证**：`WM_SETTEXT` 写完会读回比对，不相等就不算成功。

## 环境要求

- **仅 Windows**（`apply()` 对 `process.platform` 有硬校验）。
- 引擎用 **Windows PowerShell 5.1**（`powershell.exe`）—— 它自带 `UIAutomationClient` 与
  `System.Drawing`，PowerShell 7 没有。
- dsh web `0.1.x`。

## 安装

```sh
dsh plugin --profile web add github:wwwort/dsh-win-computer-use
```

发布到 npm 后，`dsh plugin --profile web add dsh-win-computer-use` 也可用。

## 构建

`lib/` 是**预构建产物且已提交**，安装过程不会构建任何东西。要自己重建：

```bash
DSH_CHECKOUT=<dsh 源码 checkout> bash scripts/build.sh
node scripts/preflight.mjs        # 校验 dsh.bundle 清单与真实入包清单
```

## 实测（2026-09-19，2560×1600，Windows 11）

| 项 | 结果 |
|---|---|
| 一件事一次调用 | 8 步（启动应用 → 等窗口 → 找输入框 → 输入 → 点击 → 读回标签 → 截图）：**1 次调用、1.4 s** |
| 后台输入 | `uia.valuePattern` / `win32.wm_settext`，读回 `bg-typed 中文 OK`，**目标窗口全程不在前台**，前台始终是用户自己的窗口 |
| 后台点击 | `win32.bm_click`，应用自己的点击计数变成 1 |
| 离屏截图 | 被别的应用遮挡的窗口完整抓到（`source: "printwindow"`） |
| 冷/热调用 | ~800 ms（一次性进程）→ 42–104 ms（常驻引擎） |
| 改引擎 | 改 `win.ps1` 后下一次调用自动退休旧引擎并起新的；1 行日志，无重试风暴 |
| 上面的第 2、3 轮 | 追问引用了上一轮的回答 —— 同一个会话，全程由工具调用驱动 |

本仓库里的截图就是那次运行的真实抓取，**裁掉了无关的桌面内容**（侧栏、账号、用量等）。

## 已知边界

- **仅 Windows。**
- **`key` 没有后台实现** —— 要零打扰就用 `type`（写值）或 `click`（Invoke）。
- **老控件**（WinForms 等）在 UIA 下常常只暴露 `Pane`、无任何 Pattern，走 Win32 消息层；
  **Chromium 渲染区**不接受 `WM_SETTEXT`，浏览器页面只能靠 UIA `ValuePattern` 或物理输入。
- contenteditable 输入框可能接受了 `SetValue` 却仍报告占位符，因此 `type` 返回
  `verified: true|false` 加一句说明，而不是暗示一定成功。
- **人机并发**：「设坐标 → 点击」不是原子操作，指针没到位时引擎**拒绝点击**并报出指针真实位置。
- UIA 遍历在复杂窗口上可能数百毫秒；`uia` 会在 `max_nodes` 处截断并说明。
- 窗口标题是子串匹配，**零宽字符会让匹配失败** —— Edge 自己的标题里就有一个。
- `windows restore` 会激活窗口（`SW_RESTORE`）；最小化的窗口不恢复就没法有意义地抓取。

## 许可

BSD-3-Clause。
