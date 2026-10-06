# UESTC-WiredAnchor: UESTC校园网自动登录工具
By Victor Cartesius

> 校园网自动认证，掉线自动重连，免人工登录

| 项目 | 状态 |
|---|---|
| 版本号 | **1.1.0** |
| 运行环境 | Windows 10 / 11 + **Windows PowerShell 5.1**（系统自带，无第三方依赖） |
| 网络与权限 | 需能访问认证网关；日常**无需管理员**（仅计划任务自启需要） |
| 代码位置 | `main\`（入口 `main\Manage.ps1`） |
| 许可证 | MIT（见 `LICENSE`） |

> **快速跳转**：[开箱即用](#s0) · [目录](#toc) · [配置指南](#s7) · [常见问题与排错](#s10) · [安全说明](#s11) · [已知限制](#s12) · [工程约定](#s13) · [版本与兼容性](#s14)

---

<a id="s0"></a>
## 0. 开箱即用

> 若无特殊说明，所有路径均以**根目录 \UESTC-WiredAnchor**（`main` 的父级目录）为准。

解压包用户需解除 Windows 对下载文件的锁定：

```powershell
Get-ChildItem .\main -Recurse -File | Unblock-File
```

启动管理界面：

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1
```

可以见到如下的窗口：
![WiredAnchor Management Interface](https://cartesius.site/wp-content/uploads/WiredAnchor_v1.1.0_UI.webp)

然后在菜单里依次完成以下配置：

| 菜单项 | 主要功能 | 说明 |
|---|---|---|
| `3) SetCredential` | 配置校园网账号及密码 | 密码为**隐藏输入**，将保存至用户环境变量；一般同统一身份认证，若开通校园宽带请咨询运营商是否可接入 |
| `5) SetLocate` | 区域选择 | `Teaching`（教学区，默认）或 `Dorm`（宿舍区） |
| `6) TestLogin` | 单次登录尝试 | 出现 `connected` 即成功 |
| `7) Install` | 开机自启 | 之后每次登录 Windows 自动运行，无需人工维护 |
| `9) Enable` | 允许开机自启 | 之后每次登录 Windows 自动运行，无需人工维护 |
| `11) Start` | 启动 Keep-Alive 守护进程 | 立即启动守护进程，本次登录即可使用 |

**成功标志**：`6) TestLogin` 打印 `ip x.x.x.x` 与 `connected`；尝试手动断网后 2 分钟内再次认证成功。

**若未成功**，见 §10；或先运行一次
`powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action Status` 查看状态。

> 如不使用交互式菜单，全部功能均提供命令行形式，见 §4.2。
> 如需彻底移除本工具、恢复原状，见 §5.4。

---

<a id="toc"></a>
## 目录

**日常使用**

- [0. 开箱即用](#s0)
- [1. 功能](#s1)
- [2. 文件目录](#s2)
- [3. 手动方式](#s3)
- [4. 统一管理界面 `Manage.ps1`](#s4) - [4.1 交互式界面](#s4-1) · [4.2 命令行形式](#s4-2) · [4.3 参数](#s4-3)
- [5. 开机自启：安装 / 开关 / 卸载](#s5) - [5.1 三种方式](#s5-1) · [5.2 常用命令](#s5-2) · [5.3 重要提示](#s5-3) · [5.4 彻底移除](#s5-4)
- [6. 手动启停 Keep-Alive](#s6) - [6.1 关闭终端窗口后是否仍会运行？](#s6-1)
- [7. 配置指南：如何修改参数](#s7)
- [8. 日志](#s8)
- [9. 工作原理](#s9) - [9.1 Keep-Alive 状态机](#s9-1) · [9.2 只负责有线网络](#s9-2) · [9.3 登录协议](#s9-3)
- [10. 常见问题与排错](#s10)
- [11. 安全说明](#s11)
- [12. 已知限制](#s12)

**维护（开发者）**

- [13. 工程约定（维护者须知）](#s13)
- [14. 版本与兼容性](#s14) - [14.1 版本历史](#s14-1) · [14.2 契约表面](#s14-2) · [14.3 版本号规则](#s14-3) · [14.4 维护与贡献](#s14-4)

<!-- 目录使用显式锚点：每个标题上方有一行 <a id> 标记（子节为 sN-M，目录自身为 toc）。
     重命名或移动章节时，请同步"锚点 + 目录链接 + 顶部快速跳转"这三处。 -->

---

<a id="s1"></a>
## 1. 功能简介

当计算机通过有线网络接入校园网时，**自动完成认证，并在检测到掉线时自动重新认证**。

功能框图

![WiredAnchor Functional Block Diagram](https://cartesius.site/wp-content/uploads/WiredAnchor_v1.1.0_FBD-scaled.webp)
---

<a id="s2"></a>
## 2. 文件目录

```
main\
├── Manage.ps1        ← 【推荐入口】统一管理界面（配置 / 自启 / 启停 / 状态 / 日志）
├── Login.ps1         ← 入口：登录一次
├── KeepAlive.ps1     ← 入口：常驻 Keep-Alive
├── SrunConfig.ps1    ← 配置权威：区域预设、网关、运营商、日志目录、环境变量名、守护状态标记
├── SrunLogin.ps1     ← 登录流程（网关身份校验 → get_challenge → 加密 → 提交认证）
├── SrunCrypto.ps1    ← 加密算法库（XXTEA / 自定义字母表 Base64 / MD5 / SHA1，纯计算）
├── SrunKeepAlive.ps1 ← Keep-Alive 逻辑（探测、身份门禁、判定、冷却、退避重连）与参数表
├── Start-Hidden.vbs  ← 无窗口启动器（自启与 `Start` 均经由它启动 Keep-Alive）
└── logs\             ← 运行日志（按天生成 YYYY-MM-DD.log）
```

调用链：`Manage.ps1` →（`Login.ps1` / `KeepAlive.ps1`）→ `SrunLogin.ps1` → `SrunCrypto.ps1` + `SrunConfig.ps1`。

仓库根目录（`main\` 的父级）另有：`README.md`（本说明书）、`LICENSE`（MIT 许可证）、`CONTRIBUTING.md`（贡献指南）、`SECURITY.md`（安全政策）。

**日常只需要用 `Manage.ps1`**，其余文件由它调用。

---

<a id="s3"></a>
## 3. 手动方式

> 日常请使用 §0 的菜单流程；本节为等价的手动方式。

**配置登录信息**（等价于菜单 `3) SetCredential`）：

```powershell
[Environment]::SetEnvironmentVariable('UESTC_NUMBER', '用户名', 'User')
[Environment]::SetEnvironmentVariable('UESTC_PASSWD', '密码', 'User')
```

| 变量名 | 含义 | 必填 |
|---|---|---|
| `UESTC_NUMBER` | 一般为统一身份认证的账号 | 是 |
| `UESTC_PASSWD` | 对应的密码 | 是 |
| `UESTC_LOCATE` | 区域覆盖：`Teaching`（教学区）/ `Dorm`（宿舍区） | 可选 |

> 环境变量设置后，须**打开新的终端会话**方能读取；当前会话可使用 `Manage.ps1` 的 `SetCredential`（其会一并刷新当前会话）。
> 清除已保存的账号密码：`Manage.ps1 -Action ClearCredential`。

**不经菜单直接运行**：

单次登录：

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Login.ps1
```

前台常驻（实时输出）：

```powershell
powershell -ExecutionPolicy Bypass -File .\main\KeepAlive.ps1
```

**执行策略**：本说明书的命令均带 `-ExecutionPolicy Bypass`；如需长期免除该参数，可放开当前用户：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

<a id="s4"></a>
## 4. 统一管理界面 `Manage.ps1`

<a id="s4-1"></a>
### 4.1 交互式界面

提供交互式界面以便统一管理，运行 `Manage.ps1` 后键入选项对应的数字并按 `Enter` 即可。

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1
```

主菜单：

```
UESTC-WiredAnchor

   1) Status           credentials, area, gateway, autostart, daemon
   2) ShowConfig       print the effective configuration
   3) SetCredential    store student ID and password
   4) ClearCredential  remove the stored credentials
   5) SetLocate        set area (Teaching/Dorm)
   6) TestLogin        log in once and report the result
   7) Install          install autostart at logon
   8) Uninstall        remove autostart
   9) Enable           enable autostart
  10) Disable          disable autostart
  11) Start            start the keep-alive daemon
  12) Stop             stop the keep-alive daemon
  13) Logs             show the tail of the newest log
   0) exit
```

<a id="s4-2"></a>
### 4.2 命令行形式

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action <Action>
```

| Action | 功能 |
|---|---|
| `Status` | 查看状态：凭据是否就绪、当前区域 / 网关、自启方式、守护进程是否运行、日志路径 |
| `ShowConfig` | 打印生效配置（区域来源、网关、`ac_id`、域名、环境变量名） |
| `SetCredential` | 交互式录入账号密码并写入用户环境变量 |
| `ClearCredential` | 清除用户环境变量里的账号密码 |
| `SetLocate` | 设置区域（配合 `-Locate <区域名>`，或交互输入） |
| `TestLogin` | 调用 `Login.ps1` 登录一次 |
| `Install` / `Uninstall` | 安装 / 卸载"登录自启" |
| `Enable` / `Disable` | 开启 / 关闭已安装的自启 |
| `Start` / `Stop` | 立刻启动 / 停止 Keep-Alive 进程 |
| `Logs` | 显示当天日志末尾（`-LogLines N` 控制行数） |
| `Menu` | 交互式菜单（默认） |

> 动作清单以代码为准：`$script:SrunActions` 表同时生成菜单与命令行分发，上表仅供阅读。

<a id="s4-3"></a>
### 4.3 参数

| 参数 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `-Action` | 见上表 | `Menu` | 要执行的动作 |
| `-Method` | `Auto` / `Task` / `Run` | `Auto` | 自启方式（见第 5 节） |
| `-Locate` | 区域名，取自 `SrunConfig.ps1` 的 `$script:SrunPresets` 键（默认 `Teaching` / `Dorm`） | — | 配合 `SetLocate`；大小写不敏感，非法值会被拒绝并列出合法取值 |
| `-LogLines` | 整数 `1`–`1000` | `20` | `Logs` 显示的行数 |

---

<a id="s5"></a>
## 5. 开机自启：安装 / 开关 / 卸载

<a id="s5-1"></a>
### 5.1 三种方式

| `-Method` | 机制 | 需要管理员 | 说明 |
|---|---|---|---|
| `Task` | Windows 计划任务（登录触发、**无窗口**） | **需要** | 更健壮，适合位置固定的机器。注意：任务里虽配置了"失败重启 3 次"，但当前**实际不会触发**（原因见 §12） |
| `Run` | 当前用户 `HKCU\...\CurrentVersion\Run` 登录项 | **不需要** | 兼容性最好，普通用户即可使用 |
| `Auto`（默认） | 先尝试 `Task`，被拒则自动改用 `Run` | 视情况 | 推荐 |

<a id="s5-2"></a>
### 5.2 常用命令

```powershell
$M = ".\main\Manage.ps1"

# 安装（默认 Auto：可创建任务时创建任务，否则使用 Run）
powershell -ExecutionPolicy Bypass -File $M -Action Install

# 强制免管理员的 Run 方式
powershell -ExecutionPolicy Bypass -File $M -Action Install -Method Run

# 强制计划任务（需在“以管理员身份运行”的 PowerShell 里）
powershell -ExecutionPolicy Bypass -File $M -Action Install -Method Task

# 临时关闭 / 重新开启（不卸载）
powershell -ExecutionPolicy Bypass -File $M -Action Disable
powershell -ExecutionPolicy Bypass -File $M -Action Enable

# 彻底卸载
powershell -ExecutionPolicy Bypass -File $M -Action Uninstall
```

`Status` 的 `autostart` 一行为以下三者之一：

```
scheduled task (Ready)
Run entry (logon, no admin)
not installed
```

<a id="s5-3"></a>
### 5.3 重要提示

- 自启为**"登录时"触发**，而非开机即启动。若需要在**无人登录**的情况下也运行，必须使用 `Task` 方式并由管理员改为"不管用户是否登录都运行"（需存储凭据或使用系统账户）。
- `Run` 方式是"存在即启用、移除即关闭"，因此其 `Disable` 等同于临时移除（`Enable` 会重新写入）。
- `Task` 方式若报 `Access is denied`，说明当前不具备管理员权限，改用 `-Method Run` 即可。
- **安装自启前，凭据与区域必须已"持久化"**：自启项在登录时的进程中无法读取仅在**当前会话**设置的变量。若不满足，`Install` 会**直接拒绝**并说明原因（见 §10），以避免守护进程静默启动失败。通过菜单第 3 项 `SetCredential` 录入即为持久化。

<a id="s5-4"></a>
### 5.4 彻底移除（恢复原状）

不再需要本工具时，三步即可恢复原状：

```powershell
$M = ".\main\Manage.ps1"

# 1) 卸载自启（计划任务与 Run 项都会被清掉）
powershell -ExecutionPolicy Bypass -File $M -Action Uninstall

# 2) 清除已保存的账号 / 密码（注册表 + 当前会话）
powershell -ExecutionPolicy Bypass -File $M -Action ClearCredential

# 3) 清除区域覆盖（只有设过才需要）
[Environment]::SetEnvironmentVariable('UESTC_LOCATE', $null, 'User')
```

**确认清理完成**：

```powershell
powershell -ExecutionPolicy Bypass -File $M -Action Status
# 预期输出：  autostart   not installed
#            credentials not set (use SetCredential)
#            daemon      not running
```

> 第 3 步仅清除已在环境变量中设置的覆盖值；`SrunConfig.ps1` 中的默认区域不受影响。
> 除上述环境变量、自启项（Run 项 / 计划任务）与 `main\logs` 下的日志外，
> 本工具**不写入其他注册表位置、不安装服务、不留下驻留进程**。最后直接删除 `UESTC-WiredAnchor` 文件夹即可。

---

<a id="s6"></a>
## 6. 手动启停 Keep-Alive

```powershell
$M = ".\main\Manage.ps1"

# 立即启动 Keep-Alive（无窗口；已安装自启则启动计划任务，否则直接启动后台进程）
powershell -ExecutionPolicy Bypass -File $M -Action Start

# 停止 Keep-Alive
powershell -ExecutionPolicy Bypass -File $M -Action Stop
```

> `Stop` 以**强制终止**方式停止（守护进程不提供优雅停止信号）。
> `Start` 具有**幂等**性：若已处于运行状态，将提示 `keep-alive already running (pid …)` 并跳过，不会再启动第二个进程。
> `Start` 还会在启动守护进程之前，将**用户环境变量中已有的凭据**同步至当前会话；因此，即使终端会话早于凭据设置，也能正常启动，无需重开终端。
>
> **注意**：守护进程仅在启动时读取一次配置（即启动时刻的区域、网关与密码）。因此，修改区域或密码后，
> **正在运行的实例仍沿用旧值**；须先 `Stop` 再 `Start` 方可使新配置生效（`SetLocate` / `SetCredential` /
> `ClearCredential` 执行成功后，界面会对此予以提示）。

<a id="s6-1"></a>
### 6.1 关闭终端窗口后是否仍会运行？

**会。** Keep-Alive 进程由 `Start-Hidden.vbs` 以「窗口样式 0」启动，自创建起即无可见窗口，且不依附于任何终端会话，因此关闭终端不影响其运行。

**验证方法**（关闭终端后重新打开一个）：

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action Status
#   daemon 一行应显示： pid xxxxx
```

> 未采用 `powershell.exe -WindowStyle Hidden` 的原因：该参数仅能隐藏已经创建的控制台，守护进程自身的控制台仍会出现，而关闭它即终止 Keep-Alive。`Start-Hidden.vbs` 将「窗口样式 0」直接写入子进程启动信息，控制台自创建起即隐藏，不存在可关闭的窗口。

---

<a id="s7"></a>
## 7. 配置指南：如何修改参数

本工具将与维护相关的可调项集中放置，**每项仅有一个定义点**，修改一处即全局生效。

| 想改什么 | 改哪里 | 当前默认值 |
|---|---|---|
| 区域（教学区 / 宿舍区） | `SrunConfig.ps1` 顶部 `$script:SrunPresets` 的**键**（`$script:SrunDefaultLocate` 定默认；环境变量 `UESTC_LOCATE` 可覆盖） | `'Teaching'` |
| 网关地址 / `ac_id` | `SrunConfig.ps1` 的 `$script:SrunPresets` 表（**成对**定义，不应拆开） | 教学区 `10.253.0.237` + `ac_id=1`（**覆盖整个教学区，含各教学楼，并非仅主楼**）；宿舍区 `10.253.0.235` + `ac_id=3` |
| 运营商后缀 | `SrunConfig.ps1` 的 `$script:SrunDomain` | `@dx-uestc`（校园网）；电信 `@dx`；移动 `@cmcc` |
| 日志目录 | `SrunConfig.ps1` 的 `$script:SrunLogDir`（写日志与读日志共用同一处） | `main\logs` |
| 环境变量名（账号 / 密码 / 区域） | `SrunConfig.ps1` 的 `$script:SrunEnvNumber` / `$script:SrunEnvPasswd` / `$script:SrunEnvLocate` | `UESTC_NUMBER` / `UESTC_PASSWD` / `UESTC_LOCATE` |
| 探测用哪个网址 / 期望内容 | `SrunKeepAlive.ps1` 的 `$script:SrunProbe`（网址与期望内容**成对**） | `http://www.msftconnecttest.com/connecttest.txt` / `Microsoft Connect Test` |
| 探测频率、掉线阈值、重试间隔、重连上限与冷却、超时 | `SrunKeepAlive.ps1` 顶部 `$script:SrunKeepAliveConfig` 表 | 见下表 |
| 账号 / 密码 | 用户环境变量 `UESTC_NUMBER` / `UESTC_PASSWD` | — |

> 新增区域时，只需在 `$script:SrunPresets` 中增加一行：菜单、`Status`、`SetLocate` 的合法取值及区域名列表均自动随之更新，它们均由该表派生，不存在其他硬编码。
>
> 生效区域**惰性解析**（`Get-SrunEffectiveLocate`），不做缓存。因此在同一会话中执行 `SetLocate` 后，`Status` 与 `TestLogin` 立即使用新区域，不会出现「状态显示旧值、登录使用新值」的不一致。

> 下表仅为便于阅读的**抄录**，**一切以代码为准**：`Status` 与启动日志显示的是代码中的实际取值。
> 修改 `SrunKeepAlive.ps1` 的 `$script:SrunKeepAliveConfig` 时，请同步更新本表。

**Keep-Alive 参数默认值**（`$script:SrunKeepAliveConfig`）：

| 键 | 默认 | 含义 |
|---|---|---|
| `OnlineInterval` | 30 | 在线时探测间隔（秒） |
| `FailThreshold` | 3 | 连续探测失败几次判定掉线 |
| `DetachedDelay` | 60 | 离网 / 非有线出口时的复查间隔（秒） |
| `RetestDelay` | 3 | 判定掉线前的快速复测间隔（秒） |
| `PostLoginDelay` | 2 | 重连成功后重新探测前等待（秒） |
| `BackoffStart` | 4 | 重连失败后的初始退避（秒） |
| `BackoffFactor` | 2 | 退避倍数 |
| `MaxBackoff` | 60 | 退避上限（秒） |
| `MaxReconnectAttempts` | 5 | 连续重连失败达此次数后进入冷却 |
| `CooldownDelay` | 600 | 冷却期的复核间隔（秒）；冷却期间不发起登录 |
| `ConnectTimeoutMs` | 3000 | 网关可达性探测超时（毫秒）；该值的唯一来源在协议层 `SrunLogin.ps1`，此处引用 |
| `ProbeTimeoutMs` | 5000 | 外网探测连接/读取超时（毫秒） |
| `MaxProbeChars` | 65536 | 探测响应最多读取的字符数（防止伪造响应或门户页面导致内存占用失控） |
| `LogRetentionDays` | 30 | 日志保留天数（守护进程启动时清理更早的日志；`0` 表示永久保留） |

> 登录请求的超时（10 秒）定义于协议层 `SrunLogin.ps1` 的 `$script:SrunLoginTimeoutSec`。

**关键设计**：网关地址与 `ac_id` **成对定义**（切换区域时二者必须同时变更），故封装为「区域预设」，从结构上避免因只修改其中一项而导致的认证失败。

---

<a id="s8"></a>
## 8. 日志

- 位置：`main\logs\YYYY-MM-DD.log`（按天一个文件），同时输出到控制台。
- 仅记录**状态变化**，而非每次探测都写（以避免冗余输出与日志无限增长）。
- 守护进程启动时清理超过保留期的旧日志；若发生删除，会额外记录一行：`removed N log file(s) older than 30 days`（保留天数见 §7 的 `LogRetentionDays`，`0` 表示永久保留）。
- 启动阶段的致命错误记录为：`fatal: cannot start: <原因>`（见 §10）。
- 查看方式：

```powershell
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action Logs -LogLines 30
```

典型日志：

```
[2026-10-04 22:09:00] keep-alive started: gateway http://10.253.0.237, probe http://www.msftconnecttest.com/connecttest.txt
[2026-10-04 22:09:00] settings: loginTimeout=10s, ...
[2026-10-04 22:09:01] online via 211.83.104.243 [state=Online]
[2026-10-04 22:15:12] offline: 3 consecutive failures on 211.83.104.243 - reconnecting [state=Offline]
[2026-10-04 22:15:13] reconnect: ok (ip 211.83.104.243)
[2026-10-04 22:16:00] foreign gateway: identity check failed (client_ip 10.0.0.1 does not match local source 192.168.1.20) - not logging in [state=Foreign]
[2026-10-04 22:26:00] reconnect failed x5 - cooling for 600s [state=Cooling]
[2026-10-04 22:36:00] gateway identity confirmed again on wired outlet - resuming attempts [state=Offline]
```

> 状态变化行尾部的 `[state=<状态>]` 是**机器可读标记**，`Manage.ps1 -Action Status` 的 `state` 一行即由它解析得到。

---

<a id="s9"></a>
## 9. 工作原理

<a id="s9-1"></a>
### 9.1 Keep-Alive 状态机

![WiredAnchor Finite-State Machine](https://cartesius.site/wp-content/uploads/WiredAnchor_v1.1.0_FSM.webp)

| 状态 | 判据 | 行为 |
|---|---|---|
| **Online** | 外网可达 | 静默等待，低频探测 |
| **Offline** | 网关身份通过、外网不通 | 判定掉线 → 重连（失败则指数退避） |
| **Foreign** | 网关地址可连，但身份校验失败 | 判定非校园网 / 门户，只复核，**永不登录** |
| **Cooling** | 身份通过但连续重连失败达上限 | 冷却期内**不登录**，仅周期复核身份 |
| **Detached** | 网关不可达 | 只等待，**不重连**（离网或未接入网线） |
| **Idle** | 出口不是有线网卡 | 主动让出，**不介入**（例如使用 Wi-Fi） |

> 每条状态变化日志行尾部带有机器可读标记 `[state=<状态>]`；`Manage.ps1 -Action Status` 的 `state` 一行据此显示守护进程当前状态。
> 上图为关键迁移的**简化图**：任一状态在检测到网关不可达、或出口非有线时，都会分别转入 `Detached` / `Idle`（详见 `SrunKeepAlive.ps1` 主循环）。

<a id="s9-2"></a>
### 9.2 只负责有线网络

本工具连接网关并读取**系统实际使用的出口源 IP**：当且仅当该 IP 属于**有线网卡**时才接管；若当前使用 Wi-Fi，则进入 `Idle`，不与系统无线连接冲突。

<a id="s9-3"></a>
### 9.3 登录协议

认证流程与官方网页的 JavaScript 实现等价：获取本机 IP → 获取 challenge → 本地加密（XXTEA + 自定义字母表 Base64 + HMAC-MD5 + SHA1）→ 提交认证。因此**无需浏览器**。

登录前先**校验对端身份**：仅当 `get_challenge` 回显的 `client_ip` 与本机有线出口源 IP 一致、且 `challenge` 形态合法时，才会构造并发送任何密码材料；否则进入 `Foreign` 状态，不发送凭据。

---

<a id="s10"></a>
## 10. 常见问题与排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `running scripts is disabled` | 执行策略限制 | 在命令中加入 `-ExecutionPolicy Bypass`，或执行 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `无法加载文件 … 未数字签名` / `… 因为在此系统上禁止运行脚本`（解压后首次运行） | 压缩包解压后，文件被 Windows 标记为"来自 Internet" | 在根目录执行 `Get-ChildItem .\main -Recurse -File \| Unblock-File`；或右键文件 → 属性 → 勾选"解除锁定" |
| `Manage.ps1 is out of sync: …` | `-Action` 的 `ValidateSet` 与动作表不同步 | 属开发期的保护性检查，正常使用不会触发；按提示将两处改为一致即可 |
| `unknown area 'xxx' (expected: ...)` | `UESTC_LOCATE`（或 `-Locate`）指定了预设表中不存在的区域名 | 改用 `SrunConfig.ps1` 的 `$script:SrunPresets` 中的键；报错信息会列出全部合法取值 |
| `credentials are not set (...)` | 当前会话中未设置相应的环境变量 | 重新打开终端；或使用 `Manage.ps1` 的 `SetCredential` |
| 环境变量已设置却读取不到 | 终端会话早于环境变量的设置 | 重新打开终端（`Manage.ps1` 亦会同步当前会话） |
| 登录结果 `sign_error` | 网关响应格式变化或解析异常 | 身份校验或解析失败会抛出 `gateway identity check failed: ...` 等明确错误，按其提示排查 |
| 日志出现 `foreign gateway: identity check failed ...`，或 `Status` 的 `state` 为 `Foreign` | 网关地址可连，但对端不是 UESTC srun 网关（非校园网 / 强制门户 / 地址段撞车） | 属**有意的保护**：工具不会向对端发送任何密码材料。请确认接入的是 UESTC 有线网 |
| `Status` 的 `state` 为 `Cooling` | 身份通过，但连续重连失败达上限（默认 5 次） | 冷却期内不登录；到期且在有线接口上身份复核通过后自动恢复。可先排查网关是否故障 |
| `Install` 报 `Access is denied` | 计划任务需要管理员权限 | 改用 `-Method Run`，或使用 `Auto`（会自动回退） |
| `Install` 提示 `Windows Script Host is unavailable` | 系统通过组策略禁用了 Windows Script Host，无窗口启动器不可用 | 功能仍可正常使用，但登录时窗口可能闪现；若需完全无窗口，改用 `-Method Task` 并由管理员设为"不管用户是否登录都运行" |
| 确认 Keep-Alive 是否在运行 | 无窗口启动后无法直接观察进程 | 执行 `Manage.ps1 -Action Status` 查看 `daemon` 一行，或 `-Action Logs` 查看日志尾部 |
| 可以上网却反复判定掉线 | 探测目标不可达（部分网络会拦截该地址） | 修改 `SrunKeepAlive.ps1` 的 `$script:SrunProbe`（网址与期望内容须成对修改） |
| 使用 Wi-Fi 时完全不介入 | 属**有意设计**（仅管理有线网络） | 如需管理无线连接，本工具不适用 |
| 日志行数很少 | 仅记录状态变化，属正常现象 | 如需更详细的输出，可临时以前台方式运行观察 |
| 出现 `error: cannot start keep-alive` 或 `error: cannot install autostart - the daemon would not start at logon` | 在启动（或安装自启）**之前**即被前置校验拒绝：凭据未设置、区域名非法，或凭据/区域**仅存在于当前会话**（登录时的进程无法读取） | 按提示使用 `SetCredential` 录入凭据、`SetLocate` 持久化区域。此为**有意的**提前拦截，以避免守护进程静默启动失败 |
| 以前台方式运行 `KeepAlive.ps1` 时窗口**闪现** | 早期失败（如凭据缺失）会打印 `fatal:` 并以非 0 退出码结束；若窗口由双击或快捷方式启动，将立即关闭 | 查看 `main\logs\` 当天日志中的 `fatal:` 行，失败原因记录于此（后台无窗口运行时同理） |

**自查命令：**

```powershell
# 版本与执行环境
$PSVersionTable.PSVersion

# 当前生效配置（含区域来源、网关、ac_id）
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action ShowConfig

# 状态总览
powershell -ExecutionPolicy Bypass -File .\main\Manage.ps1 -Action Status
```

---

<a id="s11"></a>
## 11. 安全说明

- 账号与密码存放在**用户级环境变量**中（Windows 下即注册表 `HKCU\Environment` 的明文），**不写入任何脚本或仓库文件**。
  - 需明确其边界：注册表同样是**持久化存储**，且**以当前用户身份运行的任何进程均可读取**。它优于将密码写入脚本，但并非加密存储。
- 使用 `Manage.ps1` 的 `SetCredential` 录入时，密码为**隐藏输入**，且不会被打印或写入日志。
- 不再需要时，可用 `Manage.ps1 -Action ClearCredential` 一次性清除两处（注册表与当前会话）；
  也可仅清除当前会话的副本：`Remove-Item Env:UESTC_PASSWD`。在共用计算机上请勿长期保存密码。
- 自启方式 `Run` / `Task` 仅写入指向 `KeepAlive.ps1` 的启动命令，不含任何凭据。
- **登录前先验明网关身份**：只有在 `get_challenge` 回显的 `client_ip` 与本机有线出口源 IP 一致、且 `challenge` 形态合法时，才会构造并发送密码材料。若对端不是真正的 srun 网关（非校园网 / 门户劫持 / 地址段撞车），工具进入 `Foreign` 状态并**不发送任何凭据**。
  - 它的边界：能挡住"随手撞车 / 门户"一类廉价情形，但**挡不住定向恶意对端**——真正占据网关地址的设备可在 TCP 层看到本机源 IP 并原样回显，从而通过校验（此时它会拿到密码材料）；也挡不住位于到网关同一路径上的中间人（见下条）。
  - 另注：身份探测（`get_challenge`）会携带**账号名**；密码受 `challenge` 加密保护，账号名不受。
- **认证链路为明文 HTTP**（本节最重要的一项）：srun 网关本身仅提供 HTTP，而用于保护密码的 `challenge` 令牌**在同一条明文信道上下发**（XXTEA 的密钥即为该令牌）。因此，同一局域网内的监听者可解出明文密码，低熵密码还可能遭受离线字典攻击。
  - 此属**协议固有限制**，客户端无法单方面消除。本工具可做的是**仅管理有线网络**，不将认证流量发往无线侧。
  - 因此，请**仅在可信的校园有线网络中使用**，不要在公共 Wi-Fi 或不可信网络下依赖本工具。
  - 若校方网关同时提供可信 HTTPS（证书有效），可将 `SrunConfig.ps1` 预设中的 URL 改为 https，但需自行验证网关确支持该协议。
- **登录请求使用 GET 方法**，`password` / `info` / `chksum` 均位于查询串中，可能被网关或中间代理记入访问日志。此由协议形态决定，客户端无法规避。
- **自启项位于用户可写目录，并以 `-ExecutionPolicy Bypass` 在每次登录时执行一次**：能够改写 `main` 目录的进程即可获得登录期的持久执行能力（用户级，非提权）。请勿将该目录置于共享位置或他人可写的位置。
- **执行 `ClearCredential` 后，正在运行的守护进程内存中仍可能保留旧密码**（其于启动时读取一次，之后一直使用内存中的值）。轮换密码时请配合 `Stop` 与 `Start`。

---

<a id="s12"></a>
## 12. 已知限制

| 限制 | 说明 |
|---|---|
| 仅 Windows | 依赖 Windows PowerShell 5.1 及 Windows 环境变量与自启机制 |
| 针对电子科技大学校园网 | 网关地址与协议依据 UESTC 的 srun 系统实现 |
| 仅管理**有线**网络 | 使用 Wi-Fi 时有意不介入 |
| 自启为"登录时"触发 | 无桌面会话时不运行（除非改造为系统级任务） |
| 无优雅停止 | `Stop` 以强制终止方式停止 |
| 无窗口启动器依赖 Windows Script Host | 极少数被组策略禁用 WSH 的计算机将回退为"隐藏窗口"（窗口可能闪现）；`Install` 时会给出提示 |
| 探测地址需可访问 | 默认使用 Windows 官方连通性检测地址；更换时须同步修改"期望内容" |
| 内存占用 | 常驻进程约 **90 MB**，随负载浮动（PowerShell 运行时开销）。该数值来自短时观测（单点实测 93.1 MB），尚无持续 24 小时以上的实测数据支撑 |
| 移动安装目录后需重装自启 | 自启项记录的是绝对路径。`Start-Hidden.vbs` 自身可随目录移动，但自启项不会自动跟随；移动 `main` 后请重新执行 `Install` |
| 认证链路为明文 HTTP | 见 §11；属协议固有限制，客户端无法消除 |
| 网关响应未设读取上限 | 身份探测与登录响应经 `Invoke-WebRequest` 读取，未做有界读取（§7 的 `MaxProbeChars` 仅覆盖外网探测）。恶意对端可能返回超大响应，属已知残余风险 |
| 无法完全区分"门户劫持"与"校园网掉线" | 主要防线是登录前的身份校验（`Foreign` 状态）；未引入 HTTPS / 证书或门户特征探针。若对端能回显本机源 IP，身份校验可被通过（见 §11） |
| 身份校验依赖网关回显 `client_ip` | 校验要求网关返回的 `client_ip` 等于本机有线出口源 IP。若校方网关不满足该条件，会被判为 `Foreign` 而不登录（属保护性误判）；届时请按 §14.4 反馈 |
| 日志默认保留 30 天 | 见 §7 的 `LogRetentionDays`（`0` 表示永久保留，磁盘占用不再有上限） |
| 计划任务的"失败重启"当前不触发 | 任务中虽配置了失败重启 3 次，但无窗口启动器（`Start-Hidden.vbs`）启动后**不等子进程退出即返回**，任务因此总被记为"成功"，重启策略不会触发。启动失败的原因不会丢失，记录于日志的 `fatal:` 行（见 §10） |
| **计划任务自启路径未经实机验证** | 本机全部验证均采用 `Run` 方式；以管理员身份安装（`-Method Task`，亦为 `Auto` 的首选）时走计划任务，其行为**仅有静态依据**，未在实机运行验证。建议先以 `-Method Run` 验证，或在安装后通过 `-Action Logs` 确认日志出现 `keep-alive started` |

---

> **以下两节面向维护者**

<a id="s13"></a>
## 13. 工程约定（维护者须知）

为保持长期稳定运行，本工程设有以下约束：

| 约定 | 说明 |
|---|---|
| **配置只写一处** | 任何可调数值（时间、超时、网址、策略）只允许出现在配置区，其它地方一律**引用**，不得重复写数字或字符串。 |
| **成组的值必须放一起** | 例：网关地址与 `ac_id` 必须同时切换，故封装为"区域预设"；探测网址与期望内容则封装为一体。**不允许拆开**。 |
| **协议红线不得改动** | `acid` / `ac_id` 的不同拼写、校验和拼接顺序、加密取整方式（`[Math]::Floor`）、位掩码（`4294967295`）等，是实测验证过的协议正确性，只允许调整代码位置，**不允许改动语义**。 |

**当前各权威定义点（修改时以此为准，无需在其他位置查找同名值）：**

| 内容 | 唯一权威 |
|---|---|
| 区域预设 / 默认区域 / 运营商 / 日志目录 / 环境变量名 / 守护状态标记 | `SrunConfig.ps1` |
| Keep-Alive 参数（含冷却）/ 探测目标 / 有线网卡过滤 | `SrunKeepAlive.ps1` |
| 登录请求头 / 登录请求超时 / 网关身份不变量 / 网关连接超时 | `SrunLogin.ps1` |
| 动作清单（菜单条目与编号、命令行分发都从这里派生） | `Manage.ps1` 的 `$script:SrunActions` 表（`-Action` 的 `ValidateSet` 是它的镜像，启动时校验漂移） |
| 自启项名称（计划任务名与注册表值名同源） | `Manage.ps1` 的 `$script:AutostartName` |
| 启动器可执行文件路径 | `Manage.ps1` 的 `$script:WscriptExe` / `$script:PowerShellExe`（**注意**：`Start-Hidden.vbs` 内另有一份等价路径；因跨语言无法共享，**修改一处必须同步另一处**） |

判断登录是否成功，统一依据协议层返回的 `$res.Success`，**不要在调用处比较返回字符串**。

**编码约束**：`main\` 下的**代码文件**（`.ps1` / `.vbs`）必须保持**字节级纯 ASCII**——既不包含非 ASCII 字符，也不包含 UTF-8 BOM（BOM 的字节 `EF BB BF` 会使文件在字节级不再是纯 ASCII）；**Markdown 文档**（`*.md`）**允许**带 UTF-8 BOM。此约束用于避免在不同语言 / 区域设置的计算机上出现编码解析问题。

---

<a id="s14"></a>
## 14. 版本与兼容性

<a id="s14-1"></a>
### 14.1 版本历史

| 版本 | 日期 | 内容摘要 |
|---|---|---|
| **1.1.0** | 2026-10-05 | **加固版**。登录前增加**网关身份校验**（`client_ip` 回显须等于本机有线出口源 IP、`challenge` 形态校验），未通过则不构造、不发送任何密码材料；新增 `Foreign`（非校园网 / 门户，永不登录）与 `Cooling`（重连失败达上限后冷却）状态，及配置键 `MaxReconnectAttempts` / `CooldownDelay`；状态变化日志行新增 `[state=...]` 标记，`Status` 显示守护进程当前状态；并统一 `main\` 代码文件为**字节级纯 ASCII**（去除既有 BOM）。不破坏 §14.2 契约。 |
| **1.0.0** | 2026-10-05 | **首次发布版**。自动登录 + Keep-Alive 重连 + 自启管理（Run / Task）+ 凭据 / 区域 / 日志管理；**无窗口**启动；启动期致命错误写入 `fatal:` 日志并以非 0 退出（不再静默退出）；探测响应**有界读取**与日志保留策略；动作 / 区域 / 键名 / 路径**单一来源**并有启动期漂移检查。 |

<a id="s14-2"></a>
### 14.2 契约表面（自 1.0.0 起稳定）

下表即为本工具**对外承诺的全部范围**。修改其中任何一条均属**破坏性变更**（见 §14.3）。

| 契约 | 具体内容 | 改动后果 |
|---|---|---|
| 命令行动作集 | `-Action` 的取值（`Status` / `ShowConfig` / `SetCredential` / `ClearCredential` / `SetLocate` / `TestLogin` / `Install` / `Uninstall` / `Enable` / `Disable` / `Start` / `Stop` / `Logs` / `Menu`）、`-Method` 的 `Auto` / `Task` / `Run` | 用户的脚本、快捷方式与本文档示例全部失效 |
| 环境变量名 | `UESTC_NUMBER` / `UESTC_PASSWD` / `UESTC_LOCATE` | 用户已保存的凭据将无法读取，必须重新设置 |
| 配置键名与取值 | `$script:SrunKeepAliveConfig` 的键名；区域名 `Teaching` / `Dorm`；运营商后缀 `$script:SrunDomain` | 用户按 §7 完成的配置失效；`UESTC_LOCATE` 的旧值会被拒绝 |
| 自启项标识 | `UESTC-WiredAnchor`（计划任务名与 Run 值名同源） | `Uninstall` / `Disable` 将无法定位自身条目，在用户计算机上残留无法清理的项 |
| 日志位置与格式 | `main\logs\YYYY-MM-DD.log`；行前缀 `[yyyy-MM-dd HH:mm:ss] `；仅记录状态变化；状态变化行尾部附带机器可读标记 `[state=<状态>]`（1.1.0 起新增，属**追加**，不改行前缀） | 任何依据日志判断的脚本或习惯失效 |
| 入口输出 | `Login.ps1` 打印 `ip …` 与 `connected`；成功退出码 0、失败 1 | 用户的判断条件失效 |
| 运行环境 | Windows + Windows PowerShell 5.1；**无第三方依赖**；目录布局固定 | 引入模块依赖将导致用户无法安装 |
| 协议不变量（红线） | `acid` / `ac_id` 的拼写、校验和拼接顺序、`[Math]::Floor`、`4294967295` 掩码 | 登录将直接失败（属正确性要求，但同样必须单独列出） |

<a id="s14-3"></a>
### 14.3 版本号规则

| 位数 | 何时递增 | 例子 |
|---|---|---|
| **MAJOR**（2.0.0） | 破坏 §14.2 契约表中**任意一条** | 重命名环境变量、改动作名、改日志路径或格式、要求新依赖 |
| **MINOR**（1.1.0） | **新增**动作 / 区域 / 配置键，且不破坏契约表 | 新增一个区域预设、新增一个可调参数 |
| **PATCH**（1.0.1） | 仅修复缺陷或修改文档，契约不变 | 修复探测误判、修复日志乱码 |

> 本工具为本地工具，不提供公共 API：上表即为"稳定"的**全部**含义。不承诺长期向后兼容，仅承诺"破坏性变更只在 MAJOR 中发生，并在 §14.1 中明确列出"。

<a id="s14-4"></a>
### 14.4 维护与贡献

本工程目前采用**单一维护者（BDFL）**模式：所有功能性变更均须先与维护者沟通，以免与既有设计约定（见 §13）冲突。

| 事项 | 渠道 |
|---|---|
| 维护者 | Victor Cartesius（vcartesius@126.com） |
| 报告问题 / 提出建议 | 提交 Issue，或直接邮件说明 |
| 提交代码 | 先沟通确认方案，再提交 Pull Request；详见 `CONTRIBUTING.md` |
| 安全漏洞 | 一般缺陷可直接提 Issue；**可被利用的**漏洞（如凭据泄露、任意代码执行）请先私下上报，修复后再公开；详见 `SECURITY.md` |

**发布流程**（维护者）：

1. 修改代码，并新开一轮审查（报告写入开发期内部归档，不随本工具分发）；
2. 在 §14.1 版本历史中增加一行（版本号 + 日期 + 摘要）；
3. 若属 MAJOR：在 §14.1 相应行中**逐条列出**被破坏的契约；
4. 同步更新顶部信息表的**版本号**；
5. §13 的协议红线在**任何**版本中均不得改动。

**许可证**：MIT，见 `LICENSE`。

---

> [↑ 回到目录](#toc)
