# dsh-computer-use engine (Windows).
#
# ASCII-ONLY ON PURPOSE: Windows PowerShell 5.1 decodes BOM-less scripts as ANSI,
# so a single non-ASCII byte here (e.g. a Chinese comment) is mangled and can
# swallow line breaks. Non-ASCII only ever travels through the UTF-8 JSON
# argument file in and the UTF-8 result out.
#
# Two transports, one dispatch:
#   one-shot : powershell -File win.ps1 -Action <name> -ArgsJsonFile in.json -OutFile out.json
#   daemon   : powershell -File win.ps1 -Action serve -PortFile port.txt -IdleMs <ms>
#              then one JSON request line per TCP connection on 127.0.0.1:<port>.
# The daemon exists for two reasons: Add-Type + assembly load costs ~0.8s per
# cold start (paid once instead of once per action), and a batch can only be one
# model round trip if many actions run inside a single engine call.
#
# Every action returns a plain object; the caller serializes it. Nothing here
# writes to stdout (the sandbox forbids piped stdio), everything is files/sockets.

param(
  [string]$Action = '',
  [string]$ArgsJsonFile = '',
  [string]$OutFile = '',
  [string]$PortFile = '',
  [int]$Port = 0,
  [int]$IdleMs = 600000
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Fingerprint of the code this process is actually running. A daemon loads the
# script once, so editing win.ps1 would otherwise leave a warm daemon serving
# stale code forever. `ping` reports this, the client compares it with the file
# on disk, and a mismatch makes the client retire this daemon and start a fresh
# one -- self-healing, no manual kill, no "why is my fix not taking effect".
#
# It is a CONTENT hash, not a timestamp: an earlier timestamp version subtracted
# a [datetime] literal that PowerShell converts to local time from
# LastWriteTimeUtc, so the two sides differed by the UTC offset and every daemon
# looked stale forever. Bytes cannot drift like that.
$script:ScriptStamp = ''
try {
  $self = $PSCommandPath
  if (-not $self) { $self = $MyInvocation.MyCommand.Path }
  $script:ScriptStamp = (Get-FileHash -LiteralPath $self -Algorithm SHA256).Hash.ToLowerInvariant()
} catch { $script:ScriptStamp = '' }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ---------------------------------------------------------------- native layer

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class N {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int nMaxCount);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);
  [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr hWnd);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

  /// Real top-level enumeration: Process.MainWindowHandle is 0 for console
  /// windows (cmd / pwsh / WindowsTerminal), and terminals are exactly what an
  /// agent needs most.
  private static List<IntPtr> _wins;
  private static bool CollectWindow(IntPtr h, IntPtr l) { _wins.Add(h); return true; }
  public static IntPtr[] TopLevelWindows() {
    _wins = new List<IntPtr>();
    EnumWindows(new EnumWindowsProc(CollectWindow), IntPtr.Zero);
    return _wins.ToArray();
  }
  public static IntPtr[] ChildWindows(IntPtr parent) {
    _wins = new List<IntPtr>();
    EnumChildWindows(parent, new EnumWindowsProc(CollectWindow), IntPtr.Zero);
    return _wins.ToArray();
  }
  public static string Title(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
  public static string Cls(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetClassName(h, sb, sb.Capacity); return sb.ToString(); }

  /// Force a window to the foreground and report whether it really got there.
  /// SetForegroundWindow alone is unreliable: Windows refuses foreground changes
  /// from a process that does not own the current foreground window, so a
  /// separate "focus" call can silently do nothing and the next call then types
  /// into whatever was focused. AttachThreadInput defeats that restriction.
  public static bool ForceForeground(IntPtr h) {
    if (h == IntPtr.Zero) return false;
    if (GetForegroundWindow() == h) return true;
    if (IsIconic(h)) ShowWindow(h, 9);
    uint cur = GetCurrentThreadId();
    uint fgPid = 0;
    uint targetPid = 0;
    uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint targetThread = GetWindowThreadProcessId(h, out targetPid);
    bool attachedFg = false;
    bool attachedTarget = false;
    if (fgThread != 0 && fgThread != cur) attachedFg = AttachThreadInput(cur, fgThread, true);
    if (targetThread != 0 && targetThread != cur && targetThread != fgThread) attachedTarget = AttachThreadInput(cur, targetThread, true);
    bool ok = SetForegroundWindow(h);
    if (attachedTarget) AttachThreadInput(cur, targetThread, false);
    if (attachedFg) AttachThreadInput(cur, fgThread, false);
    return ok;
  }

  public static void SendVk(ushort vk, bool up) {
    int size = Marshal.SizeOf(typeof(INPUT));
    INPUT[] one = new INPUT[1];
    one[0].type = 1; one[0].u.ki.wVk = vk; one[0].u.ki.wScan = 0;
    one[0].u.ki.dwFlags = up ? (uint)0x0002 : 0u;
    SendInput(1, one, size);
  }
  public static void TypeUnicode(string text) {
    int size = Marshal.SizeOf(typeof(INPUT));
    foreach (char c in text) {
      char ch = c;
      if (ch == '\n') { SendVk(0x0D, false); SendVk(0x0D, true); continue; }
      if (ch == '\t') { SendVk(0x09, false); SendVk(0x09, true); continue; }
      if (ch == '\r') { continue; }
      INPUT[] down = new INPUT[1];
      down[0].type = 1; down[0].u.ki.wVk = 0; down[0].u.ki.wScan = (ushort)ch; down[0].u.ki.dwFlags = 0x0004;
      INPUT[] up = new INPUT[1];
      up[0].type = 1; up[0].u.ki.wVk = 0; up[0].u.ki.wScan = (ushort)ch; up[0].u.ki.dwFlags = 0x0004 | 0x0002;
      SendInput(1, down, size);
      SendInput(1, up, size);
    }
  }
  /// Classic child-control text read. GetWindowText cannot read a control that
  /// lives in another process; WM_GETTEXT can.
  public static string ControlText(IntPtr h) {
    StringBuilder sb = new StringBuilder(4096);
    SendMessage(h, 0x000D, (IntPtr)4096, sb);
    return sb.ToString();
  }
}
'@

[void][N]::SetProcessDPIAware()

$MOUSEEVENTF = @{ leftdown = 0x0002; leftup = 0x0004; rightdown = 0x0008; rightup = 0x0010; middledown = 0x0020; middleup = 0x0040; wheel = 0x0800; hwheel = 0x1000 }
$script:ProcNameCache = @{}

# ---------------------------------------------------------------- json helpers

function To-JsonText($obj) { return (ConvertTo-Json -InputObject $obj -Depth 14 -Compress) }

function Write-Utf8File([string]$path, [string]$text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-Arg($obj, [string]$name, $default) {
  if ($null -eq $obj) { return $default }
  if ($obj -is [System.Collections.IDictionary]) {
    if ($obj.Contains($name)) { $v = $obj[$name]; if ($null -ne $v) { return $v } }
    return $default
  }
  if (@($obj.PSObject.Properties.Name) -contains $name) {
    $v = $obj.$name
    if ($null -ne $v) { return $v }
  }
  return $default
}

function Safe-Int($v) {
  try {
    $d = [double]$v
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 0 }
    return [int]$d
  } catch { return 0 }
}

# ------------------------------------------------------------------- geometry

function Get-ProcName([int]$procId) {
  if ($script:ProcNameCache.ContainsKey($procId)) { return $script:ProcNameCache[$procId] }
  $n = 'unknown'
  try { $n = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $n = 'unknown' }
  $script:ProcNameCache[$procId] = $n
  return $n
}

function Get-WindowInfo([IntPtr]$h) {
  $r = New-Object N+RECT
  [void][N]::GetWindowRect($h, [ref]$r)
  $procId = 0
  [void][N]::GetWindowThreadProcessId($h, [ref]$procId)
  return [ordered]@{
    handle    = [int64]$h
    title     = [N]::Title($h)
    cls       = [N]::Cls($h)
    pid       = [int]$procId
    process   = (Get-ProcName ([int]$procId))
    rect      = [ordered]@{ x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top) }
    minimized = [bool][N]::IsIconic($h)
    maximized = [bool][N]::IsZoomed($h)
    visible   = [bool][N]::IsWindowVisible($h)
  }
}

function Get-TopWindows($filter, $wantPid) {
  $out = @()
  foreach ($h in [N]::TopLevelWindows()) {
    if (-not [N]::IsWindowVisible($h)) { continue }
    $ex = [N]::GetWindowLong($h, -20)
    $owner = [N]::GetWindow($h, 4)
    # Skip tool windows and owned popups: not what a user calls a "window", and
    # they would drown the useful entries.
    $isAppWindow = ($ex -band 0x00040000) -ne 0
    if (($ex -band 0x00000080) -ne 0 -and -not $isAppWindow) { continue }
    if ($owner -ne [IntPtr]::Zero -and -not $isAppWindow) { continue }
    $info = Get-WindowInfo $h
    if (-not $info.title) { continue }
    if ($wantPid -and $info.pid -ne [int]$wantPid) { continue }
    if ($filter -and ($info.title -notlike "*$filter*") -and ($info.process -notlike "*$filter*")) { continue }
    $out += $info
  }
  return $out
}

# @() forces an array: with exactly one match Get-TopWindows degrades to a
# single ordered dictionary, and dictionary [0] looks up KEY 0 (returns $null)
# rather than the first element.
function Resolve-TargetWindow($match, $wantPid) {
  if ($wantPid) {
    $p = Get-Process -Id ([int]$wantPid) -ErrorAction Stop
    if ($p.MainWindowHandle -ne 0) { return [IntPtr][int64]$p.MainWindowHandle }
    $hit = @(Get-TopWindows '' $wantPid)
    if ($hit.Count -gt 0) { return [IntPtr][int64]$hit[0].handle }
    throw "process $wantPid has no visible window"
  }
  if (-not $match) { return [N]::GetForegroundWindow() }
  $cands = @(Get-TopWindows $match $null)
  if ($cands.Count -eq 0) { throw "no visible window matching '$match'" }
  # Rank matches: exact title first, then title prefix, then whatever substring
  # match is left. Without this, "ChatGPT" can hit a BROWSER window whose page
  # title merely contains "chatgpt" -- and the agent then drives the wrong app.
  $exact = @($cands | Where-Object { $_.title -eq $match })
  if ($exact.Count -gt 0) { return [IntPtr][int64]$exact[0].handle }
  $prefix = @($cands | Where-Object { $_.title -like "$match*" })
  if ($prefix.Count -gt 0) { return [IntPtr][int64]$prefix[0].handle }
  return [IntPtr][int64]$cands[0].handle
}

# Always returns an IntPtr (Zero when there is no such window). Returning $null
# here would break every "-ne [IntPtr]::Zero" test downstream, because $null is
# not equal to a value type.
function Get-OptionalWindow($match, $wantPid) {
  try {
    $h = Resolve-TargetWindow $match $wantPid
    if ($null -eq $h) { return [IntPtr]::Zero }
    return [IntPtr]$h
  } catch { return [IntPtr]::Zero }
}

# Bring a target window to the foreground and PROVE it got there, or throw.
# Typing into "whatever happens to be focused" is how an agent sends text to the
# wrong application; fail closed instead.
function Focus-Target($match, $wantPid) {
  $t = Resolve-TargetWindow $match $wantPid
  if ($t -eq [IntPtr]::Zero) { throw 'could not resolve a target window' }
  [void][N]::ForceForeground($t)
  for ($i = 0; $i -lt 24; $i++) {
    if ([N]::GetForegroundWindow() -eq $t) { return $t }
    Start-Sleep -Milliseconds 50
  }
  throw ("refusing to act: could not bring the target window to the foreground (handle " + [int64]$t + ")")
}

function Get-HwndAtPoint([int]$x, [int]$y, [IntPtr]$expectedRoot) {
  $pt = New-Object N+POINT
  $pt.X = $x; $pt.Y = $y
  $h = [N]::WindowFromPoint($pt)
  if ($h -eq [IntPtr]::Zero) { return [IntPtr]$expectedRoot }
  if ($expectedRoot -ne [IntPtr]::Zero) {
    $root = [N]::GetAncestor($h, 2)
    if ($root -ne $expectedRoot) { return [IntPtr]$expectedRoot }
  }
  return $h
}

# ------------------------------------------------------------- pointer restore

function Save-Pointer {
  $p = New-Object N+POINT
  [void][N]::GetCursorPos([ref]$p)
  return @{ x = $p.X; y = $p.Y; fg = [N]::GetForegroundWindow() }
}

# "Borrowing" the desktop is acceptable; keeping it is not. After any physical
# input we put the cursor back and hand the foreground back to whoever had it.
function Restore-Pointer($s) {
  if ($null -eq $s) { return }
  try { [void][N]::SetCursorPos([int]$s.x, [int]$s.y) } catch { }
  try {
    if ($s.fg -ne [IntPtr]::Zero -and [N]::GetForegroundWindow() -ne $s.fg) { [void][N]::ForceForeground($s.fg) }
  } catch { }
}

# ------------------------------------------------------------------ UIA layer

$script:PatternCache = $null
function Get-PatternList {
  if ($null -ne $script:PatternCache) { return $script:PatternCache }
  $script:PatternCache = @(
    @{ key = 'invoke';          p = [System.Windows.Automation.InvokePattern]::Pattern;          name = 'invoke' },
    @{ key = 'value';           p = [System.Windows.Automation.ValuePattern]::Pattern;           name = 'value' },
    @{ key = 'text';            p = [System.Windows.Automation.TextPattern]::Pattern;            name = 'text' },
    @{ key = 'selectionItem';   p = [System.Windows.Automation.SelectionItemPattern]::Pattern;   name = 'selectionItem' },
    @{ key = 'toggle';          p = [System.Windows.Automation.TogglePattern]::Pattern;          name = 'toggle' },
    @{ key = 'expandCollapse';  p = [System.Windows.Automation.ExpandCollapsePattern]::Pattern;  name = 'expandCollapse' },
    @{ key = 'selection';       p = [System.Windows.Automation.SelectionPattern]::Pattern;       name = 'selection' },
    @{ key = 'scroll';          p = [System.Windows.Automation.ScrollPattern]::Pattern;          name = 'scroll' },
    @{ key = 'window';          p = [System.Windows.Automation.WindowPattern]::Pattern;          name = 'window' },
    @{ key = 'transform';       p = [System.Windows.Automation.TransformPattern]::Pattern;       name = 'transform' }
  )
  return $script:PatternCache
}

function Get-UiaPatterns($el) {
  $found = @()
  foreach ($entry in (Get-PatternList)) {
    $o = $null
    try { if ($el.TryGetCurrentPattern($entry.p, [ref]$o)) { $found += $entry.name } } catch { }
  }
  # The leading comma stops PowerShell from unrolling an empty array into
  # nothing: the caller must receive @(), not $null, so "no patterns" and "not
  # probed" stay distinguishable.
  return ,$found
}

function Get-OptionalPattern($el, $pattern) {
  $o = $null
  try {
    if ($el.TryGetCurrentPattern($pattern, [ref]$o)) { return $o }
  } catch { }
  return $null
}

function New-UiaCondition($spec) {
  $conds = New-Object System.Collections.ArrayList
  $name = [string](Get-Arg $spec 'name' '')
  if ($name) { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name))) }
  $aid = [string](Get-Arg $spec 'automation_id' '')
  if ($aid) { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $aid))) }
  $cls = [string](Get-Arg $spec 'class_name' '')
  if ($cls) { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, $cls))) }
  $tp = [string](Get-Arg $spec 'type' '')
  if ($tp) { [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, (Resolve-ControlType $tp)))) }
  if ($conds.Count -eq 0) { return $null }
  if ($conds.Count -eq 1) { return $conds[0] }
  return (New-Object System.Windows.Automation.AndCondition([System.Windows.Automation.Condition[]]$conds.ToArray()))
}

function Resolve-ControlType([string]$name) {
  $t = [System.Windows.Automation.ControlType]
  $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::IgnoreCase
  $p = $t.GetProperty($name, $flags)
  if ($null -eq $p) { throw "unknown control type '$name' (e.g. Button, Edit, Document, Text, MenuItem, ListItem, TabItem, CheckBox, ComboBox, TreeItem, Hyperlink, Pane, Group, Window)" }
  return $p.GetValue($null)
}

function Resolve-UiaRoot($spec) {
  $match = [string](Get-Arg $spec 'window' '')
  $wantPid = Get-Arg $spec 'pid' 0
  if ($match -or $wantPid) {
    $h = Resolve-TargetWindow $match $wantPid
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    if ($null -eq $root) { throw 'UIA could not attach to the target window' }
    return @{ root = $root; handle = $h }
  }
  return @{ root = [System.Windows.Automation.AutomationElement]::RootElement; handle = [IntPtr]::Zero }
}

# Breadth-first so "first match" means shallowest match, and the element order
# is document order rather than a stack-shuffled one. Every COM failure is
# swallowed per element: one broken node must not abort a whole walk.
function Get-UiaFlat($root, [int]$maxDepth, [int]$maxNodes) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $items = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue(@{ el = $root; d = 0 })
  $truncated = $false
  while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    $el = $item.el
    $d = [int]$item.d
    if ($null -eq $el) { continue }
    try {
      $c = $el.Current
      $rect = $c.BoundingRectangle
      $x = Safe-Int $rect.X; $y = Safe-Int $rect.Y; $w = Safe-Int $rect.Width; $h = Safe-Int $rect.Height
      $valid = ($w -gt 0 -and $h -gt 0)
      [void]$items.Add([ordered]@{
        depth        = $d
        name         = [string]$c.Name
        type         = ([string]$c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
        automationId = [string]$c.AutomationId
        className    = [string]$c.ClassName
        hwnd         = [int64]$c.NativeWindowHandle
        enabled      = [bool]$c.IsEnabled
        offscreen    = [bool]$c.IsOffscreen
        focused      = [bool]$c.HasKeyboardFocus
        rect         = [ordered]@{ x = $x; y = $y; w = $w; h = $h; cx = $(if ($valid) { [int]($x + $w / 2) } else { 0 }); cy = $(if ($valid) { [int]($y + $h / 2) } else { 0 }); valid = $valid }
        el           = $el
      })
      if ($items.Count -ge $maxNodes) { $truncated = $true; break }
      if ($d -lt $maxDepth) {
        $child = $walker.GetFirstChild($el)
        while ($null -ne $child) {
          $queue.Enqueue(@{ el = $child; d = ($d + 1) })
          $child = $walker.GetNextSibling($child)
        }
      }
    } catch { }
  }
  return @{ items = $items; truncated = $truncated }
}

function Test-ElementFilter($item, $spec) {
  $name = [string](Get-Arg $spec 'name' '')
  if ($name -and $item.name -ne $name) { return $false }
  $nc = [string](Get-Arg $spec 'name_contains' '')
  if ($nc -and ($item.name -notlike "*$nc*")) { return $false }
  $aid = [string](Get-Arg $spec 'automation_id' '')
  if ($aid -and $item.automationId -ne $aid) { return $false }
  $cls = [string](Get-Arg $spec 'class_name' '')
  if ($cls -and ($item.className -notlike "*$cls*")) { return $false }
  $tp = [string](Get-Arg $spec 'type' '')
  if ($tp -and $item.type -ne $tp) { return $false }
  # Offscreen elements are still valid targets: a window that is merely covered
  # reports its contents as offscreen, and background work must not care.
  if ([bool](Get-Arg $spec 'visible_only' $false) -and $item.offscreen) { return $false }
  if ([bool](Get-Arg $spec 'enabled_only' $false) -and -not $item.enabled) { return $false }
  return $true
}

function Get-ElementPublic($item) {
  $o = [ordered]@{
    name      = $item.name
    type      = $item.type
    aid       = $item.automationId
    cls       = $item.className
    hwnd      = $item.hwnd
    enabled   = $item.enabled
    offscreen = $item.offscreen
    focused   = $item.focused
    rect      = $item.rect
  }
  return $o
}

function Find-Elements($spec, [int]$maxMatches) {
  $scope = Resolve-UiaRoot $spec
  $depth = [int](Get-Arg $spec 'depth' 14)
  $flat = Get-UiaFlat $scope.root $depth 900
  $hits = New-Object System.Collections.ArrayList
  foreach ($item in $flat.items) {
    if (-not (Test-ElementFilter $item $spec)) { continue }
    $score = 0
    if ($item.offscreen) { $score += 1 }
    if (-not $item.enabled) { $score += 1 }
    [void]$hits.Add(@{ item = $item; score = $score; order = $hits.Count })
  }
  $ranked = @($hits | Sort-Object -Property @{ Expression = { $_.score } }, @{ Expression = { $_.order } })
  return @{ scope = $scope; hits = $ranked; truncated = $flat.truncated; total = $hits.Count; max = $maxMatches }
}

function Find-OneElement($spec) {
  $res = Find-Elements $spec 1
  if ($res.hits.Count -eq 0) { return $null }
  $first = $res.hits[0]
  return @{
    el      = $first.item.el
    item    = $first.item
    scope   = $res.scope
    matches = $res.total
  }
}

function Resolve-ElementTarget($step, $state) {
  $ref = [string](Get-Arg $step 'ref' '')
  if ($ref) {
    if (-not $state.refs.ContainsKey($ref)) { throw "unknown ref '$ref' (declare it with {op:'find', as:'$ref'})" }
    return $state.refs[$ref]
  }
  $target = Get-Arg $step 'target' $null
  if ($null -ne $target) {
    $t = Find-OneElement $target
    if ($null -eq $t) { throw 'target element not found' }
    return $t
  }
  $inline = $false
  foreach ($k in @('name', 'name_contains', 'automation_id', 'class_name', 'type')) { if ([string](Get-Arg $step $k '')) { $inline = $true } }
  if ($inline) {
    $t = Find-OneElement $step
    if ($null -eq $t) {
      $what = [string](Get-Arg $step 'name' (Get-Arg $step 'name_contains' (Get-Arg $step 'automation_id' (Get-Arg $step 'class_name' (Get-Arg $step 'type' '')))))
      $scopeName = [string](Get-Arg $step 'window' '(foreground/desktop)')
      throw "element '$what' not found in '$scopeName'"
    }
    return $t
  }
  return $null
}

# ------------------------------------------------------- interaction strategy

$WM_SETTEXT = 0x000C
$WM_GETTEXT = 0x000D
$WM_CHAR = 0x0102
$BM_CLICK = 0x00F5

# Layer 1: UIA patterns. Works without focus and without moving the pointer for
# anything built on modern UI frameworks (WinUI / WPF / UWP / Chromium / Qt).
function Try-UiaClick($found, [string]$button, [int]$count) {
  if ($button -ne 'left') { return $null }
  $el = $found.el
  $inv = Get-OptionalPattern $el ([System.Windows.Automation.InvokePattern]::Pattern)
  if ($null -ne $inv) {
    for ($i = 0; $i -lt [Math]::Max(1, $count); $i++) { $inv.Invoke(); Start-Sleep -Milliseconds 60 }
    return [ordered]@{ ok = $true; strategy = 'uia.invoke'; target = (Get-ElementPublic $found.item) }
  }
  $sel = Get-OptionalPattern $el ([System.Windows.Automation.SelectionItemPattern]::Pattern)
  if ($null -ne $sel) {
    $sel.Select()
    Start-Sleep -Milliseconds 60
    return [ordered]@{ ok = $true; strategy = 'uia.select'; target = (Get-ElementPublic $found.item) }
  }
  $tg = Get-OptionalPattern $el ([System.Windows.Automation.TogglePattern]::Pattern)
  if ($null -ne $tg) {
    $tg.Toggle()
    Start-Sleep -Milliseconds 60
    return [ordered]@{ ok = $true; strategy = 'uia.toggle'; target = (Get-ElementPublic $found.item) }
  }
  $ec = Get-OptionalPattern $el ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
  if ($null -ne $ec) {
    try {
      if ($ec.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ec.Collapse() } else { $ec.Expand() }
      Start-Sleep -Milliseconds 60
      return [ordered]@{ ok = $true; strategy = 'uia.expandCollapse'; target = (Get-ElementPublic $found.item) }
    } catch { }
  }
  return $null
}

# Layer 2: Win32 messages straight to the control. No focus, no pointer, no
# activation -- the classic WinForms/Win32 automation route. Verified by
# reading the control back, because a wrong hwnd fails silently.
function Try-Win32SetText([IntPtr]$hwnd, [string]$text, [bool]$append) {
  if ($hwnd -eq [IntPtr]::Zero -or -not [N]::IsWindow($hwnd)) { return $null }
  # NEVER WM_SETTEXT a top-level window: that renames the window instead of
  # filling a field, and because the read-back then matches the value we just
  # set, the caller would be told "typed OK" while the user's window silently
  # got a new title. Only a child control may be addressed this way.
  if ([N]::GetAncestor($hwnd, 2) -eq $hwnd) { return $null }
  $before = ''
  try { $before = [N]::ControlText($hwnd) } catch { return $null }
  $value = $text
  if ($append) { $value = $before + $text }
  try { [void][N]::SendMessage($hwnd, $WM_SETTEXT, [IntPtr]::Zero, $value) } catch { return $null }
  Start-Sleep -Milliseconds 60
  $after = ''
  try { $after = [N]::ControlText($hwnd) } catch { return $null }
  if ($after -ne $value) { return $null }
  return [ordered]@{ ok = $true; strategy = 'win32.wm_settext'; hwnd = [int64]$hwnd; readback = $after }
}

function Try-Win32Click([IntPtr]$hwnd, [int]$x, [int]$y, [string]$button, [int]$count) {
  if ($hwnd -eq [IntPtr]::Zero -or -not [N]::IsWindow($hwnd)) { return $null }
  $pt = New-Object N+POINT
  $pt.X = $x; $pt.Y = $y
  if (-not [N]::ScreenToClient($hwnd, [ref]$pt)) { return $null }
  $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
  $down = 0x0201; $up = 0x0202
  if ($button -eq 'right') { $down = 0x0204; $up = 0x0205 }
  if ($button -eq 'middle') { $down = 0x0207; $up = 0x0208 }
  try {
    for ($i = 0; $i -lt [Math]::Max(1, $count); $i++) {
      [void][N]::SendMessage($hwnd, $down, [IntPtr]1, $lp)
      [void][N]::SendMessage($hwnd, $up, [IntPtr]::Zero, $lp)
      Start-Sleep -Milliseconds 40
    }
  } catch { return $null }
  Start-Sleep -Milliseconds 60
  return [ordered]@{ ok = $true; strategy = 'win32.wm_click'; hwnd = [int64]$hwnd; client = [ordered]@{ x = $pt.X; y = $pt.Y } }
}

function Try-Win32ClickButton([IntPtr]$hwnd, [int]$count) {
  if ($hwnd -eq [IntPtr]::Zero -or -not [N]::IsWindow($hwnd)) { return $null }
  $cls = [N]::Cls($hwnd)
  if ($cls -notlike '*BUTTON*') { return $null }
  try {
    for ($i = 0; $i -lt [Math]::Max(1, $count); $i++) { [void][N]::SendMessage($hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 60 }
  } catch { return $null }
  return [ordered]@{ ok = $true; strategy = 'win32.bm_click'; hwnd = [int64]$hwnd }
}

function Get-ElementHwnd($found) {
  if ($null -eq $found) { return [IntPtr]::Zero }
  $native = [int64]$found.item.hwnd
  if ($native -ne 0 -and [N]::IsWindow([IntPtr]$native)) { return [IntPtr]$native }
  $rect = $found.item.rect
  if ($rect.valid) {
    $root = [IntPtr]::Zero
    if ($null -ne $found.scope) { $root = $found.scope.handle }
    return (Get-HwndAtPoint $rect.cx $rect.cy $root)
  }
  return [IntPtr]::Zero
}

function Do-PhysicalClick([int]$x, [int]$y, [string]$button, [int]$count, [bool]$restore, [IntPtr]$window) {
  $saved = $null
  if ($restore) { $saved = Save-Pointer }
  if ($window -ne [IntPtr]::Zero) { [void][N]::ForceForeground($window) }
  [void][N]::SetCursorPos($x, $y)
  # Prove the pointer actually reached the requested spot BEFORE acting. Setting
  # a pointer is not atomic with clicking: a human (or another process) can move
  # it in between, and the click then lands somewhere else entirely.
  $arrived = $false
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 40
    $probe = New-Object N+POINT
    [void][N]::GetCursorPos([ref]$probe)
    if ([Math]::Abs($probe.X - $x) -le 2 -and [Math]::Abs($probe.Y - $y) -le 2) { $arrived = $true; break }
  }
  if (-not $arrived) {
    $now = New-Object N+POINT
    [void][N]::GetCursorPos([ref]$now)
    Restore-Pointer $saved
    throw ("refusing to act: pointer did not reach (" + $x + "," + $y + "); it is at (" + $now.X + "," + $now.Y + ") -- something else is moving the mouse")
  }
  switch ($button) {
    'right'  { [N]::mouse_event($MOUSEEVENTF.rightdown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.rightup, 0, 0, 0, [UIntPtr]::Zero) }
    'middle' { [N]::mouse_event($MOUSEEVENTF.middledown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.middleup, 0, 0, 0, [UIntPtr]::Zero) }
    default  { [N]::mouse_event($MOUSEEVENTF.leftdown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.leftup, 0, 0, 0, [UIntPtr]::Zero) }
  }
  if ($count -gt 1) {
    for ($i = 1; $i -lt $count; $i++) {
      Start-Sleep -Milliseconds 90
      [N]::mouse_event($MOUSEEVENTF.leftdown, 0, 0, 0, [UIntPtr]::Zero)
      [N]::mouse_event($MOUSEEVENTF.leftup, 0, 0, 0, [UIntPtr]::Zero)
    }
  }
  Start-Sleep -Milliseconds 120
  $after = New-Object N+POINT
  [void][N]::GetCursorPos([ref]$after)
  Restore-Pointer $saved
  return [ordered]@{
    ok                = $true
    strategy          = 'physical'
    clickedAt         = [ordered]@{ x = $x; y = $y }
    cursorNow         = [ordered]@{ x = $after.X; y = $after.Y }
    pointerRestored   = [bool]$restore
    foregroundWindow  = (Get-WindowInfo ([N]::GetForegroundWindow()))
  }
}

function Do-PhysicalType([string]$text, [IntPtr]$window, [bool]$restore) {
  $saved = $null
  if ($restore) { $saved = Save-Pointer }
  if ($window -ne [IntPtr]::Zero) {
    [void][N]::ForceForeground($window)
    for ($i = 0; $i -lt 24; $i++) {
      if ([N]::GetForegroundWindow() -eq $window) { break }
      Start-Sleep -Milliseconds 50
    }
    if ([N]::GetForegroundWindow() -ne $window) {
      Restore-Pointer $saved
      throw ("refusing to type: could not bring the target window to the foreground (handle " + [int64]$window + ")")
    }
  }
  [N]::TypeUnicode($text)
  Start-Sleep -Milliseconds 80
  Restore-Pointer $saved
  return [ordered]@{ ok = $true; strategy = 'physical.keystrokes'; chars = $text.Length; pointerRestored = [bool]$restore }
}

# ------------------------------------------------------------------- actions

function Do-Display {
  $screens = @()
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $screens += [ordered]@{
      device      = $s.DeviceName
      primary     = [bool]$s.Primary
      bounds      = [ordered]@{ x = $s.Bounds.X; y = $s.Bounds.Y; w = $s.Bounds.Width; h = $s.Bounds.Height }
      workingArea = [ordered]@{ x = $s.WorkingArea.X; y = $s.WorkingArea.Y; w = $s.WorkingArea.Width; h = $s.WorkingArea.Height }
    }
  }
  $cur = New-Object N+POINT
  [void][N]::GetCursorPos([ref]$cur)
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  return [ordered]@{
    ok               = $true
    dpiAware         = $true
    screenCount      = $screens.Count
    screens          = $screens
    virtualScreen    = [ordered]@{ x = $vs.X; y = $vs.Y; w = $vs.Width; h = $vs.Height }
    cursor           = [ordered]@{ x = $cur.X; y = $cur.Y }
    foregroundWindow = (Get-WindowInfo ([N]::GetForegroundWindow()))
  }
}

function Do-Screenshot($a) {
  $scale   = [double](Get-Arg $a 'scale' 1.0)
  $outPath = [string](Get-Arg $a 'path' '')
  $win     = [string](Get-Arg $a 'window' '')
  $wantPid = Get-Arg $a 'pid' 0
  $display = [int](Get-Arg $a 'display' -1)
  $region  = [string](Get-Arg $a 'region' '')
  $source  = 'screen'
  $targetWindow = [IntPtr]::Zero
  $minimized = $false

  $x = 0; $y = 0; $w = 0; $h = 0
  # region wins over window/pid/display: it is the more specific request, and
  # silently ignoring an explicit region is how the caller ends up looking at
  # the wrong pixels.
  if ($region) {
    $parts = "$region".Split(',')
    if ($parts.Count -ne 4) { throw "region must be 'x,y,w,h'" }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
  } elseif ($win -or $wantPid) {
    # Deliberately do NOT activate the window: activating is what makes an agent
    # steal the desktop. PrintWindow reads the window's own rendering instead.
    $t = Resolve-TargetWindow $win $wantPid
    $targetWindow = $t
    $minimized = [bool][N]::IsIconic($t)
    $info = Get-WindowInfo $t
    $x = $info.rect.x; $y = $info.rect.y; $w = $info.rect.w; $h = $info.rect.h
  } else {
    $all = [System.Windows.Forms.Screen]::AllScreens
    if ($display -ge 0) {
      if ($display -ge $all.Count) { throw "display index $display out of range (0..$($all.Count - 1))" }
      $b = $all[$display].Bounds
      $x = $b.X; $y = $b.Y; $w = $b.Width; $h = $b.Height
    } else {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $x = $vs.X; $y = $vs.Y; $w = $vs.Width; $h = $vs.Height
    }
  }
  if ($w -le 0 -or $h -le 0) { throw "resolved capture area is empty ($w x $h)" }
  if ($scale -lt 0.1 -or $scale -gt 1.0) { throw "scale must be between 0.1 and 1.0" }

  $target = $outPath
  if (-not $target) {
    $dir = Join-Path $env:TEMP 'dsh-computer-use'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    $target = Join-Path $dir ("shot-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + ".png")
  }

  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $captured = $false
  if ($targetWindow -ne [IntPtr]::Zero) {
    try {
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $hdc = $g.GetHdc()
      $captured = [N]::PrintWindow($targetWindow, $hdc, 2)
      $g.ReleaseHdc($hdc)
      $g.Dispose()
      if ($captured) { $source = 'printwindow' }
    } catch { $captured = $false }
  }
  if (-not $captured) {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $source = 'screen'
  }

  $finalW = $w; $finalH = $h
  if ($scale -lt 1.0) {
    $finalW = [int][Math]::Max(1, [Math]::Round($w * $scale))
    $finalH = [int][Math]::Max(1, [Math]::Round($h * $scale))
    $resized = New-Object System.Drawing.Bitmap($finalW, $finalH)
    $g2 = [System.Drawing.Graphics]::FromImage($resized)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, $finalW, $finalH)
    $g2.Dispose()
    $bmp.Dispose()
    $bmp = $resized
  }
  $bmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $bytes = (Get-Item -LiteralPath $target).Length
  $res = [ordered]@{
    ok         = $true
    path       = $target
    width      = $finalW
    height     = $finalH
    sourceRect = [ordered]@{ x = $x; y = $y; w = $w; h = $h }
    source     = $source
    bytes      = [int64]$bytes
  }
  if ($targetWindow -ne [IntPtr]::Zero) {
    $res.window = [int64]$targetWindow
    if ($minimized) { $res.minimized = $true; $res.note = 'window was minimized; the capture may be blank -- restore it first for a real frame' }
    if ($source -eq 'screen') { $res.note = 'PrintWindow failed for this window, fell back to a screen grab which may include windows on top' }
  }
  return $res
}

function Do-Windows($a) {
  $act     = [string](Get-Arg $a 'action' 'list')
  $match   = [string](Get-Arg $a 'match' '')
  $wantPid = Get-Arg $a 'pid' 0
  $max     = [int](Get-Arg $a 'max' 30)
  if ($act -eq 'list') {
    $list = @(Get-TopWindows $match $wantPid)
    $fgH = [int64][N]::GetForegroundWindow()
    $trim = @()
    foreach ($e in $list) {
      if ($trim.Count -ge $max) { break }
      $e['focused'] = ([int64]$e.handle -eq $fgH)
      $trim += $e
    }
    return [ordered]@{ ok = $true; total = $list.Count; shown = $trim.Count; foregroundHandle = $fgH; windows = $trim }
  }
  $t = Resolve-TargetWindow $match $wantPid
  $r = $true
  switch ($act) {
    'focus' {
      # Do NOT SW_RESTORE unconditionally: that un-maximizes a maximized window.
      if ([N]::IsIconic($t)) { [void][N]::ShowWindow($t, 9) }
      [void][N]::ForceForeground($t)
      $verified = $false
      for ($i = 0; $i -lt 24; $i++) {
        if ([N]::GetForegroundWindow() -eq $t) { $verified = $true; break }
        Start-Sleep -Milliseconds 50
      }
      if (-not $verified) { throw ("could not bring the window to the foreground (handle " + [int64]$t + ")") }
    }
    'minimize' { $r = [N]::ShowWindow($t, 6) }
    'maximize' { [void][N]::ShowWindow($t, 9); $r = [N]::ShowWindow($t, 3) }
    'restore'  { $r = [N]::ShowWindow($t, 9) }
    'close'    { $r = [N]::PostMessage($t, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    'move'     {
      $mx = [int](Get-Arg $a 'x' 0); $my = [int](Get-Arg $a 'y' 0)
      $mw = [int](Get-Arg $a 'w' 0); $mh = [int](Get-Arg $a 'h' 0)
      if ($mw -le 0 -or $mh -le 0) {
        $info = Get-WindowInfo $t
        if ($mw -le 0) { $mw = $info.rect.w }
        if ($mh -le 0) { $mh = $info.rect.h }
      }
      [void][N]::ShowWindow($t, 9)
      $r = [N]::MoveWindow($t, $mx, $my, $mw, $mh, $true)
    }
    default { throw "unknown windows action '$act' (list|focus|minimize|maximize|restore|close|move)" }
  }
  Start-Sleep -Milliseconds 150
  return [ordered]@{ ok = $true; action = $act; applied = [bool]$r; window = (Get-WindowInfo $t) }
}

function Do-Focus($a) {
  $match = [string](Get-Arg $a 'window' (Get-Arg $a 'match' ''))
  $wantPid = Get-Arg $a 'pid' 0
  $t = Focus-Target $match $wantPid
  return [ordered]@{ ok = $true; focused = (Get-WindowInfo $t) }
}

function Do-Mouse($a) {
  $act = [string](Get-Arg $a 'action' 'click')
  $x = Get-Arg $a 'x' $null
  $y = Get-Arg $a 'y' $null
  $restore = [bool](Get-Arg $a 'restore' $true)
  if ($act -eq 'move' -or $act -eq 'scroll') { $restore = [bool](Get-Arg $a 'restore' $false) }
  $saved = $null
  if ($restore) { $saved = Save-Pointer }
  if ($null -ne $x -and $null -ne $y) {
    [void][N]::SetCursorPos([int]$x, [int]$y)
    $arrived = $false
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Milliseconds 40
      $probe = New-Object N+POINT
      [void][N]::GetCursorPos([ref]$probe)
      if ([Math]::Abs($probe.X - [int]$x) -le 2 -and [Math]::Abs($probe.Y - [int]$y) -le 2) { $arrived = $true; break }
    }
    if (-not $arrived) {
      $now = New-Object N+POINT
      [void][N]::GetCursorPos([ref]$now)
      Restore-Pointer $saved
      throw ("refusing to act: pointer did not reach (" + [int]$x + "," + [int]$y + "); it is at (" + $now.X + "," + $now.Y + ") -- something else is moving the mouse")
    }
  }
  $cur = New-Object N+POINT
  [void][N]::GetCursorPos([ref]$cur)
  switch ($act) {
    'move'   { }
    'click'  { [N]::mouse_event($MOUSEEVENTF.leftdown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.leftup, 0, 0, 0, [UIntPtr]::Zero) }
    'right_click'  { [N]::mouse_event($MOUSEEVENTF.rightdown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.rightup, 0, 0, 0, [UIntPtr]::Zero) }
    'middle_click' { [N]::mouse_event($MOUSEEVENTF.middledown, 0, 0, 0, [UIntPtr]::Zero); [N]::mouse_event($MOUSEEVENTF.middleup, 0, 0, 0, [UIntPtr]::Zero) }
    'double_click' {
      for ($i = 0; $i -lt 2; $i++) {
        [N]::mouse_event($MOUSEEVENTF.leftdown, 0, 0, 0, [UIntPtr]::Zero)
        [N]::mouse_event($MOUSEEVENTF.leftup, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 90
      }
    }
    'drag' {
      $tx = [int](Get-Arg $a 'to_x' 0); $ty = [int](Get-Arg $a 'to_y' 0)
      [N]::mouse_event($MOUSEEVENTF.leftdown, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 120
      $steps = 24
      for ($i = 1; $i -le $steps; $i++) {
        $ix = [int]($cur.X + (($tx - $cur.X) * $i / $steps))
        $iy = [int]($cur.Y + (($ty - $cur.Y) * $i / $steps))
        [void][N]::SetCursorPos($ix, $iy)
        Start-Sleep -Milliseconds 12
      }
      [N]::mouse_event($MOUSEEVENTF.leftup, 0, 0, 0, [UIntPtr]::Zero)
    }
    'scroll' {
      $amount = [int](Get-Arg $a 'amount' 3)
      $horizontal = [bool](Get-Arg $a 'horizontal' $false)
      $flag = if ($horizontal) { $MOUSEEVENTF.hwheel } else { $MOUSEEVENTF.wheel }
      # mouse_event takes an unsigned DWORD, but the wheel delta is signed
      # (negative = scroll down). [uint32] of a negative int throws, so go
      # through the two's-complement bit pattern instead.
      $delta = [int]($amount * 120)
      $wheelData = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($delta), 0)
      [N]::mouse_event($flag, 0, 0, $wheelData, [UIntPtr]::Zero)
    }
    default { throw "unknown mouse action '$act' (move|click|double_click|right_click|middle_click|drag|scroll)" }
  }
  Start-Sleep -Milliseconds 120
  $after = New-Object N+POINT
  [void][N]::GetCursorPos([ref]$after)
  Restore-Pointer $saved
  $under = [N]::WindowFromPoint($after)
  return [ordered]@{
    ok                = $true
    action            = $act
    cursor            = [ordered]@{ x = $after.X; y = $after.Y }
    pointerRestored   = [bool]$restore
    foregroundWindow  = (Get-WindowInfo ([N]::GetForegroundWindow()))
    windowUnderCursor = (Get-WindowInfo $under)
  }
}

function Convert-KeysToVk([string]$keys) {
  $map = @{
    ctrl = 0x11; control = 0x11; shift = 0x10; alt = 0x12; win = 0x5B; lwin = 0x5B
    enter = 0x0D; return = 0x0D; esc = 0x1B; escape = 0x1B; tab = 0x09; space = 0x20
    backspace = 0x08; delete = 0x2E; del = 0x2E; insert = 0x2D; ins = 0x2D
    home = 0x24; end = 0x23; pageup = 0x21; pgup = 0x21; pagedown = 0x22; pgdn = 0x22
    up = 0x26; down = 0x28; left = 0x25; right = 0x27
    capslock = 0x14; printscreen = 0x2C; prtsc = 0x2C; pause = 0x13; menu = 0x5D
    f1 = 0x70; f2 = 0x71; f3 = 0x72; f4 = 0x73; f5 = 0x74; f6 = 0x75
    f7 = 0x76; f8 = 0x77; f9 = 0x78; f10 = 0x79; f11 = 0x7A; f12 = 0x7B
  }
  $vks = @()
  foreach ($k in "$keys".ToLower().Split('+')) {
    $k = $k.Trim()
    if (-not $k) { continue }
    if ($map.ContainsKey($k)) { $vks += $map[$k]; continue }
    if ($k.Length -eq 1) { $vks += [int][char][char]::ToUpper($k[0]); continue }
    throw "unknown key '$k'"
  }
  # Leading comma: a one-key combo must still come back as an array, otherwise
  # the caller sees a bare int and the shape changes with the key count.
  return ,$vks
}

function Send-KeyCombo([string]$keys, [int]$repeat) {
  $vks = Convert-KeysToVk $keys
  if ($vks.Count -eq 0) { throw "keys must name at least one key (e.g. ctrl+shift+s)" }
  $extended = @(0x25, 0x26, 0x27, 0x28, 0x24, 0x23, 0x21, 0x22, 0x2D, 0x2E, 0x5B, 0x5D)
  for ($r = 0; $r -lt [Math]::Max(1, $repeat); $r++) {
    foreach ($vk in $vks) {
      $flags = if ($extended -contains $vk) { [uint32]0x0001 } else { [uint32]0 }
      [N]::keybd_event([byte]$vk, 0, $flags, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 30
    for ($i = $vks.Count - 1; $i -ge 0; $i--) {
      $vk = $vks[$i]
      $flags = if ($extended -contains $vk) { [uint32](0x0001 -bor 0x0002) } else { [uint32]0x0002 }
      [N]::keybd_event([byte]$vk, 0, $flags, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 30
  }
  return ,$vks
}

function Do-Keyboard($a) {
  $act = [string](Get-Arg $a 'action' 'type')
  $repeat = [int](Get-Arg $a 'repeat' 1)
  $win = [string](Get-Arg $a 'window' '')
  $wantPid = Get-Arg $a 'pid' 0
  $restore = [bool](Get-Arg $a 'restore' $true)
  $target = [IntPtr]::Zero
  if ($win -or $wantPid) { $target = Resolve-TargetWindow $win $wantPid }
  if ($act -eq 'type') {
    $text = [string](Get-Arg $a 'text' '')
    if (-not $text) { throw "keyboard type requires 'text'" }
    $out = [ordered]@{ ok = $true; action = 'type'; chars = $text.Length }
    for ($i = 0; $i -lt [Math]::Max(1, $repeat); $i++) { [void](Do-PhysicalType $text $target $restore) }
    $out.foregroundWindow = (Get-WindowInfo ([N]::GetForegroundWindow()))
    return $out
  }
  if ($act -eq 'press') {
    $keys = [string](Get-Arg $a 'keys' '')
    if (-not $keys) { throw "keyboard press requires 'keys' (e.g. ctrl+shift+s)" }
    $saved = $null
    if ($restore) { $saved = Save-Pointer }
    if ($target -ne [IntPtr]::Zero) { [void](Focus-Target $win $wantPid) }
    $vks = Send-KeyCombo $keys $repeat
    Restore-Pointer $saved
    return [ordered]@{ ok = $true; action = 'press'; combo = $keys; vks = $vks; foregroundWindow = (Get-WindowInfo ([N]::GetForegroundWindow())) }
  }
  throw "unknown keyboard action '$act' (type|press)"
}

function Do-Clipboard($a) {
  $act = [string](Get-Arg $a 'action' 'get')
  if ($act -eq 'get') {
    $text = ''
    try { $text = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $text = '' }
    if ($null -eq $text) { $text = '' }
    return [ordered]@{ ok = $true; action = 'get'; length = $text.Length; text = $text }
  }
  if ($act -eq 'set') {
    $text = [string](Get-Arg $a 'text' '')
    Set-Clipboard -Value $text
    return [ordered]@{ ok = $true; action = 'set'; length = $text.Length }
  }
  throw "unknown clipboard action '$act' (get|set)"
}

function Do-Process($a) {
  $act = [string](Get-Arg $a 'action' 'list')
  $max = [int](Get-Arg $a 'max' 30)
  if ($act -eq 'list') {
    $filter = [string](Get-Arg $a 'filter' '')
    $procs = @()
    foreach ($p in (Get-Process | Sort-Object -Property WorkingSet64 -Descending)) {
      if ($filter -and ($p.ProcessName -notlike "*$filter*")) { continue }
      $procs += [ordered]@{
        pid      = $p.Id
        name     = $p.ProcessName
        title    = $(try { [N]::Title([IntPtr]$p.MainWindowHandle) } catch { '' })
        memoryMB = [int][Math]::Round($p.WorkingSet64 / 1MB, 1)
      }
      if ($procs.Count -ge $max) { break }
    }
    return [ordered]@{ ok = $true; total = $procs.Count; processes = $procs }
  }
  if ($act -eq 'start') {
    $target = [string](Get-Arg $a 'path' '')
    if (-not $target) { $target = [string](Get-Arg $a 'name' '') }
    if (-not $target) { throw "process start requires 'path' or 'name'" }
    $argList = [string](Get-Arg $a 'args' '')
    if ($argList) { $p = Start-Process -FilePath $target -ArgumentList $argList -PassThru }
    else { $p = Start-Process -FilePath $target -PassThru }
    Start-Sleep -Milliseconds 600
    return [ordered]@{ ok = $true; action = 'start'; pid = $p.Id; name = $p.ProcessName }
  }
  if ($act -eq 'stop') {
    $wantPid = Get-Arg $a 'pid' 0
    $nm = [string](Get-Arg $a 'name' '')
    if ($wantPid) { Stop-Process -Id ([int]$wantPid) -Force; return [ordered]@{ ok = $true; action = 'stop'; pid = [int]$wantPid } }
    if ($nm) { Stop-Process -Name $nm -Force; return [ordered]@{ ok = $true; action = 'stop'; name = $nm } }
    throw "process stop requires 'pid' or 'name'"
  }
  throw "unknown process action '$act' (list|start|stop)"
}

function Do-Uia($a) {
  $maxDepth = [int](Get-Arg $a 'depth' 8)
  $maxNodes = [int](Get-Arg $a 'max_nodes' 250)
  $filter = [string](Get-Arg $a 'filter' '')
  $wantPatterns = [bool](Get-Arg $a 'patterns' $false)
  $scope = Resolve-UiaRoot $a
  $flat = Get-UiaFlat $scope.root $maxDepth $maxNodes
  $out = @()
  foreach ($item in $flat.items) {
    if ($filter -and ($item.name -notlike "*$filter*")) { continue }
    $o = Get-ElementPublic $item
    $o.depth = $item.depth
    if ($wantPatterns) { $o.patterns = (Get-UiaPatterns $item.el) }
    $out += $o
  }
  $res = [ordered]@{ ok = $true; total = $out.Count; truncated = [bool]$flat.truncated; nodes = $out }
  if ($scope.handle -ne [IntPtr]::Zero) { $res.window = (Get-WindowInfo $scope.handle) }
  return $res
}

function Do-Find($a, $state) {
  $max = [int](Get-Arg $a 'max' 10)
  $res = Find-Elements $a $max
  $shown = @()
  $i = 0
  foreach ($hit in $res.hits) {
    if ($i -ge $max) { break }
    $o = Get-ElementPublic $hit.item
    $o.depth = $hit.item.depth
    $o.score = $hit.score
    $o.patterns = (Get-UiaPatterns $hit.item.el)
    $shown += $o
    $i++
  }
  $refName = [string](Get-Arg $a 'as' '')
  if ($refName -and $res.hits.Count -gt 0) {
    $pick = [int](Get-Arg $a 'index' 0)
    if ($pick -ge $res.hits.Count) { throw "index $pick out of range: only $($res.hits.Count) match(es)" }
    $chosen = $res.hits[$pick]
    $state.refs[$refName] = @{ el = $chosen.item.el; item = $chosen.item; scope = $res.scope; matches = $res.total }
  }
  $out = [ordered]@{ ok = $true; matches = $res.total; shown = $shown.Count; elements = $shown }
  if ($refName) { $out.ref = $refName }
  if ($res.total -eq 0) { $out.note = 'no element matched; widen the scope (window), drop exact `name` for `name_contains`, or pass depth' }
  return $out
}

function Do-Click($a, $state) {
  $mode = [string](Get-Arg $a 'mode' 'auto')
  $button = [string](Get-Arg $a 'button' 'left')
  $count = [int](Get-Arg $a 'count' 1)
  $restore = [bool](Get-Arg $a 'restore' $true)
  $wantPid = Get-Arg $a 'pid' 0
  $win = [string](Get-Arg $a 'window' '')
  $windowHandle = [IntPtr]::Zero
  if ($win -or $wantPid) { $windowHandle = Get-OptionalWindow $win $wantPid }

  $found = Resolve-ElementTarget $a $state
  if ($null -ne $found) {
    if ($mode -ne 'physical') {
      $uia = Try-UiaClick $found $button $count
      if ($null -ne $uia) { return $uia }
      $hwnd = Get-ElementHwnd $found
      if ($hwnd -ne [IntPtr]::Zero) {
        $bm = Try-Win32ClickButton $hwnd $count
        if ($null -ne $bm) { $bm.target = (Get-ElementPublic $found.item); return $bm }
        $rect = $found.item.rect
        if ($rect.valid) {
          $wc = Try-Win32Click $hwnd $rect.cx $rect.cy $button $count
          if ($null -ne $wc) { $wc.target = (Get-ElementPublic $found.item); return $wc }
        }
      }
      if ($mode -eq 'background') {
        throw ("background click on '" + $found.item.name + "' failed: no invokable UIA pattern and no usable window handle; retry with mode:'physical' (that takes over the pointer and foreground briefly)")
      }
    }
    $rect = $found.item.rect
    if (-not $rect.valid) { throw ("element '" + $found.item.name + "' has no usable rectangle; use {op:'find'} first and click by coordinates") }
    $r = Do-PhysicalClick $rect.cx $rect.cy $button $count $restore (Get-ElementHwnd $found)
    $r.target = (Get-ElementPublic $found.item)
    return $r
  }

  $x = Get-Arg $a 'x' $null
  $y = Get-Arg $a 'y' $null
  if ($null -eq $x -or $null -eq $y) { throw "click needs an element target (ref / name / name_contains / automation_id / target) or explicit x and y" }
  if ($mode -eq 'background') {
    $hwnd = Get-HwndAtPoint ([int]$x) ([int]$y) $windowHandle
    $r = Try-Win32Click $hwnd ([int]$x) ([int]$y) $button $count
    if ($null -ne $r) { return $r }
    throw "background click at ($x,$y) failed: no window accepted the message; retry with mode:'physical'"
  }
  return (Do-PhysicalClick ([int]$x) ([int]$y) $button $count $restore $windowHandle)
}

function Do-Type($a, $state) {
  $text = [string](Get-Arg $a 'text' '')
  if (-not $text) { throw "type requires 'text'" }
  $mode = [string](Get-Arg $a 'mode' 'auto')
  $append = [bool](Get-Arg $a 'append' $false)
  $restore = [bool](Get-Arg $a 'restore' $true)
  $wantPid = Get-Arg $a 'pid' 0
  $win = [string](Get-Arg $a 'window' '')
  $windowHandle = [IntPtr]::Zero
  if ($win -or $wantPid) { $windowHandle = Get-OptionalWindow $win $wantPid }

  $found = Resolve-ElementTarget $a $state
  if ($null -eq $found) {
    if ($mode -eq 'background') {
      # Address the control, not the window: WM_SETTEXT to a top-level window
      # would rename it. Say that plainly instead of attempting it.
      throw "background type needs a field to write into: pass name / name_contains / automation_id / class_name to pick the control (use {op:'find'} first if you need to see what is there), or mode:'physical' to let the engine focus the window and send real keystrokes"
    }
    return (Do-PhysicalType $text $windowHandle $restore)
  }

  if ($mode -ne 'physical') {
    $vp = Get-OptionalPattern $found.el ([System.Windows.Automation.ValuePattern]::Pattern)
    if ($null -ne $vp) {
      $value = $text
      if ($append) { $value = [string]$vp.Current.Value + $text }
      $threw = $false
      try { $vp.SetValue($value) } catch { $threw = $true }
      if (-not $threw) {
        Start-Sleep -Milliseconds 80
        return [ordered]@{ ok = $true; strategy = 'uia.valuePattern'; chars = $text.Length; readback = [string]$vp.Current.Value; target = (Get-ElementPublic $found.item) }
      }
    }
    $hwnd = Get-ElementHwnd $found
    $r = Try-Win32SetText $hwnd $text $append
    if ($null -ne $r) { $r.target = (Get-ElementPublic $found.item); return $r }
    if ($mode -eq 'background') {
      throw ("background type into '" + $found.item.name + "' failed: no ValuePattern and no control accepted WM_SETTEXT; retry with mode:'physical'")
    }
  }
  $r = Do-PhysicalType $text (Get-ElementHwnd $found) $restore
  $r.target = (Get-ElementPublic $found.item)
  return $r
}

function Do-Key($a, $state) {
  $keys = [string](Get-Arg $a 'keys' '')
  if (-not $keys) { throw "key requires 'keys' (e.g. ctrl+s, enter, alt+F4)" }
  $mode = [string](Get-Arg $a 'mode' 'auto')
  $repeat = [int](Get-Arg $a 'repeat' 1)
  $restore = [bool](Get-Arg $a 'restore' $true)
  $wantPid = Get-Arg $a 'pid' 0
  $win = [string](Get-Arg $a 'window' '')
  $found = Resolve-ElementTarget $a $state
  $target = [IntPtr]::Zero
  if ($null -ne $found) { $target = Get-ElementHwnd $found }
  elseif ($win -or $wantPid) { $target = Get-OptionalWindow $win $wantPid }

  if ($mode -eq 'background') {
    # Keystrokes go through the OS input queue, so there is no honest
    # background variant; say so instead of quietly taking the desktop.
    throw "key has no background implementation (keystrokes must go through the OS input queue); use mode:'physical' and expect a brief focus change, or prefer {op:'type'} / {op:'click'} which work in the background"
  }
  $saved = $null
  if ($restore) { $saved = Save-Pointer }
  if ($target -ne [IntPtr]::Zero) {
    [void][N]::ForceForeground($target)
    for ($i = 0; $i -lt 24; $i++) {
      if ([N]::GetForegroundWindow() -eq $target) { break }
      Start-Sleep -Milliseconds 50
    }
    if ([N]::GetForegroundWindow() -ne $target) {
      Restore-Pointer $saved
      throw ("refusing to send keys: could not bring the target window to the foreground (handle " + [int64]$target + ")")
    }
  }
  $vks = Send-KeyCombo $keys $repeat
  Start-Sleep -Milliseconds 80
  Restore-Pointer $saved
  return [ordered]@{ ok = $true; strategy = 'physical.keys'; combo = $keys; vks = $vks; pointerRestored = [bool]$restore }
}

function Test-StepCondition($step) {
  $ms = Get-Arg $step 'ms' $null
  if ($null -ne $ms) { Start-Sleep -Milliseconds ([int]$ms); return $true }
  $state = [string](Get-Arg $step 'state' 'exists')
  $wantPid = Get-Arg $step 'pid' 0
  $win = [string](Get-Arg $step 'window' '')
  $proc = [string](Get-Arg $step 'process' '')
  $elementish = $false
  foreach ($k in @('name', 'name_contains', 'automation_id', 'type')) { if ([string](Get-Arg $step $k '')) { $elementish = $true } }

  if ($proc) {
    $running = @(Get-Process -Name $proc -ErrorAction SilentlyContinue).Count -gt 0
    if ($state -eq 'gone') { return (-not $running) }
    return $running
  }
  if ($elementish) {
    $found = $null
    try { $found = Find-OneElement $step } catch { $found = $null }
    if ($state -eq 'gone') { return ($null -eq $found) }
    return ($null -ne $found)
  }
  if ($win -or $wantPid) {
    $h = Get-OptionalWindow $win $wantPid
    switch ($state) {
      'gone'       { return ($null -eq $h) }
      'foreground' { return ($null -ne $h -and [N]::GetForegroundWindow() -eq $h) }
      'visible'    { return ($null -ne $h -and [N]::IsWindowVisible($h)) }
      default      { return ($null -ne $h) }
    }
  }
  throw "wait/assert needs one condition: window (+state), process (+state), an element filter (name/name_contains/automation_id/type), or ms"
}

function Do-Wait($a) {
  $timeout = [int](Get-Arg $a 'timeout_ms' 15000)
  $interval = [int](Get-Arg $a 'interval_ms' 250)
  # stable_ms: the condition must keep holding for this long before it counts.
  # A window that exists one instant and is gone the next (an app still coming
  # up, or a shell tearing one down) would otherwise satisfy a plain poll and
  # the next step would then act on nothing.
  $stable = [int](Get-Arg $a 'stable_ms' 0)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $attempts = 0
  $held = 0
  while ($true) {
    $attempts++
    if (Test-StepCondition $a) {
      $held += $interval
      if ($held -ge $stable) {
        return [ordered]@{ ok = $true; waited_ms = [int]$sw.ElapsedMilliseconds; attempts = $attempts; satisfied = $true }
      }
    } else {
      $held = 0
    }
    if ($sw.ElapsedMilliseconds -ge $timeout) {
      throw ("wait timed out after " + $timeout + "ms (" + $attempts + " checks)")
    }
    Start-Sleep -Milliseconds $interval
  }
}

# --------------------------------------------------------------- batch driver

function Invoke-Step($op, $step, $state) {
  switch ($op) {
    'display'   { return (Do-Display) }
    'windows'   { return (Do-Windows $step) }
    'shot'      { return (Do-Screenshot $step) }
    'uia'       { return (Do-Uia $step) }
    'find'      { return (Do-Find $step $state) }
    'click'     { return (Do-Click $step $state) }
    'type'      { return (Do-Type $step $state) }
    'key'       { return (Do-Key $step $state) }
    'mouse'     { return (Do-Mouse $step) }
    'focus'     { return (Do-Focus $step) }
    'clipboard' { return (Do-Clipboard $step) }
    'process'   { return (Do-Process $step) }
    'wait'      { return (Do-Wait $step) }
    'sleep'     { Start-Sleep -Milliseconds ([int](Get-Arg $step 'ms' 500)); return [ordered]@{ ok = $true } }
    default {
      throw "unknown op '$op'; valid ops: display, windows, shot, uia, find, click, type, key, mouse, focus, clipboard, process, wait, sleep"
    }
  }
}

function Invoke-Batch($a) {
  $steps = @(Get-Arg $a 'steps' @())
  if ($steps.Count -eq 0) { throw "steps must be a non-empty array" }
  $onError = [string](Get-Arg $a 'on_error' 'stop')
  $budget = [int](Get-Arg $a 'timeout_ms' 120000)
  $state = @{ refs = @{} }
  $results = New-Object System.Collections.ArrayList
  $failedAt = -1
  $swAll = [System.Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $steps.Count; $i++) {
    $step = $steps[$i]
    $op = [string](Get-Arg $step 'op' '')
    $entry = [ordered]@{ i = $i; op = $op }
    $label = [string](Get-Arg $step 'label' '')
    if ($label) { $entry.label = $label }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = $null
    $failed = $false
    try {
      if ($swAll.ElapsedMilliseconds -gt $budget) { throw "batch budget exceeded (" + $budget + "ms)" }
      $res = Invoke-Step $op $step $state
      if ($null -eq $res) { $res = [ordered]@{ ok = $true } }
    } catch {
      $failed = $true
      $res = [ordered]@{ ok = $false; error = $_.Exception.Message }
    }
    $sw.Stop()
    # Copy the step's fields onto the entry. Deliberately NOT "$res.Keys":
    # PowerShell member access is case-insensitive, so a result carrying its own
    # `keys` field shadows OrderedDictionary.Keys and the loop then iterates the
    # VALUE of that field instead of the property names -- which silently
    # reported `{"key":null}` for a step that had in fact succeeded.
    if ($res -is [System.Collections.IDictionary]) {
      foreach ($pair in $res.GetEnumerator()) { $entry[$pair.Key] = $pair.Value }
    } else {
      foreach ($p in $res.PSObject.Properties) { $entry[$p.Name] = $p.Value }
    }
    $entry.ms = [int]$sw.ElapsedMilliseconds
    [void]$results.Add($entry)
    if ($failed) {
      $optional = [bool](Get-Arg $step 'optional' $false)
      if (-not $optional -and $onError -ne 'continue') { $failedAt = $i; break }
    }
  }
  $out = [ordered]@{
    ok         = ($failedAt -lt 0)
    steps      = $steps.Count
    executed   = $results.Count
    failedStep = $(if ($failedAt -ge 0) { $failedAt } else { $null })
    total_ms   = [int]$swAll.ElapsedMilliseconds
    results    = $results
  }
  if ($failedAt -ge 0) { $out.error = $results[$failedAt].error }
  return $out
}

# -------------------------------------------------------------------- routing

function Invoke-Action([string]$action, $a) {
  switch ($action) {
    ''           { throw 'action is required' }
    'ping'       { return [ordered]@{ ok = $true; pid = $PID; warm = $true; stamp = $script:ScriptStamp } }
    'batch'      { return (Invoke-Batch $a) }
    'display'    { return (Do-Display) }
    'screenshot' { return (Do-Screenshot $a) }
    'windows'    { return (Do-Windows $a) }
    'mouse'      { return (Do-Mouse $a) }
    'keyboard'   { return (Do-Keyboard $a) }
    'clipboard'  { return (Do-Clipboard $a) }
    'process'    { return (Do-Process $a) }
    'uia'        { return (Do-Uia $a) }
    default      { throw "unknown action '$action'" }
  }
}

# ---------------------------------------------------------------------- serve

function Start-Daemon {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()
  $actual = [int]$listener.LocalEndpoint.Port
  if ($PortFile) { Write-Utf8File $PortFile "$actual" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $last = Get-Date
  $stop = $false
  while (-not $stop) {
    if (-not $listener.Pending()) {
      Start-Sleep -Milliseconds 40
      if ($IdleMs -gt 0 -and ((Get-Date) - $last).TotalMilliseconds -gt $IdleMs) { break }
      continue
    }
    $client = $listener.AcceptTcpClient()
    $last = Get-Date
    $ns = $null
    try {
      $client.ReceiveTimeout = 300000
      $client.SendTimeout = 300000
      $ns = $client.GetStream()
      $ms = New-Object System.IO.MemoryStream
      $buf = New-Object byte[] 65536
      while ($true) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        if ($buf[$n - 1] -eq 10) { break }
      }
      $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
      $ms.Dispose()
      $resp = '{"ok":false,"error":"empty request"}'
      if ($raw) {
        $req = $null
        try { $req = $raw | ConvertFrom-Json } catch { $req = $null }
        if ($null -eq $req) {
          $resp = '{"ok":false,"error":"request is not valid JSON"}'
        } else {
          $act = [string]$req.action
          if ($act -eq 'shutdown') {
            $resp = '{"ok":true,"action":"shutdown"}'
            $stop = $true
          } else {
            try { $resp = To-JsonText (Invoke-Action $act $req) }
            catch { $resp = To-JsonText ([ordered]@{ ok = $false; action = $act; error = $_.Exception.Message }) }
          }
        }
      }
      $bytes = $enc.GetBytes($resp + "`n")
      $ns.Write($bytes, 0, $bytes.Length)
      $ns.Flush()
    } catch {
      # A broken client must never take the daemon down.
    } finally {
      try { $client.Close() } catch { }
    }
  }
  try { $listener.Stop() } catch { }
}

# ----------------------------------------------------------------------- main

if ($Action -eq 'serve') {
  Start-Daemon
  exit 0
}

$A = $null
if ($ArgsJsonFile -and (Test-Path -LiteralPath $ArgsJsonFile)) {
  $raw = [System.IO.File]::ReadAllText($ArgsJsonFile, [System.Text.Encoding]::UTF8)
  if ($raw -and $raw.Trim()) { $A = $raw | ConvertFrom-Json }
}

$result = $null
try {
  $result = Invoke-Action $Action $A
} catch {
  $result = [ordered]@{ ok = $false; action = $Action; error = $_.Exception.Message }
}
if (-not $OutFile) { $OutFile = Join-Path $env:TEMP 'dsh-computer-use-out.json' }
Write-Utf8File $OutFile (To-JsonText $result)
exit 0
