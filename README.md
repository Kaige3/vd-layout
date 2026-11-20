# vd-layout — Windows 虚拟桌面 / 窗口布局快照与恢复

记录「哪个窗口在哪个虚拟桌面」，重启后一键还原（含 IDEA / PyCharm / WebStorm 的项目窗口）。

- 纯 PowerShell，零依赖（用 Win32 + Windows 虚拟桌面 COM 接口）
- 单文件：`vd-layout.ps1`
- 快照文件：`vd.json`

## 用法

```powershell
# 查看当前桌面和窗口分布
powershell -NoProfile -File .\vd-layout.ps1 list

# 保存快照（把当前布局写进 vd.json）
powershell -NoProfile -File .\vd-layout.ps1 snapshot -Path .\vd.json

# 恢复布局：补齐桌面 → 移动已存在的窗口 → 启动缺失应用 → 等窗口出现并排布
powershell -NoProfile -File .\vd-layout.ps1 restore -Path .\vd.json -LaunchMissing -ReturnToFirst

# 手动移动单个窗口到指定桌面（桌面编号从 1 开始）
powershell -NoProfile -File .\vd-layout.ps1 move -Hwnd <窗口句柄> -Desktop <编号>
```

参数：

| 参数 | 作用 |
|------|------|
| `-Path` | 快照文件路径（默认 `vd-layout.json`） |
| `-LaunchMissing` | 启动快照里缺失的应用，并等待窗口出现后按快照排布 |
| `-ReturnToFirst` | 恢复完成后切回桌面 1 |

## 项目路径怎么识别的

JetBrains 系 IDE（IDEA / PyCharm / WebStorm …）的项目路径有三层回退：

1. **窗口标题里的 `[C:/path]`**（最准）——在 IDEA 里开启
   `Settings → Appearance & Behavior → Appearance → 勾选 "Show full path in window title"`，
   之后标题会直接带完整路径，脚本用一条正则取出。
2. **`recentProjects.xml` 精确匹配**——读
   `%APPDATA%\JetBrains\<产品>\options\recentProjects.xml`，用窗口标题匹配 `frameTitle`，
   取对应 `key`（`$USER_HOME$` 会替换成真实用户目录）。注意该文件是**无 BOM 的 UTF-8**，
   PowerShell 5.1 必须用 `-Encoding UTF8` 读，否则中文/破折号会乱码导致匹配失败。
3. **规范化标题匹配**——把破折号、空白统一后再匹配，兜住标题格式微差。

`projectPath` 为空且进程是 JetBrains IDE 的窗口（如 IDEA 的 LightEdit 单文件模式）会被判定为
内部工作区，**不启动、也不计入「缺失」**。

## 已知限制

| 情况 | 原因 |
|------|------|
| 文件资源管理器（explorer）恢复不了具体文件夹 | explorer 是单进程 shell，命令行不带文件夹路径，标题里也只有文件夹名 |
| 浏览器标签页 | 标签页状态在浏览器自己手里，不体现在窗口/命令行 |
| 无项目路径的 JetBrains 窗口 | LightEdit 模式不在任何配置里记录路径 |
| 单实例 IDE 多项目的启动节奏 | IDEA 冷启动约 15~20 秒；脚本对首个项目等 20 秒、后续项目等 5 秒，避免「打开项目」信号被丢弃 |

## 注意

- 移动窗口用公开的 `IVirtualDesktopManager.MoveWindowToDesktop`；
  枚举/建桌/切桌用未公开的 `IVirtualDesktopManagerInternal`，**只支持 Win11 24H2/25H2（build 26100+）**。
- `restore` 会真实启动程序、移动窗口；`list` / `snapshot` 是只读的。
