# vd-layout.ps1 — Windows 虚拟桌面 ↔ 窗口布局快照 / 恢复（最小 PoC）
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File vd-layout.ps1 list
#   powershell -NoProfile -ExecutionPolicy Bypass -File vd-layout.ps1 snapshot [-Path vd-layout.json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File vd-layout.ps1 restore  [-Path vd-layout.json] [-LaunchMissing] [-ReturnToFirst]
#   powershell -NoProfile -ExecutionPolicy Bypass -File vd-layout.ps1 move -Hwnd <句柄> -Desktop <编号,从1开始>
#
# 说明:
#   - 只读动作(snapshot/list)安全; restore 会移动窗口 / 新建虚拟桌面 / (可选)启动程序。
#   - 移动窗口用公开的 IVirtualDesktopManager.MoveWindowToDesktop;
#     枚举/建桌/切桌用未公开的 IVirtualDesktopManagerInternal(布局针对 Win11 24H2/25H2, build 26100+)。

param(
  [Parameter(Position = 0)][ValidateSet('snapshot', 'restore', 'list', 'move')]
  [string]$Action = 'list',
  [string]$Path = 'vd-layout.json',
  [switch]$LaunchMissing,
  [switch]$ReturnToFirst,
  [long]$Hwnd = 0,
  [int]$Desktop = 0
)

$ErrorActionPreference = 'Stop'

# ---------- 内联 C#: 虚拟桌面 COM 接口 + 窗口枚举 ----------
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections;
using System.Runtime.InteropServices;

namespace VdLayout
{
    public static class Guids
    {
        public static readonly Guid CLSID_ImmersiveShell = new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239");
        public static readonly Guid CLSID_VirtualDesktopManagerInternal = new Guid("C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B");
        public static readonly Guid CLSID_VirtualDesktopManager = new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A");
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIInspectable), Guid("372E1D3B-38D3-42E4-A15B-8AB2B178F513")]
    public interface IApplicationView { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("1841C6D7-4F9D-42C0-AF41-8747538F10E5")]
    public interface IApplicationViewCollection
    {
        int GetViews(out IObjectArray array);
        int GetViewsByZOrder(out IObjectArray array);
        int GetViewsByAppUserModelId(string id, out IObjectArray array);
        int GetViewForHwnd(IntPtr hwnd, out IApplicationView view);
        int GetViewForApplication(object application, out IApplicationView view);
        int GetViewForAppUserModelId(string id, out IApplicationView view);
        int GetViewInFocus(out IntPtr view);
        int Unknown1(out IntPtr view);
        void RefreshCollection();
        int RegisterForApplicationViewChanges(object listener, out int cookie);
        int UnregisterForApplicationViewChanges(int cookie);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("3F07F4BE-B107-441A-AF0F-39D82529072C")]
    public interface IVirtualDesktop
    {
        bool IsViewVisible(IApplicationView view);
        Guid GetId();
    }

    // Win11 24H2 / 25H2 布局(共 22 个方法, 顺序必须精确)。仅调用前 5 个 + SwitchDesktop。
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("53F5CA0B-158F-4124-900C-057158060B27")]
    public interface IVirtualDesktopManagerInternal
    {
        int GetCount();
        void MoveViewToDesktop(IApplicationView view, IVirtualDesktop desktop);
        bool CanViewMoveDesktops(IApplicationView view);
        IVirtualDesktop GetCurrentDesktop();
        void GetDesktops(out IObjectArray desktops);
        [PreserveSig] int GetAdjacentDesktop(IVirtualDesktop from, int direction, out IVirtualDesktop desktop);
        void SwitchDesktop(IVirtualDesktop desktop);
        void SwitchDesktopAndMoveForegroundView(IVirtualDesktop desktop);
        IVirtualDesktop CreateDesktop();
        void MoveDesktop(IVirtualDesktop desktop, int nIndex);
        void RemoveDesktop(IVirtualDesktop desktop, IVirtualDesktop fallback);
        IVirtualDesktop FindDesktop(ref Guid desktopid);
        void GetDesktopSwitchIncludeExcludeViews(IVirtualDesktop desktop, out IObjectArray unknown1, out IObjectArray unknown2);
        void SetDesktopName(IVirtualDesktop desktop, string name);
        void SetDesktopWallpaper(IVirtualDesktop desktop, string path);
        void UpdateWallpaperPathForAllDesktops(string path);
        void CopyDesktopState(IApplicationView pView0, IApplicationView pView1);
        void CreateRemoteDesktop(string path, out IVirtualDesktop desktop);
        void SwitchRemoteDesktop(IVirtualDesktop desktop, IntPtr switchtype);
        void SwitchDesktopWithAnimation(IVirtualDesktop desktop);
        void GetLastActiveDesktop(out IVirtualDesktop desktop);
        void WaitForAnimationToComplete();
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B")]
    public interface IVirtualDesktopManager
    {
        bool IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow);
        Guid GetWindowDesktopId(IntPtr topLevelWindow);
        void MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9")]
    public interface IObjectArray
    {
        void GetCount(out int count);
        void GetAt(int index, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object obj);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("6D5140C1-7436-11CE-8034-00AA006009FA")]
    public interface IServiceProvider10
    {
        [return: MarshalAs(UnmanagedType.IUnknown)]
        object QueryService(ref Guid service, ref Guid riid);
    }

    public static class Vd
    {
        private static IVirtualDesktopManagerInternal internalMgr;
        private static IVirtualDesktopManager publicMgr;
        private static IApplicationViewCollection appViewCollection;

        public static void Init()
        {
            var shell = (IServiceProvider10)Activator.CreateInstance(Type.GetTypeFromCLSID(Guids.CLSID_ImmersiveShell));
            internalMgr = (IVirtualDesktopManagerInternal)shell.QueryService(Guids.CLSID_VirtualDesktopManagerInternal, typeof(IVirtualDesktopManagerInternal).GUID);
            publicMgr = (IVirtualDesktopManager)Activator.CreateInstance(Type.GetTypeFromCLSID(Guids.CLSID_VirtualDesktopManager));
            appViewCollection = (IApplicationViewCollection)shell.QueryService(typeof(IApplicationViewCollection).GUID, typeof(IApplicationViewCollection).GUID);
        }

        public static IVirtualDesktop GetDesktop(int index)
        {
            IObjectArray desktops;
            internalMgr.GetDesktops(out desktops);
            object obj;
            Guid iid = typeof(IVirtualDesktop).GUID;
            desktops.GetAt(index, ref iid, out obj);
            Marshal.ReleaseComObject(desktops);
            return (IVirtualDesktop)obj;
        }

        public static int GetDesktopCount() { return internalMgr.GetCount(); }

        public static string GetDesktopId(int index) { return GetDesktop(index).GetId().ToString(); }

        public static void CreateDesktop() { internalMgr.CreateDesktop(); }

        public static void SwitchToDesktop(int index) { internalMgr.SwitchDesktop(GetDesktop(index)); }

        public static string GetWindowDesktopId(long hwnd)
        {
            try { return publicMgr.GetWindowDesktopId(new IntPtr(hwnd)).ToString(); }
            catch { return ""; }
        }

        // 移动窗口到指定桌面(0 起始索引)。先试公开 MoveWindowToDesktop, 失败则回退内部 MoveViewToDesktop。
        public static void MoveWindow(long hwnd, int desktopIndex)
        {
            IVirtualDesktop desktop = GetDesktop(desktopIndex);
            try
            {
                Guid g = desktop.GetId();
                publicMgr.MoveWindowToDesktop(new IntPtr(hwnd), ref g);
                return;
            }
            catch { }
            IApplicationView view;
            appViewCollection.GetViewForHwnd(new IntPtr(hwnd), out view);
            internalMgr.MoveViewToDesktop(view, desktop);
        }

        // 枚举所有可见顶层窗口。注意: 不能用 DWMWA_CLOAKED 过滤 —— Windows 会把
        // 非当前虚拟桌面上的窗口也标记为 cloaked, 过滤掉就会丢光其它桌面的窗口。
        // 只按 IsWindowVisible + 标题非空 + 类名(系统壳) 过滤; 桌面归属交给调用方按 GUID 判定。
        // 返回 ArrayList<Hashtable>, 键: hwnd(long) pid(int) title class desktop(Guid 字符串, 空=取不到)。
        public static ArrayList EnumTopWindows()
        {
            var list = new ArrayList();
            Win32.EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (!Win32.IsWindowVisible(h)) return true;

                int tlen = Win32.GetWindowTextLength(h);
                if (tlen == 0) return true;

                var title = new StringBuilder(tlen + 1);
                Win32.GetWindowText(h, title, title.Capacity);

                var cls = new StringBuilder(256);
                Win32.GetClassName(h, cls, 256);
                if (IsSystemWindow(cls.ToString())) return true;

                uint pid;
                Win32.GetWindowThreadProcessId(h, out pid);

                string dg = publicMgr != null ? GetWindowDesktopId(h.ToInt64()) : "";

                var ht = new Hashtable();
                ht["hwnd"] = h.ToInt64();
                ht["pid"] = (int)pid;
                ht["title"] = title.ToString();
                ht["class"] = cls.ToString();
                ht["desktop"] = dg;
                list.Add(ht);
                return true;
            }, IntPtr.Zero);
            return list;
        }

        private static readonly string[] SkipClasses = new string[] {
            "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
            "Windows.UI.CompositionDesktopWindowContentBridge", "DV2ControlHost",
            "XamlExplorerHostIslandWindow", "CiceroUIWndFrame", "CicMarshalWnd",
            "MSCTFIME UI", "IME", "tooltips_class32", "Auto-Suggest Dropdown"
        };

        private static bool IsSystemWindow(string cls)
        {
            for (int i = 0; i < SkipClasses.Length; i++)
                if (String.Equals(SkipClasses[i], cls, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }

    public static class Win32
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
    }
}
'@

# ---------- 工具函数 ----------
function Initialize-Vd {
  try {
    [VdLayout.Vd]::Init()
  } catch {
    Write-Error "虚拟桌面 COM 接口初始化失败(可能当前系统版本与 24H2/25H2 布局不匹配): $($_.Exception.Message)"
    exit 1
  }
}

# 进程信息缓存: pid -> @{ name; path; cmdline }
$script:ProcCache = @{}
function Get-ProcInfo([int]$wpid) {
  if (-not $script:ProcCache.ContainsKey($wpid)) {
    $name = ''; $path = ''; $cmdline = ''
    $p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
    if ($p) {
      $name = $p.ProcessName
      try { $path = $p.Path } catch { $path = '' }
      try { $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$wpid" -ErrorAction Stop).CommandLine } catch { $cmdline = '' }
    }
    $script:ProcCache[$wpid] = @{ name = $name; path = $path; cmdline = $cmdline }
  }
  return $script:ProcCache[$wpid]
}

# 标题规范化: 统一各种破折号/连字符为 '-', 折叠空白, 转小写(用于模糊匹配)
function Normalize-Title([string]$s) {
  if (-not $s) { return '' }
  return (($s -replace '[‐-―]', '-') -replace '\s+', ' ').Trim().ToLowerInvariant()
}

# 读取所有 JetBrains 系 recentProjects.xml, 建立 "标题 -> 项目完整路径" 两级索引(精确 + 规范化)
function Get-JetBrainsProjectMap {
  $exact = @{}   # 精确标题 -> 路径
  $norm  = @{}   # 规范化标题 -> 路径
  $ts    = @{}   # 标题 -> 最近激活时间戳(同名去歧义)
  $userHome = $env:USERPROFILE
  foreach ($root in @("$env:APPDATA\JetBrains", "$env:LOCALAPPDATA\JetBrains")) {
    if (-not (Test-Path $root)) { continue }
    foreach ($dir in (Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)) {
      $xmlPath = Join-Path $dir.FullName 'options\recentProjects.xml'
      if (-not (Test-Path $xmlPath)) { continue }
      try {
        [xml]$xml = Get-Content -Raw -Path $xmlPath -Encoding UTF8
        foreach ($e in $xml.SelectNodes('//entry')) {
          $key = [string]$e.GetAttribute('key')
          $meta = $e.SelectSingleNode('.//RecentProjectMetaInfo')
          if (-not $meta) { continue }
          $ft = [string]$meta.GetAttribute('frameTitle')
          if (-not $ft) { $ft = Split-Path -Leaf $key }   # 无 frameTitle 时用项目名(路径最后一段)
          if (-not ($key -and $ft)) { continue }
          if ($key -match '\$APPLICATION_') { continue }  # 占位符(如 $APPLICATION_CONFIG_DIR$)跳过
          $path = $key.Replace('$USER_HOME$', $userHome).Replace('/', '\')
          # 激活时间戳: 同名/同项目名出现多条路径时, 保留最近激活的那条
          $tsVal = 0
          $tsNode = $meta.SelectSingleNode('.//option[@name="activationTimestamp"]')
          if ($tsNode) { $tsVal = [long]$tsNode.GetAttribute('value') }
          if (-not $exact.ContainsKey($ft) -or $tsVal -ge $ts[$ft]) {
            $exact[$ft] = $path; $ts[$ft] = $tsVal
          }
          $nft = Normalize-Title $ft
          if (-not $norm.ContainsKey($nft) -or $tsVal -ge $ts[$nft]) {
            $norm[$nft] = $path; $ts[$nft] = $tsVal
          }
        }
      } catch { }
    }
  }
  return [pscustomobject]@{ exact = $exact; normalized = $norm }
}

# 获取当前桌面列表: 返回 @( [pscustomobject]@{ index; guid } )
function Get-DesktopList {
  $count = [VdLayout.Vd]::GetDesktopCount()
  $list = @()
  for ($i = 0; $i -lt $count; $i++) {
    $list += [pscustomobject]@{ index = $i + 1; guid = [VdLayout.Vd]::GetDesktopId($i) }
  }
  return $list
}

# 获取当前窗口列表(含进程名/路径/桌面编号): 返回 @( [pscustomobject]@{ hwnd; processName; exePath; title; desktop } )
function Get-WindowList {
  $desktops = Get-DesktopList
  $guidToIndex = @{}
  foreach ($d in $desktops) { $guidToIndex[$d.guid] = $d.index }

  # JetBrains 项目路径映射(标题 -> 完整路径), 每次会话只解析一次
  if (-not $script:JbMap) { $script:JbMap = Get-JetBrainsProjectMap }

  $out = @()
  foreach ($w in [VdLayout.Vd]::EnumTopWindows()) {
    $dg = [string]$w['desktop']
    if (-not $guidToIndex.ContainsKey($dg)) { continue }   # 固定到所有桌面 / 未知 -> 跳过
    $pi = Get-ProcInfo ([int]$w['pid'])
    $title = [string]$w['title']
    $projPath = ''
    $isInternal = $false
    # 1) 窗口标题里直接含完整路径(需 IDEA 开启"在标题显示完整路径", 路径在 [...] 里)
    if ($title -match '\[([A-Za-z]:[\\/][^\]]+)\]') {
      $projPath = $Matches[1].Replace('/', '\')
    }
    # 2) 精确标题匹配
    if (-not $projPath) { $projPath = $script:JbMap.exact[$title] }
    # 3) 规范化标题匹配
    if (-not $projPath) { $projPath = $script:JbMap.normalized[(Normalize-Title $title)] }
    # 4) IDEA 内部工作区(light-edit 等, 在 AppData\...\JetBrains 下)不是用户项目
    if ($projPath -and $projPath -match 'JetBrains[\\/]') { $projPath = ''; $isInternal = $true }
    if (-not $projPath) { $projPath = '' }
    $out += [pscustomobject]@{
      hwnd        = [long]$w['hwnd']
      processName = $pi.name
      exePath     = $pi.path
      commandLine = $pi.cmdline
      projectPath = $projPath
      isInternal  = $isInternal
      title       = $title
      desktop     = [int]$guidToIndex[$dg]
    }
  }
  return $out
}

# 判断进程名是否为 JetBrains IDE(idea/pycharm/webstorm 等, 单实例、可带项目路径启动)
function Test-JetBrainsIde([string]$name) {
  return $name -match '^(idea|pycharm|webstorm|clion|goland|phpstorm|rider|datagrip|rubymine)(64)?$'
}

# 在窗口列表中为快照窗口找匹配(进程名+标题一致; 否则进程名唯一时匹配)。返回匹配项或 $null
function Find-WindowMatch($sw, $curList, $used) {
  # 1) 进程名 + 标题 精确匹配
  foreach ($cw in $curList) {
    if ($used.ContainsKey($cw.hwnd)) { continue }
    if ($cw.processName -eq $sw.processName -and $cw.title -eq $sw.title) { return $cw }
  }
  # 2) 进程名 + 项目路径 匹配(JetBrains 项目窗口, 标题加载期间也能对上)
  if ($sw.projectPath) {
    foreach ($cw in $curList) {
      if ($used.ContainsKey($cw.hwnd)) { continue }
      if ($cw.processName -eq $sw.processName -and $cw.projectPath -and $cw.projectPath -eq $sw.projectPath) { return $cw }
    }
  }
  # 3) 进程名唯一时匹配
  $same = @($curList | Where-Object { (-not $used.ContainsKey($_.hwnd)) -and $_.processName -eq $sw.processName })
  if ($same.Count -eq 1) { return $same[0] }
  return $null
}

# ---------- 动作 ----------
switch ($Action) {

  'list' {
    Initialize-Vd
    $desktops = Get-DesktopList
    Write-Host ("虚拟桌面数量: {0}" -f $desktops.Count)
    foreach ($d in $desktops) {
      Write-Host ("桌面 {0}  {1}" -f $d.index, $d.guid)
      $wins = Get-WindowList | Where-Object { $_.desktop -eq $d.index }
      foreach ($w in $wins) {
        $line = ("    [{0}] {1}" -f $w.processName, $w.title)
        if ($w.projectPath) { $line += "  ->  " + $w.projectPath }
        Write-Host $line
      }
    }
  }

  'snapshot' {
    Initialize-Vd
    $desktops = Get-DesktopList
    $wins = Get-WindowList | Sort-Object desktop, processName, title
    $snap = [ordered]@{
      version      = 1
      createdAt    = (Get-Date).ToString('o')
      desktopCount = $desktops.Count
      desktops     = @($desktops)
      windows      = @($wins)
    }
    $snap | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding utf8
    Write-Host ("已保存快照: {0}  (桌面 {1} 个, 窗口 {2} 个)" -f (Resolve-Path $Path), $desktops.Count, $wins.Count)
    Write-Host '  -- 快照内容(桌面 -> 窗口):'
    foreach ($d in $desktops) {
      Write-Host ("  桌面 {0}:" -f $d.index)
      foreach ($w in ($wins | Where-Object { $_.desktop -eq $d.index })) {
        $line = ("    [{0}] {1}" -f $w.processName, $w.title)
        if ($w.projectPath) { $line += "  ->  " + $w.projectPath }
        Write-Host $line
      }
    }
  }

  'move' {
    if ($Hwnd -le 0 -or $Desktop -lt 1) { Write-Error "move 需要 -Hwnd <句柄> 和 -Desktop <编号, 从1开始>"; exit 1 }
    Initialize-Vd
    $desktops = Get-DesktopList
    if ($Desktop -gt $desktops.Count) { Write-Error ("桌面编号超出范围(当前 {0} 个)" -f $desktops.Count); exit 1 }
    try {
      [VdLayout.Vd]::MoveWindow($Hwnd, ($Desktop - 1))
      Write-Host ("已把窗口 0x{0:X} 移动到桌面 {1}" -f $Hwnd, $Desktop)
    } catch {
      Write-Error ("移动失败: {0}" -f $_.Exception.Message)
      exit 1
    }
  }

  'restore' {
    Initialize-Vd
    if (-not (Test-Path $Path)) { Write-Error "快照文件不存在: $Path"; exit 1 }
    $snap = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $targetCount = [int]$snap.desktopCount
    Write-Host ("快照目标: {0} 个桌面, {1} 个窗口" -f $targetCount, @($snap.windows).Count)

    # 1) 补齐虚拟桌面数量
    $count = [VdLayout.Vd]::GetDesktopCount()
    while ($count -lt $targetCount) {
      [VdLayout.Vd]::CreateDesktop()
      Start-Sleep -Milliseconds 600
      $count = [VdLayout.Vd]::GetDesktopCount()
    }
    Write-Host ("当前桌面 {0} 个(目标 {1})" -f $count, $targetCount)

    # 2) 枚举当前窗口并匹配
    $curList = @(Get-WindowList)
    $used = @{}
    $moved = 0; $already = 0; $missing = @()

    foreach ($sw in @($snap.windows)) {
      $target = [int]$sw.desktop
      if ($target -lt 1 -or $target -gt $targetCount) { continue }
      $match = Find-WindowMatch $sw $curList $used
      if ($match) {
        $used[$match.hwnd] = $true
        if ($match.desktop -ne $target) {
          try {
            [VdLayout.Vd]::MoveWindow($match.hwnd, ($target - 1))
            $moved++
            Write-Host ("  移动 [{0}] {1} -> 桌面 {2}" -f $match.processName, $match.title, $target)
          } catch {
            Write-Warning ("  移动失败 [{0}] {1}: {2}" -f $match.processName, $match.title, $_.Exception.Message)
          }
        } else { $already++ }
      } else {
        $missing += $sw
      }
    }

    # 3) 可选: 启动缺失应用, 并等待其窗口出现后重新排布
    if ($LaunchMissing -and $missing.Count -gt 0) {
      Write-Host ("尝试启动 {0} 个缺失应用..." -f $missing.Count)
      $launched = @{}
      $jetBrainsStarted = @{}   # exePath -> true, 记录该单实例 IDE 是否已启动过
      # 有项目路径的优先启动, 避免同 exe 的"无路径窗口"先启动把"项目路径窗口"顶掉
      foreach ($sw in @($missing | Sort-Object { [bool]$_.projectPath } -Descending)) {
        if ($sw.isInternal) { continue }   # IDEA 内部工作区(LightEdit 等), 不启动
        if ((Test-JetBrainsIde $sw.processName) -and -not $sw.projectPath) { continue }   # 无项目路径的 JetBrains 窗口(LightEdit), 不启动
        if (-not $sw.exePath) { Write-Warning ("  跳过(无 exePath): [{0}] {1}" -f $sw.processName, $sw.title); continue }
        $key = ([string]$sw.exePath).ToLower()
        $proj = [string]$sw.projectPath
        if ($proj) { $key = $key + "|" + $proj.ToLower() }   # 同 exe 的不同项目分别启动
        if ($launched.ContainsKey($key)) { continue }
        $launched[$key] = $true
        try {
          $projPath = [string]$sw.projectPath
          if ($projPath) {
            # 有项目路径(JetBrains 等): 直接带路径启动, 恢复打开的项目
            Start-Process -FilePath $sw.exePath -ArgumentList ('"{0}"' -f $projPath) -ErrorAction Stop | Out-Null
            Write-Host ("  已按项目路径启动 [{0}] -> {1}" -f $sw.processName, $projPath)
            # 单实例 IDE(如 IDEA): 首次启动等冷启动完成(否则后续"打开项目"信号会被丢弃), 之后稍等即可
            if (Test-JetBrainsIde $sw.processName) {
              $exeKey = ([string]$sw.exePath).ToLower()
              if ($jetBrainsStarted.ContainsKey($exeKey)) {
                Start-Sleep -Seconds 5
              } else {
                Start-Sleep -Seconds 20
                $jetBrainsStarted[$exeKey] = $true
              }
            }
          } else {
            $cmdline = [string]$sw.commandLine
            if ($cmdline) {
              # 用原始命令行重新启动(恢复打开的项目/文件)
              $psi = New-Object System.Diagnostics.ProcessStartInfo
              $psi.FileName = $env:ComSpec
              $psi.Arguments = '/d /s /c "' + $cmdline + '"'
              $psi.UseShellExecute = $false
              $psi.CreateNoWindow = $true
              [void][System.Diagnostics.Process]::Start($psi)
              Write-Host ("  已按命令行启动 [{0}]" -f $sw.processName)
            } else {
              Start-Process -FilePath $sw.exePath -ErrorAction Stop | Out-Null
              Write-Host ("  已启动 [{0}]" -f $sw.processName)
            }
          }
        } catch {
          Write-Warning ("  启动失败 [{0}]: {1}" -f $sw.processName, $_.Exception.Message)
        }
      }

      # 主动跳过的窗口(内部工作区/无项目路径的 JetBrains 窗口/无 exe)不计入"缺失"
      $missing = @($missing | Where-Object {
        (-not $_.isInternal) -and
        (-not ((Test-JetBrainsIde $_.processName) -and -not $_.projectPath)) -and
        ([bool]$_.exePath)
      })

      # 轮询等待新窗口出现(只读), 直到全部排布完成或超时
      $waitSeconds = 120
      $deadline = (Get-Date).AddSeconds($waitSeconds)
      while ($missing.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $curList = @(Get-WindowList)
        $remaining = @()
        foreach ($sw in @($missing)) {
          $target = [int]$sw.desktop
          $match = Find-WindowMatch $sw $curList $used
          if ($match) {
            $used[$match.hwnd] = $true
            if ($match.desktop -ne $target) {
              try {
                [VdLayout.Vd]::MoveWindow($match.hwnd, ($target - 1))
                $moved++
                Write-Host ("  移动(新启动) [{0}] {1} -> 桌面 {2}" -f $match.processName, $match.title, $target)
              } catch {
                Write-Warning ("  移动失败 [{0}] {1}: {2}" -f $match.processName, $match.title, $_.Exception.Message)
              }
            } else { $already++ }
          } else {
            $remaining += $sw
          }
        }
        $missing = @($remaining)
      }
      if ($missing.Count -gt 0) {
        Write-Warning ("等待 {0} 秒后仍有 {1} 个窗口未出现(可能启动失败或需登录/弹窗)" -f $waitSeconds, $missing.Count)
      }
    }

    # 4) 可选: 切回桌面 1
    if ($ReturnToFirst -and $targetCount -ge 1) {
      [VdLayout.Vd]::SwitchToDesktop(0)
      Write-Host '已切回桌面 1'
    }

    Write-Host ("恢复完成: 移动 {0} 个, 已在位 {1} 个, 缺失 {2} 个" -f $moved, $already, $missing.Count)
    if ($missing.Count -gt 0 -and -not $LaunchMissing) {
      Write-Host '  提示: 缺失的窗口可加 -LaunchMissing 尝试启动, 或用 -ReturnToFirst 切回桌面 1'
    }
  }
}
