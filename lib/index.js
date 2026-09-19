/**
 * @dsh-external/dsh-computer-use — give DSH the ability to drive this Windows box.
 *
 * Design rules, both learned the hard way:
 *
 * 1. ONE call must finish a whole task. Every extra tool call re-sends the whole
 *    conversation to the model, so a five-call sequence costs five prompts. The
 *    `computer` tool therefore takes a *list* of steps and runs them inside a
 *    single engine request: find the control, click it, type, wait for the next
 *    window, capture it -- one model turn, one round trip.
 *
 * 2. Do not occupy the user's desktop. The default mode runs everything in the
 *    background: UIA patterns and Win32 messages reach a window without
 *    focusing it, PrintWindow captures it without raising it. When something
 *    genuinely needs the pointer or a real keystroke (mode:"physical"), the
 *    previous foreground window and cursor position are restored immediately
 *    afterwards, so the desktop is borrowed, not taken.
 *
 * The engine lives in `scripts/win.ps1` (ASCII-only: Windows PowerShell 5.1
 * decodes BOM-less scripts as ANSI); `src/bridge.ts` owns its process and
 * transport. Everything here is schema, wording, and the tool bodies.
 */
import { readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { Engine } from './bridge.js';
export const name = 'dsh-win-computer-use';
export const inject = ['tools'];
const DEFAULTS = {
    powershell: 'powershell.exe',
    timeoutMs: 120000,
    idleMs: 600000,
    daemon: true,
};
/** Engine script: lib/index.js -> ../scripts/win.ps1. Resolved without
 *  `import.meta.dirname`, which only exists on Node 20.11+ — the packaged
 *  artifact owns this path, so it must not depend on a version detail. */
const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'win.ps1');
const MAX_BATCH_MS = 900000;
const MAX_SHOT_MS = 120000;
/**
 * Fields every step may carry, regardless of op. Op-specific fields
 * (action/x/y/keys/...) are allowed by `additionalProperties: true` and are
 * documented in the tool description instead of being repeated per op.
 */
const STEP_ITEM = {
    type: 'object',
    additionalProperties: true,
    properties: {
        op: {
            type: 'string',
            required: true,
            description: 'find|read|click|type|key|wait|shot|windows|uia|mouse|focus|clipboard|process|display|sleep',
        },
        label: { type: 'string', description: 'Free-text tag echoed back with this step result; use it to locate failures.' },
        optional: { type: 'boolean', description: 'true = a failure here does not stop the batch.' },
        window: { type: 'string', description: 'Target window: title substring (or process name) used both to scope an element search and to pick the window to act on.' },
        pid: { type: 'integer', description: 'Target window by process id (alternative to window).' },
        ref: { type: 'string', description: 'Handle to an element remembered by an earlier find step (`as`). Valid only inside the SAME call\'s steps — a ref does not survive into a later call; re-run `find` there.' },
        name: { type: 'string', description: 'Exact UI element name.' },
        name_contains: { type: 'string', description: 'UI element name substring.' },
        automation_id: { type: 'string', description: 'UI AutomationId (stable across languages/versions when available).' },
        class_name: { type: 'string', description: 'UI class name substring, e.g. RichEditD2DPT, WindowsForms10.EDIT, Chrome_RenderWidgetHostHWND.' },
        type: { type: 'string', description: 'UI control type: Button|Edit|Document|Text|MenuItem|ListItem|TabItem|CheckBox|ComboBox|TreeItem|Hyperlink|Pane...' },
        as: { type: 'string', description: 'find only: remember the matched element under this ref name.' },
        index: { type: 'integer', description: 'find only: pick the Nth match (default 0).' },
        max: { type: 'integer', description: 'find only: how many matches to return (default 10).' },
        text: { type: 'string', description: 'type only: the text to write (any Unicode, including Chinese).' },
        append: { type: 'boolean', description: 'type only: append instead of replacing the current value.' },
        keys: { type: 'string', description: 'key only: combo, e.g. "ctrl+s", "enter", "alt+F4".' },
        action: { type: 'string', description: 'windows: list|focus|minimize|maximize|restore|close|move. mouse: move|click|double_click|right_click|middle_click|drag|scroll. process: list|start|stop. clipboard: get|set.' },
        match: { type: 'string', description: 'windows action=list: filter by title substring or process name.' },
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'click only, default left.' },
        count: { type: 'integer', description: 'click only: click count (2 = double click).' },
        x: { type: 'integer', description: 'Screen x in physical pixels (click/windows move).' },
        y: { type: 'integer', description: 'Screen y in physical pixels (click/windows move).' },
        to_x: { type: 'integer', description: 'mouse drag target x.' },
        to_y: { type: 'integer', description: 'mouse drag target y.' },
        amount: { type: 'integer', description: 'mouse scroll: wheel notches, positive = up.' },
        mode: { type: 'string', enum: ['auto', 'background', 'physical'], description: 'auto (default): try background first, fall back to physical. background: never touch focus or pointer -- fail instead. physical: use the real pointer/keyboard.' },
        timeout_ms: { type: 'integer', description: 'wait: how long to keep polling (default 15000). batch-level: total budget (default 120000).' },
        stable_ms: { type: 'integer', description: 'wait only: the condition must hold this long before it counts (filters out windows that are still appearing).' },
        interval_ms: { type: 'integer', description: 'wait only: poll interval (default 250).' },
        ms: { type: 'integer', description: 'sleep only: milliseconds to wait.' },
        state: { type: 'string', enum: ['exists', 'gone', 'foreground', 'visible', 'text_stable'], description: 'wait only, default exists. text_stable = return once the window text stops changing (and return it as text) -- use it to wait for a reply instead of guessing a sleep.' },
        tail: { type: 'integer', description: 'read/wait only: return just the last N characters. The newest content of a chat, status line or log sits at the end of the document text.' },
        max_chars: { type: 'integer', description: 'read/wait only: hard cap on returned characters (default 4000, keeps the tail).' },
        from: { type: 'string', enum: ['tail', 'head'], description: 'read only: which end to keep when the text is truncated (default tail).' },
        process: { type: 'string', description: 'process name for wait (with state exists|gone) or a process step.' },
        filter: { type: 'string', description: 'process list / uia: substring filter.' },
        depth: { type: 'integer', description: 'uia only: max tree depth (default 8).' },
        max_nodes: { type: 'integer', description: 'uia only: max elements returned (default 250).' },
        region: { type: 'string', description: 'shot only: "x,y,w,h" in physical pixels.' },
        display: { type: 'integer', description: 'shot only: monitor index, 0-based.' },
        scale: { type: 'number', description: 'shot only: 0.1-1.0 downscale to save tokens.' },
        path: { type: 'string', description: 'shot only: write the PNG here.' },
        restore: { type: 'boolean', description: 'Physical input only: restore the previous foreground window and cursor afterwards (default true).' },
    },
};
/** Structured image value accepted by an image content block (mirrors read_image). */
const IMAGE_VALUE = {
    type: 'object',
    additionalProperties: false,
    properties: {
        attachmentId: { type: 'string', required: true },
        mediaType: { type: 'string', required: true, enum: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'] },
        bytes: { type: 'integer', required: true },
        width: { type: 'integer', required: true },
        height: { type: 'integer', required: true },
        name: { type: 'string' },
    },
};
/** Output contract of both tools: a JSON envelope plus, when possible, the image itself. */
const textWithOptionalImage = {
    schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
            text: { type: 'string', required: true },
            image: IMAGE_VALUE,
        },
    },
    render: (_args, value) => {
        // Rendered blocks are validated by the registry; the array is deliberately
        // loose here because the image block carries a branded attachment id.
        const blocks = [{ type: 'text', text: value.text }];
        if (value.image !== undefined)
            blocks.push({ type: 'image', attachment: value.image });
        return blocks;
    },
};
function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}
function readService(ctx, name) {
    const holder = ctx;
    if (typeof holder.get !== 'function')
        return undefined;
    try {
        return holder.get(name);
    }
    catch {
        return undefined;
    }
}
/**
 * Attach a PNG to the tool result so the model sees the picture without a
 * second `read_image` call. Only done when the routed model actually declares
 * image input -- sending an image block to a text-only route would break the
 * request, and a path is always a safe fallback.
 */
async function inlineImage(ctx, exec, pngPath) {
    try {
        const attachments = readService(ctx, 'attachments');
        const llm = readService(ctx, 'llm');
        if (attachments === undefined || llm === undefined)
            return undefined;
        const agent = exec.agent;
        const routed = agent?.session?.requestHeader?.()?.config;
        const provider = routed?.provider ?? agent?.options?.provider;
        const model = routed?.model ?? agent?.options?.model;
        if (provider === undefined || model === undefined)
            return undefined;
        const info = await llm.resolveModelInfo(provider, model, exec.signal);
        if (info?.inputModalities === undefined || !info.inputModalities.includes('image'))
            return undefined;
        const data = readFileSync(pngPath);
        const ref = await attachments.saveImage({ data, mediaType: 'image/png', name: basename(pngPath) });
        return {
            attachmentId: String(ref.attachmentId),
            mediaType: ref.mediaType,
            bytes: ref.bytes,
            width: ref.width,
            height: ref.height,
            ...(ref.name === undefined ? {} : { name: ref.name }),
        };
    }
    catch {
        // An inlined image is a bonus, never a requirement: any failure degrades to
        // the path-only answer instead of failing the call.
        return undefined;
    }
}
/** The last executed step's screenshot, when the batch ended on a shot. */
function trailingShot(result) {
    const results = result.results;
    if (!Array.isArray(results) || results.length === 0)
        return undefined;
    const last = results[results.length - 1];
    if (last?.op !== 'shot' || last.ok !== true)
        return undefined;
    return typeof last.path === 'string' ? last.path : undefined;
}
const STEPS_DESCRIPTION = [
    '顺序执行的步骤数组；每步 {op, ...}。默认遇错即停，失败步骤的下标在 failedStep，原因在该步的 error。',
    'op 一览（完整字段见各参数说明）：',
    '• find：定位控件（name/name_contains/automation_id/class_name/type + window/pid），as:"ref" 记住它；返回 hwnd、rect.cx/cy、enabled、patterns。',
    '• read：把窗口内容读成**文本**（UIA TextPattern → ValuePattern → 元素名兜底），配 tail 取最新的 N 个字符。取内容一律先想它，别截图。',
    '• click：给 ref（或直接给 name/class_name…）就能按控件点击，不必先换算坐标；也可给 x/y。',
    '• type：ref 或 name…，加 text。元素树里找不到输入框时（Chromium 常有），可用 mode:"physical" 走真实键盘。',
    '• key：keys:"ctrl+s"。"enter"、"alt+F4" 这类组合键只能走真实键盘。',
    '• wait：等条件成立（window/process/元素 + state；timeout_ms、stable_ms）。state:"text_stable" 表示**等文本不再变化**并把稳定后的文本返回 —— 等 AI 回复写完、等日志停止滚动就用它，别猜 sleep。',
    '• shot：截图。给 window 时走 PrintWindow 离屏抓取，不激活窗口、被遮挡也能拍。放在最后一步，图片会直接返回给你。看「长什么样」用它，取内容用 read。',
    '• windows：action=list|focus|minimize|maximize|restore|close|move。 • uia：元素树。',
    '• mouse：原始鼠标动作。 • clipboard / process / display / sleep。',
].join('\n');
const COMPUTER_DESCRIPTION = [
    '先做复杂度判断：① 不看屏幕就能把整个 steps 写全 → 就在这里一次调用跑完（主代理一轮 ≈56 万 token）；② 必须先读界面才知道下一步、或多阶段推进 → 派子代理去做（skill: computer-operator），并把整件事交给它、别自己先探一遍。子代理每轮 ≈2 万 token，差 28 倍，越复杂省得越多（3 轮省 61%，10 轮省 86%）。',
    '取内容一律优先 read（文本），不要截图：文本准确、可引用、一次调用拿到，窗口被遮挡也读得到；截图留给「看长什么样」。等 AI 回复写完用 wait state:"text_stable"，别猜 sleep。',
    '在一个调用里做完一整串电脑操作：找控件 → 点击 → 输入 → 等条件 → 截图验证。',
    '为什么不拆成多次调用：每多一次调用，整个对话上下文就要重发给模型一次，那才是最贵的开销。所以把整件事写成 steps 一次提交。',
    '',
    STEPS_DESCRIPTION,
    '',
    '不抢你的操作（默认）：mode 缺省为 "auto"，先试后台手段——UIA 模式（Invoke/Value/Select）与 Win32 消息（WM_SETTEXT/BM_CLICK）都能在窗口不在前台、鼠标不动的情况下生效；后台不成才退回物理操作。',
    'mode:"background" 表示严格后台：做不到就报错，绝不偷偷接管你的屏幕；mode:"physical" 才真的抢焦点。任何物理操作结束后，引擎会把前台窗口和光标位置恢复原状。',
    '每一步都可带 label（便于定位失败）和 optional:true（失败不中断后续步骤）。',
    '',
    '示例——在记事本里输入并另存（一次调用）:',
    'steps:[{"op":"process","action":"start","path":"notepad.exe"},{"op":"wait","window":"Notepad","timeout_ms":8000,"stable_ms":300},{"op":"type","window":"Notepad","class_name":"RichEditD2DPT","text":"hello"},{"op":"key","keys":"ctrl+s"},{"op":"wait","name":"文件名","window":"另存为","timeout_ms":8000},{"op":"shot","window":"另存为"}]',
].join('\n');
const SHOT_DESCRIPTION = [
    '截屏并直接把画面返回给你（能内联就内联，省掉一次 read_image 调用），同时给出 PNG 路径与尺寸。',
    '给 window/pid 时用 PrintWindow 离屏抓取：不激活该窗口、被遮挡也能拍。也可用 region:"x,y,w,h"、display=N、scale 缩小省 token。',
    '只想看某个窗口的小范围时，先 computer{op:"find"} 拿到元素矩形，再用 region 精确裁剪，比全屏截图省很多 token。',
].join('\n');
/**
 * The delegation protocol, shipped as a runtime skill rather than baked into the
 * tool description: a skill costs one catalog line until the model loads it,
 * while the same text in the description would be re-sent with every request.
 *
 * Every number here is measured, not asserted. Across the 194 subagent session
 * logs on the machine this was written on, a subagent carried 39k-140k tokens per
 * request; the top-level sessions carried 270k-440k. That difference is what makes
 * delegating an iterative task worth two extra parent turns.
 */
const OPERATOR_SKILL = {
    name: 'computer-operator',
    description: '把电脑操作派给子代理：判断该自己动手还是派人、给出自包含简报模板、约定返回契约，让屏幕读数不进主代理上下文。',
    whenToUse: '要用 computer 工具做多步操作、或需要看屏幕反复决定下一步时加载。',
    content: [
        '# computer-operator —— 把电脑操作派给子代理',
        '',
        '主代理**默认不要自己一步步操作**。主代理每多一轮请求，整个上下文就要重发一次（本机实测 18.5 万 ~ 44 万 token/轮）；',
        '子代理每轮只有 4 万上下（实测 194 个子代理会话：39k–140k）。而且子代理里读到的屏幕内容**不会污染主代理的注意力**。',
        '',
        '## 先判断：自己动手，还是派出去',
        '',
        '这不是感觉问题，是算出来的。同一台机器上做了两组对照实验，两边都用会话日志量了真实 token：',
        '',
        '- **能一次写全的任务**（主代理 1 轮）：自己做 522,925；派子代理 = 1 轮派发+等待(525,007) + 子代理 5 轮(99,092) = 624,099 —— **反而贵 19%**。',
        '- **冷启动的多轮任务**（主代理必须先读界面才知道下一步填什么）：自己做 **3 轮 = 1,682,263**；派子代理 = 1 轮(565,459) + 子代理 5 轮(98,535) = **663,994 —— 省 61%**。',
        '',
        '两个常数（实测）：**主代理 ≈ 56 万 token/轮**，**子代理 ≈ 2 万 token/轮**。差 28 倍，这就是全部收益的来源。',
        '主代理本来要 N 轮时（子代理的轮数 K 一般 ≈ N+2）：',
        '',
        '| 主代理本来的轮数 N | 自己做 | 派子代理 | 结果 |',
        '|---|---|---|---|',
        '| 1 | 0.56M | 0.66M | 自己做省 15% |',
        '| 2 | 1.12M | 0.64M | 派出去省 43% |',
        '| 3 | 1.68M | 0.66M | **省 61%（实测）** |',
        '| 5 | 2.80M | 0.70M | 省 75% |',
        '| 10 | 5.60M | 0.80M | 省 86% |',
        '| 20 | 11.2M | 0.99M | 省 91% |',
        '',
        '**越复杂省得越多，上限约 96%** —— 因为子代理那一侧几乎不随复杂度增长，而主代理那一侧是线性涨的。',
        '',
        '## 路由：先做复杂度判断，再一次派完',
        '',
        '1. **不看屏幕就能把整个 `steps` 写全？**（例如「打开 X → 在 Y 输入 Z → 点确定 → 截图确认」）→ **自己做，一次调用**。派子代理更贵。',
        '2. **否则** —— 必须先读界面才知道下一步做什么、或者要多阶段推进 → **派子代理**，而且**把整件事交给它，别自己先探一遍**。',
        '   自己先探一遍等于把探索成本又付了一次，而且付在主代理那侧（贵 28 倍）。',
        '',
        '前提是用 `subagent` 时设 `run_in_background: false` —— 这样「派发 + 等结果」算**同一轮**，主上下文在子代理干活期间不重发。',
        '若用后台派发（`true`），收结果时还要一轮，门槛就抬到 N ≥ 3。',
        '',
        '## 复用同一个子代理：能，但别指望它省 token',
        '',
        '后台派发的子代理是 durable 的，可以 `send_message` 接着下指令（实测：同一个子代理连做两个任务都成功）。',
        '而且它不会被复用撑大 —— 实测两轮任务下来每轮上下文只从 18,496 涨到 21,554（+17%），两个任务合计 120,803 token。',
        '',
        '**但复用省不出钱来**：后台派发要为每个结果各多付父代理一轮，而父代理一轮 ≈ 52 万 token ——',
        '是那两个任务全部子代理开销的 14 倍。复用的真正价值是别的：它积累了这台机器的界面知识、而父上下文不必再吸收一份新简报。',
        '**要省轮次还是要可复用，只能二选一。**',
        '',
        '## 取内容：用 read，不要截图',
        '',
        '和 AI 讨论、读日志、看状态 —— 这些内容是**文本**，而文本本来就在 UIA 里。截图是下策：一张图一次读、抓不到准确文字、会随用户切窗口抓错窗口，而且没法引用。',
        '',
        '- `{"op":"read","window":"X","tail":2000}` —— 拿最新的 2000 字符。页面阅读顺序里**新内容在尾部**，侧栏之类的噪音在开头，所以 tail 读法天然干净。',
        '- `{"op":"read","window":"X","tail":5000,"max_chars":5000}` 读整轮长回复；实测 ChatGPT 一轮约 2,200 字符 ≈ 600 token，而截图是一张图。',
        '- 读**单个控件**（表单、状态栏）：给 `name`/`ref`，或对 WinForms 之类用 `region`。',
        '- ⚠️ Chromium/Electron 的**元素树会塌**：实测 ChatGPT 窗口的控件树只剩 13 个节点（标题栏按钮 + 空 Pane），网页内容全部消失 —— 但同一时刻 `read` 仍能拿到 25,722 字符的页面文本。**所以在浏览器类应用里，read 比 find 可靠**；find 返回 0 命中不一定是"没有"，可能只是树被 Chromium 收起来了。',
        '',
        '## 等回复：wait state:"text_stable"，别猜 sleep',
        '',
        '```jsonc',
        '{"op":"wait","window":"ChatGPT","state":"text_stable","stable_ms":2500,"timeout_ms":90000,"tail":2000}',
        '```',
        '它轮询窗口文本，连续 `stable_ms` 毫秒不再变化就认为写完了，并把稳定后的文本直接返回。',
        '猜 sleep 要么太短（读到半截）要么太长（每次都白等）；实测这个等待在静态页面上 4 次轮询、2.6 秒返回。',
        '',
        '## 聊天/讨论循环配方（一轮一条调用）',
        '',
        '```jsonc',
        '// 写：元素树里找不到输入框时，走真实键盘（Chromium 常见）',
        '{"steps":[',
        '  {"op":"focus","window":"ChatGPT"},',
        '  {"op":"type","window":"ChatGPT","mode":"physical","text":"<你的问题>"},',
        '  {"op":"key","keys":"enter","window":"ChatGPT"},',
        '  {"op":"wait","window":"ChatGPT","state":"text_stable","stable_ms":2500,"timeout_ms":90000,"tail":2500}',
        ']}',
        '```',
        '',
        '两条实测教训，能省你一轮：',
        '1. **contenteditable 的文本是懒更新的**：写完立刻 `read` 可能读回**旧值**（我因此误判过一次"输入失败"，其实成功了）。要么隔一会儿再读，要么用 `wait state:"text_stable"` 等它稳定。',
        '2. `focus` 只把窗口带到前台，**不一定把键盘焦点给输入框**；多数聊天应用在窗口激活后输入框是活的，但如果不灵，就先点一下输入框（`click` 给坐标）再打字。',
        '',
        '',
        '## 派发简报模板（子代理看不到你的上下文，必须自包含）',
        '',
        '下面六项填满再发。缺一项子代理就会自己猜，猜错就是白烧一轮：',
        '',
        '1. **目标状态**：一句话说清最终要让什么成立（不是「点某个按钮」，而是「让 X 窗口出现」「让输入框内容变成 Y」）。',
        '2. **目标程序**：窗口标题子串 / 进程名 / pid；程序没开就写明可执行文件路径。',
        '3. **已知定位信息**：你此前 find 到的控件名、automation_id、class_name —— 有就给，能替子代理省掉一轮 find。',
        '4. **成功判据**：子代理用什么**可观测**证据自证（「读回标签等于 X」「窗口标题含 Y」），以及不成立时不要瞎试。',
        '5. **边界**：不许碰的窗口/进程；要不要抢前台（默认不要，让它用 `mode:"background"`）。',
        '6. **返回什么**：只要结论 + 关键读数（几行字）。**除非主代理明确要看，不要回传整张截图或整棵 UIA 树** —— 那等于把体积搬回主上下文。',
        '',
        '## 子代理的返回契约（也写进简报里）',
        '',
        '- 成功：`结果 + 用的哪条通道(strategy) + 自证读数`，3~6 行。',
        '- 失败：`卡在哪一步 + 错误原文 + 已排除的可能`；不要把整棵树贴回来。',
        '- 只有主代理明确要「看」的时候才回传图片。',
        '',
        '## 为什么不让主代理直接看屏幕',
        '',
        '主代理上下文里多进去的每一个 token，**之后每一轮都要重发一次**。一次 UIA 树导出或截图 JSON 就是几万 token 常驻；',
        '按一个长会话几百轮算，一次污染要乘上百倍。子代理是隔离这些读数的正确位置 —— 它还可以把结论压缩成几行再交回主代理。',
    ].join('\n'),
};
/** Register the delegation skill when a skills service is mounted. Optional on
 *  purpose: the tools must work on a host without one. */
function registerOperatorSkill(ctx) {
    const api = ctx;
    const attach = (skills) => {
        const service = skills;
        if (service === undefined || typeof service.register !== 'function')
            return;
        try {
            // register() returns the context-owned disposer, so unload removes it.
            service.register({
                name: OPERATOR_SKILL.name,
                description: OPERATOR_SKILL.description,
                whenToUse: OPERATOR_SKILL.whenToUse,
                source: 'runtime',
                content: OPERATOR_SKILL.content,
            });
        }
        catch {
            // A skill is an optimisation for the caller, never a reason to fail a load.
        }
    };
    if (typeof api.inject === 'function') {
        api.inject(['skills'], (scoped) => attach(scoped.skills));
        return;
    }
    attach(api.get?.('skills'));
}
/** Register the two model-facing tools. */
export function apply(ctx, userConfig = {}) {
    const config = { ...DEFAULTS, ...userConfig };
    registerOperatorSkill(ctx);
    const daemon = config.daemon !== false;
    const engine = new Engine({
        script: SCRIPT,
        powershell: config.powershell,
        timeoutMs: config.timeoutMs,
        idleMs: config.idleMs,
        daemon,
        log: () => { },
    });
    ctx.effect(() => ctx.tools.register(defineTool({
        name: 'computer',
        description: COMPUTER_DESCRIPTION,
        parameters: {
            steps: { type: 'array', items: STEP_ITEM, required: true, description: '要顺序执行的步骤；整串在一次调用里跑完。' },
            on_error: { type: 'string', enum: ['stop', 'continue'], description: '某步失败后的行为：stop（默认）停止批次，continue 继续跑后续步骤。' },
            timeout_ms: { type: 'integer', description: '整批的总预算（毫秒），默认 120000。' },
        },
        output: textWithOptionalImage,
        isConcurrencySafe: () => false,
        async execute(args, exec) {
            const steps = Array.isArray(args.steps) ? args.steps : [];
            if (steps.length === 0)
                throw new Error('steps must be a non-empty array of step objects, e.g. [{"op":"windows","action":"list"}]');
            const budget = clamp(Number(args.timeout_ms ?? config.timeoutMs), 1000, MAX_BATCH_MS);
            const result = await engine.call('batch', {
                steps,
                on_error: args.on_error === 'continue' ? 'continue' : 'stop',
                timeout_ms: budget,
            }, budget + 20000, exec.signal);
            const text = JSON.stringify(result);
            const shot = trailingShot(result);
            if (shot === undefined)
                return { text };
            const image = await inlineImage(ctx, exec, shot);
            return image === undefined ? { text } : { text, image };
        },
    })), '@dsh-external/dsh-computer-use: computer');
    ctx.effect(() => ctx.tools.register(defineTool({
        name: 'computer_shot',
        description: SHOT_DESCRIPTION,
        parameters: {
            window: { type: 'string', description: '窗口标题子串；离屏抓取，不激活窗口。' },
            pid: { type: 'integer', description: '按进程 id 指定窗口。' },
            region: { type: 'string', description: '只截该区域 "x,y,w,h"（物理像素）。' },
            display: { type: 'integer', description: '显示器序号，从 0 开始；缺省为整个虚拟桌面。' },
            scale: { type: 'number', description: '缩放 0.1–1.0，用于省 token。' },
            path: { type: 'string', description: '自定义输出 PNG 路径。' },
        },
        output: textWithOptionalImage,
        isConcurrencySafe: () => false,
        async execute(args, exec) {
            const result = await engine.call('screenshot', { ...args }, MAX_SHOT_MS, exec.signal);
            if (result.ok !== true)
                throw new Error(result.error ?? 'screenshot failed');
            const text = JSON.stringify(result);
            const path = typeof result.path === 'string' ? result.path : undefined;
            if (path === undefined)
                return { text };
            const image = await inlineImage(ctx, exec, path);
            return image === undefined ? { text } : { text, image };
        },
    })), '@dsh-external/dsh-computer-use: computer_shot');
}
//# sourceMappingURL=index.js.map