# @dsh-external/dsh-computer-use —— DSH 的电脑操控能力

> 状态：✅ 已交付 · 已注入实测（2026-09-19 后台化 + 批量执行改造）
> 补记：脚手架 `dev_scaffold_plugin` 生成时**没写状态段**，而 `doc-guard.mjs` 的 C1 要求编号目录下每份
> `.md` 前 10 行内有 `> 状态：…`；本文件此前被外部改动补过一行状态段（批注自称 2026-09-25），
> 现随正式 README 一并重写，正文为本插件实况。

让 DSH 拥有与 Codex Computer Use 对等的电脑操控：**看屏幕、点控件、打字、管窗口与进程**，
并让这些动作**不占用用户桌面**、**一次调用做完一整串**。

## 两条改造目标（2026-09-19）

| 目标 | 手段 | 实测 |
|---|---|---|
| **不占用户操作**（后台运行） | 默认走**免聚焦通道**：UIA 模式 + Win32 消息直发给控件；窗口截图走 `PrintWindow` 离屏抓取；物理操作结束后自动**把前台窗口和光标位置还回去** | 目标窗口不在前台时输入/点击全部生效（见下「实测证据」） |
| **不要多次调用模型**（省 token） | 九个工具合成 **2 个**；`computer` 吃 `steps: [...]` 把「找控件 → 点 → 输入 → 等条件 → 截图」在**一次工具调用**里跑完；截图可**内联返回图片**，省掉一次 `read_image` 往返 | 8 步任务：**1 次调用 1.4 s**（改为逐次调用约 9 次请求 + 约 7 s） |

## 两个工具

| 工具 | 干什么 |
|---|---|
| `computer` | **主力**。`steps:[{op,...}, ...]` 顺序执行，一次调用跑完整串。op：`find` `click` `type` `key` `wait` `shot` `windows` `uia` `mouse` `focus` `clipboard` `process` `display` `sleep`。`shot` 放最后一步时**图片直接内联返回**。 |
| `computer_shot` | 只想看一眼时用：给 `window`/`pid` 走 `PrintWindow` 离屏抓取（**不激活窗口、被遮挡也能拍**），也支持 `region` / `display` / `scale`；能内联就直接把画面返回。 |

旧工具名（`computer_display` / `computer_windows` / `computer_uia` / `computer_mouse` /
`computer_keyboard` / `computer_clipboard` / `computer_process`）**已下线**，对应的能力就是上表里的同名 op —— 
每个 op 都能当 `steps` 里的一步单独用，schema 从 9 份降到 2 份，每轮请求都省一段前缀 token。

## 后台优先的三层策略

`mode` 缺省 `"auto"`：**先试后台手段，后台不成才退回物理操作**；`mode:"background"` 是**严格后台**，
做不到就报错，**绝不偷偷接管你的屏幕**；`mode:"physical"` 才真的抢焦点。

| 动作 | 第 1 层（首选，免聚焦） | 第 2 层（免聚焦，老控件） | 第 3 层（物理，会借桌面） |
|---|---|---|---|
| 点击 | UIA `InvokePattern` → `SelectionItemPattern` → `TogglePattern` → `ExpandCollapsePattern` | `BM_CLICK` / `WM_LBUTTONDOWN+UP` 直发控件句柄 | `SetCursorPos` + `mouse_event` |
| 输入 | UIA `ValuePattern.SetValue` | `WM_SETTEXT`（写后**读回校验**） | `SendInput` 逐字符（支持中文/任意 Unicode） |
| 按键 | —（组合键必须过 OS 输入队列，**无后台实现**，报错不静默降级） | — | `keybd_event` |
| 截图 | 有窗口时 `PrintWindow(PW_RENDERFULLCONTENT)` | — | 无窗口时 `CopyFromScreen` |

后台层每次都要**自证**：Win32 写文本后读回比对，不相等就判失败并降级；UIA 与 Win32 都做不到时，
`mode:"background"` 直接报错并提示「改用 `mode:'physical'`（会短暂占用指针与前台）」。

## 常驻引擎（为什么快）

`scripts/win.ps1` 有两条通道，同一张 dispatch 表：

- **daemon**：`powershell.exe -Action serve` 在 `127.0.0.1` 上监听（端口写进 port 文件），
  `Add-Type` / 程序集加载**只付一次**。实测：一次性调用 **~800 ms/次** → 守护进程 **40–100 ms/次**。
  空闲 `idleMs`（默认 10 分钟）后**自行退出**，不留常驻进程；被热重载后由新实例**复用**（不必重付启动成本）。
- **one-shot**：daemon 起不来时的回退（沙箱拒绝 spawn、脚本缺失），同一批 `steps` 仍是一批，只是慢。

**脚本指纹（改引擎不用手工杀进程）**：daemon 启动时算一次 `win.ps1` 的 **SHA-256**，在 `ping` 里回报；
客户端每次取用 daemon 前先用 `stat()` 做廉价比对，只有文件真变了才 `ping` 核对指纹，**不一致就退休旧 daemon 并重起**。
所以改完 `win.ps1`，**下一次工具调用即生效**（代价是一次 ~800 ms 重起），不会出现"暖 daemon 一直跑旧代码"。
> 踩过的坑：指纹最初用 `LastWriteTimeUtc` 减 `[datetime]'1970-01-01T00:00:00Z'` —— PowerShell 会把那个
> 字面量按**本地时区**解释，于是两端差整整 8 小时，**每个 daemon 都被判为陈旧**，进而疯狂重起并在 20 s 后
> 回退到 one-shot。改用**内容哈希**后此类漂移不可能发生。

两条纪律：**任何时候都不走管道**（受限沙箱下 Node 的 piped stdio 会 EPERM，且中文过命令行会被 PS 5.1 的
ANSI 解码搞坏，参数与结果都走 UTF-8 文件 / loopback TCP）；**卡死的 daemon 直接杀掉**——
它单线程，一次卡住的 UIA 调用会挡住后续所有请求，所以读超时即按 `ping` 报回的 pid 杀进程，
让下一次调用重起一个干净的（**已被写出的请求绝不自动重试**：点击不是幂等操作）。

## 实测证据（2026-09-19）

| 项 | 结果 |
|---|---|
| 后台输入（受控 WinForms 靶窗，**全程不在前台**） | `type` 走 `win32.wm_settext`、`click` 走 `win32.bm_click`；靶窗标签读回 `clicks=1 typed=bg-typed 中文 OK`，且**期间前台窗口始终是用户的 Edge** |
| 离屏截图 | 被 Edge 遮挡的 ChatGPT 窗口 `PrintWindow` 抓取成功（`source:"printwindow"`），内容完整可见（含中文） |
| 内联返回 | `computer_shot` / `computer` 尾步 `shot` 的图片**直接出现在工具结果里**，无需再调 `read_image` |
| 一次调用跑完整串 | 8 步（启动应用 → 等待窗口 → 交还前台 → 找输入框 → 后台输入 → 后台点击 → 读回标签 → 截图）：**1 次调用、1.4 s、全绿** |
| 守护进程 | 启动 ~816 ms（一次性）；`ping`/`display` 42–104 ms/次；空闲 4 s 的实例在 8 s 时**自行退出** |
| 脚本指纹自愈 | 拷贝一份引擎→冷启 816 ms；复用 104 ms（同一 daemon）；**改内容后下一次调用自动换新 daemon**（817 ms，仅 1 行日志，无重试风暴）；再复用 42 ms |
| `mode:"background"` 严格性 | `{op:"key", mode:"background"}` 明确报错（无后台实现），**不静默改成抢焦点** |
| 元素定位 | UIA 全树可用：Edge/Chromium 的按钮带中文名与 `AutomationId`（`view_7`），WinForms 老控件按 `class_name` 定位并经句柄操作 |

## 构建与注入

```bash
# 本机 checkout 是未编译的源码树，dsh-tools 的 junction 必须指向**已编译**副本（见 build.sh 的 link_pkg_built）
DSH_CHECKOUT=D:\deepseek-harness bash scripts/build.sh
# 本机 bash 不在 PATH，用 Git 自带的：
#   "C:\Program Files\Git\bin\bash.exe" scripts/build.sh
```

注入/热重载走 DSH 注入器：`dev_inject_plugin` / `dev_reload_package`。
`win.ps1` 是运行时读取的，**改它不需要重新编译**（指纹机制会让下一次调用换用新代码）。

> ⚠️ 已知环境坑：`dev_build_plugin` 在本机**找不到 checkout**（它只探测 `$HOME/dsh-harness`、`$HOME/dsh`、
> `$HOME/.dsh/dsh-harness`，而本机是 `D:\deepseek-harness`），且它 `spawnSync('bash', ...)`，而 bash 不在
> DSH 进程的 PATH 里 —— 两个原因叠加，导致它必然报 `未找到 DSH checkout`。上面那两行命令是可用的替代路径
> （注入器本体在 `~/.dsh/profiles/web/node_modules/@dsh-external/dsh-super-injector/lib/index.js`，
> 探测逻辑在 9206–9217 行、构建入口在 9358–9390 行）。

## 已知边界

- **只支持 Windows**（`apply` 内对 `process.platform` 有硬校验）。
- **`key` 没有后台实现**：组合键必须过 OS 输入队列；要零打扰就用 `type`（写值）或 `click`（Invoke）。
  走物理路径时会短暂借用前台，结束后自动还原。
- 老控件（WinForms 等）在 UIA 下常常只暴露 `Pane` 且**无任何 Pattern**，此时靠第 2 层句柄消息；
  但 Chromium 渲染区之类的句柄**不接受** `WM_SETTEXT`，此时只有 UIA `ValuePattern` 或物理输入两条路。
- **人机并发**：「设坐标 → 点击」不是原子操作，指针被别的东西抢走时会**拒绝点击**（而不是点错地方），
  失败信息里给出指针当时的真实位置。
- UIA 遍历在复杂窗口上可能数百毫秒；`uia` 有 `max_nodes` 截断（`truncated: true` 表示被截）。
- 窗口标题匹配是子串匹配，**全角/零宽字符会让匹配失败**（本机 Edge 标题里就有一个零宽字符，
  `"Microsoft Edge"` 匹配不上，得换成页面标题里的别的片段）。
- 全屏独占类窗口可能拒绝被抢前台，此时 `focus` 直接报错（**设计如此**，不静默降级）。

## 安全提示

本插件等于把键鼠与进程控制权交给模型。`process stop` 与 `windows close` 尤其危险 ——
让 agent 用之之前先把靶子窗口准备好。
