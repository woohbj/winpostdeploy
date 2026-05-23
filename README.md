# WinPostDeploy

WinPostDeploy 是一个 Windows Ghost 后初始化工具，用于批量装机后的自动加域、自动改名、状态续跑、日志记录，并预留资安软件自动安装流程。

当前已验证能力：

- 读取本机 BIOS 序列号。
- 根据 `hostname_map.csv` 匹配目标电脑名。
- 使用加域凭据加入 AD 指定 OU。
- 加域时同步设置电脑名。
- 如果出现“已加域但改名失败”，再次运行脚本可自动补做域内改名。
- 加域/改名后自动重启。
- 重启后根据 `State\state.json` 续跑后续步骤。
- 软件安装项可在 `config.json` 中启用或禁用。
- 任意步骤失败即停止，人工处理后再次运行可从失败步骤继续。

## 目录结构

把整个文件夹放到目标电脑：

```text
D:\DesktopInit
```

建议结构：

```text
D:\DesktopInit\Init-Desktop.ps1
D:\DesktopInit\config.json
D:\DesktopInit\hostname_map.csv
D:\DesktopInit\Credentials
D:\DesktopInit\Installers
D:\DesktopInit\Logs
D:\DesktopInit\State
```

## 目录和文件说明

当前部署包只需要这些内容：

```text
WinPostDeploy
├─ Init-Desktop.ps1
├─ config.json
├─ hostname_map.csv
├─ Credentials
│  └─ domain-join.credential.xml
├─ Installers
│  ├─ Bitdefender
│  ├─ IngressedAC
│  └─ IPG
├─ Logs
└─ State
```

说明：

| 路径 | 是否必须 | 用途 |
| --- | --- | --- |
| `Init-Desktop.ps1` | 必须 | 主脚本，负责读 SN、匹配电脑名、加域、改名、重启续跑、安装软件、写日志。 |
| `config.json` | 必须 | 环境配置，包含域名、OU、凭据路径、日志共享路径、软件安装配置。 |
| `hostname_map.csv` | 必须 | SN 和电脑名映射表。 |
| `Credentials` | 必须 | 放加域凭据文件。 |
| `Credentials\domain-join.credential.xml` | 必须 | 加域账号的加密凭据文件。 |
| `Installers` | 软件安装时必须 | 放 Bitdefender、Ingressed/AC、IPG 等安装包。当前软件禁用时可以为空。 |
| `Logs` | 自动生成 | 脚本运行日志目录。 |
| `State` | 自动生成 | 状态文件目录，用于失败后续跑和重启后续跑。 |

可以忽略的文件：

- `.gitkeep`：只是为了保留空目录，对脚本运行没有影响，复制到实体机也没关系。

不应该放进正式部署包的内容：

- 测试临时脚本。
- 旧日志。
- 旧的 `State\state.json` 和 `State\completed.marker`。
- 不属于当前批次的安装包或凭据文件。

## 运行方式

使用管理员身份打开 PowerShell，执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\DesktopInit\Init-Desktop.ps1" -Root "D:\DesktopInit"
```

如果脚本提示已经完成，说明 `D:\DesktopInit\State\completed.marker` 存在。需要重新测试时，先恢复快照，或删除 `State` 里的状态文件后再运行。

## 加域凭据文件

脚本默认从这里读取加域凭据：

```text
D:\DesktopInit\Credentials\domain-join.credential.xml
```

生成方式：

```powershell
New-Item -ItemType Directory -Force -Path "D:\DesktopInit\Credentials"
$cred = Get-Credential "cogniwave\join-account"
$cred | Export-Clixml -Path "D:\DesktopInit\Credentials\domain-join.credential.xml"
```

注意：`Export-Clixml` 生成的凭据文件通常和生成它的 Windows 机器、Windows 用户绑定。Ghost 克隆场景需要实测确认是否能跨克隆机器继续解密。

## 配置文件

修改 `config.json`：

```json
{
  "domain": {
    "name": "cogniwave.cn",
    "ouPath": "OU=Workstations,OU=Devices,DC=cogniwave,DC=cn",
    "credentialPath": "D:\\DesktopInit\\Credentials\\domain-join.credential.xml"
  },
  "logSharePath": "",
  "software": []
}
```

常用配置项：

- `domain.name`：AD 域名。
- `domain.ouPath`：电脑对象加入的目标 OU。
- `domain.credentialPath`：加域凭据文件路径。
- `logSharePath`：日志共享目录；为空时只保留本地日志。
- `software`：资安软件安装列表。
- `cleanup.enabled`：是否在全部成功后清理本地安装文件。

## 电脑名映射

修改 `hostname_map.csv`：

```csv
SerialNumber,ComputerName
"VMware-56 4d 71 52 f5 f0 a2 ad-0c 76 8e 79 73 c4 43 a0",CW-TEST-002
```

脚本会读取本机 BIOS SN，并匹配 `ComputerName`。如果 SN 查不到，且配置允许人工输入，脚本会提示手工输入电脑名。

## 软件安装

资安软件在 `config.json` 的 `software` 中配置。当前测试阶段可以先保持禁用：

```json
{
  "name": "Bitdefender",
  "enabled": false,
  "installer": "D:\\DesktopInit\\Installers\\Bitdefender\\setup.exe",
  "arguments": "/quiet /norestart",
  "checkType": "service",
  "checkValue": "bdservicehost"
}
```

支持的安装成功检查方式：

- `service`：检查服务名。
- `process`：检查进程名，不带 `.exe`。
- `path`：检查文件或目录是否存在。
- `registry`：检查注册表路径是否存在。
- `none`：只看安装程序退出码。

## 日志与状态

本地日志目录：

```text
D:\DesktopInit\Logs
```

状态目录：

```text
D:\DesktopInit\State
```

关键文件：

- `State\state.json`：当前执行状态、已完成步骤、失败原因。
- `State\completed.marker`：全部完成标记，存在时脚本不会重复执行。
- `Logs\WinPostDeploy_*.log`：详细执行日志。

如果通过 VMware `vmrun` 执行脚本，建议把 stdout/stderr 重定向到 `State` 目录，真正排查以 `Logs\WinPostDeploy_*.log` 和 `State\state.json` 为准。

## 已验证测试流程

在 VMware Workstation 测试 VM 中已验证：

1. 恢复快照。
2. 复制 `WinPostDeploy` 到 `D:\DesktopInit`。
3. 生成或保留 `Credentials\domain-join.credential.xml`。
4. 修改 `hostname_map.csv` 目标电脑名。
5. 管理员 PowerShell 执行脚本。
6. 完成加域、改名、重启续跑。
7. 验证结果：

```text
ComputerName=CW-TEST-002
PartOfDomain=True
Domain=cogniwave.cn
```

## V1 验收清单

用于确认“自动加域与改名稳定版”是否通过：

| 检查项 | 通过标准 |
| --- | --- |
| 目录存在 | `D:\DesktopInit` 存在，且包含主脚本、配置、映射表、凭据目录。 |
| 凭据文件 | `D:\DesktopInit\Credentials\domain-join.credential.xml` 存在。 |
| 配置文件 | `config.json` 中域名、OU、凭据路径正确。 |
| 电脑名映射 | `hostname_map.csv` 中当前机器 SN 能匹配到目标电脑名。 |
| DNS | 目标电脑能解析并访问 AD 域。 |
| 管理员运行 | 使用管理员 PowerShell 执行一条运行命令。 |
| 加域结果 | `PartOfDomain=True`，`Domain` 为目标 AD 域。 |
| 改名结果 | 本机电脑名等于 `hostname_map.csv` 中的目标电脑名。 |
| 状态文件 | `State\state.json` 中 `Status` 为 `Completed`。 |
| 失败原因 | `State\state.json` 中 `FailureReason` 为空。 |
| 日志文件 | `Logs\WinPostDeploy_*.log` 存在，可用于排查。 |
| 软件安装 | V1 默认禁用软件安装，日志中应显示跳过已禁用软件。 |
| 清理 | V1 默认禁用清理，部署文件保留用于排查。 |

常用验证命令：

```powershell
$cs = Get-CimInstance Win32_ComputerSystem
"ComputerName=$env:COMPUTERNAME"
"PartOfDomain=$($cs.PartOfDomain)"
"Domain=$($cs.Domain)"
Get-Content "D:\DesktopInit\State\state.json"
```
