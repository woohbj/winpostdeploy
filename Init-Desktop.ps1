[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Root = "D:\DesktopInit",
    [string]$SimulatedSerialNumber,
    [switch]$SkipAdminCheck
)

# WinPostDeploy 主脚本
# 用途：Ghost 后首次开机初始化 Windows 电脑。
# 主要流程：读取 SN -> 匹配电脑名 -> 加域时改名 -> 重启后续跑 -> 安装软件 -> 回传日志 -> 清理。
# 说明：公司/环境差异放在 config.json 和 hostname_map.csv 中。

$ErrorActionPreference = "Stop"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
}
catch {
    # 某些受限环境不允许修改控制台编码；日志文件仍会按 UTF-8 写入。
}

$ConfigPath = Join-Path $Root "config.json"
$MapPath = Join-Path $Root "hostname_map.csv"
$LogDir = Join-Path $Root "Logs"
$StateDir = Join-Path $Root "State"
$StatePath = Join-Path $StateDir "state.json"
$CompletionMarker = Join-Path $StateDir "completed.marker"
$RunStartedAt = Get-Date

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

Ensure-Directory -Path $LogDir
Ensure-Directory -Path $StateDir

$Script:LogPath = Join-Path $LogDir ("WinPostDeploy_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
}

# 任意步骤失败时统一调用这里：
# 记录失败原因、写入状态文件、停止脚本，等待人工处理后重新运行。
function Stop-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Write-Log -Level "ERROR" -Message ("步骤失败：{0}。原因：{1}" -f $Step, $Reason)
    Save-State -Status "Failed" -CurrentStep $Step -FailureReason $Reason
    throw "WinPostDeploy 已在步骤 '$Step' 停止。请人工处理问题后重新运行脚本。"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 读取公司环境配置，例如域名、OU、日志共享路径、软件安装参数。
function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Stop-Step -Step "LoadConfig" -Reason "找不到配置文件：$ConfigPath"
    }

    try {
        return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Stop-Step -Step "LoadConfig" -Reason "配置文件不是有效的 JSON。$($_.Exception.Message)"
    }
}

# 读取本地状态文件，用于失败后继续执行和重启后续跑。
function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [ordered]@{
            Status = "New"
            CurrentStep = ""
            CompletedSteps = @()
            SerialNumber = ""
            ComputerName = ""
            FailureReason = ""
            UpdatedAt = (Get-Date).ToString("s")
        }
    }

    try {
        $stateObject = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $completed = @()
        if ($stateObject.CompletedSteps) {
            $completed = @($stateObject.CompletedSteps)
        }

        return [ordered]@{
            Status = [string]$stateObject.Status
            CurrentStep = [string]$stateObject.CurrentStep
            CompletedSteps = $completed
            SerialNumber = [string]$stateObject.SerialNumber
            ComputerName = [string]$stateObject.ComputerName
            FailureReason = [string]$stateObject.FailureReason
            UpdatedAt = [string]$stateObject.UpdatedAt
        }
    }
    catch {
        Stop-Step -Step "LoadState" -Reason "状态文件不是有效的 JSON。$($_.Exception.Message)"
    }
}

$Script:State = Load-State

function Save-State {
    param(
        [string]$Status = $Script:State.Status,
        [string]$CurrentStep = $Script:State.CurrentStep,
        [string]$SerialNumber = $Script:State.SerialNumber,
        [string]$ComputerName = $Script:State.ComputerName,
        [string]$FailureReason = ""
    )

    $Script:State.Status = $Status
    $Script:State.CurrentStep = $CurrentStep
    $Script:State.SerialNumber = $SerialNumber
    $Script:State.ComputerName = $ComputerName
    $Script:State.FailureReason = $FailureReason
    $Script:State.UpdatedAt = (Get-Date).ToString("s")

    $Script:State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Test-StepCompleted {
    param([Parameter(Mandatory = $true)][string]$Step)
    return @($Script:State.CompletedSteps) -contains $Step
}

function Complete-Step {
    param([Parameter(Mandatory = $true)][string]$Step)

    if (-not (Test-StepCompleted -Step $Step)) {
        $Script:State.CompletedSteps = @($Script:State.CompletedSteps) + $Step
    }

    Save-State -Status "Running" -CurrentStep $Step
    Write-Log -Level "SUCCESS" -Message ("步骤完成：{0}" -f $Step)
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (Test-StepCompleted -Step $Name) {
        Write-Log -Message ("跳过已完成步骤：{0}" -f $Name)
        return
    }

    Save-State -Status "Running" -CurrentStep $Name
    Write-Log -Message ("开始步骤：{0}" -f $Name)

    try {
        & $Action
        Complete-Step -Step $Name
    }
    catch {
        Stop-Step -Step $Name -Reason $_.Exception.Message
    }
}

# 读取本机 BIOS 序列号；在家测试时可用 -SimulatedSerialNumber 模拟。
function Get-SerialNumber {
    if ($SimulatedSerialNumber) {
        Write-Log -Message "使用模拟序列号。"
        return $SimulatedSerialNumber.Trim()
    }

    $serial = ""
    try {
        $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    }
    catch {
        Write-Log -Level "WARN" -Message ("Get-CimInstance 读取失败，改用 wmic 读取。{0}" -f $_.Exception.Message)
        $serial = (wmic bios get serialnumber /value | Select-String "SerialNumber=" | ForEach-Object { $_.ToString().Split("=")[1] })
    }

    if ([string]::IsNullOrWhiteSpace($serial)) {
        throw "读取到的序列号为空。"
    }

    return $serial.Trim()
}

# 根据 SN 从 hostname_map.csv 查找电脑名；查不到时可人工输入。
function Resolve-ComputerNameFromMap {
    param(
        [Parameter(Mandatory = $true)][string]$SerialNumber,
        [Parameter(Mandatory = $true)]$Config
    )

    if (-not (Test-Path -LiteralPath $MapPath)) {
        throw "找不到电脑名映射表：$MapPath"
    }

    $rows = Import-Csv -LiteralPath $MapPath
    $row = $rows | Where-Object { $_.SerialNumber.Trim() -ieq $SerialNumber.Trim() } | Select-Object -First 1

    if ($row -and -not [string]::IsNullOrWhiteSpace($row.ComputerName)) {
        return $row.ComputerName.Trim()
    }

    Write-Log -Level "WARN" -Message ("序列号没有匹配到电脑名：{0}" -f $SerialNumber)

    if ($Config.allowManualComputerNameInput -eq $true) {
        do {
            $manualName = Read-Host "请输入这台电脑要使用的电脑名"
        } while ([string]::IsNullOrWhiteSpace($manualName))

        return $manualName.Trim()
    }

    throw "没有匹配到电脑名，并且配置中不允许人工输入。"
}

# 读取加域专用账号的加密凭据文件。
# 凭据文件必须在实际运行脚本的机器/账号上生成，不能直接复制明文密码。
function Get-DomainCredential {
    param([Parameter(Mandatory = $true)]$Config)

    $credentialPath = $Config.domain.credentialPath
    if ([string]::IsNullOrWhiteSpace($credentialPath)) {
        throw "config.json 中的 domain.credentialPath 为空。"
    }

    if (-not (Test-Path -LiteralPath $credentialPath)) {
        throw "找不到加域凭据文件：$credentialPath"
    }

    try {
        return Import-Clixml -LiteralPath $credentialPath
    }
    catch {
        throw "无法读取加域凭据文件。请在实际运行脚本的机器/账号上使用 Export-Clixml 生成。$($_.Exception.Message)"
    }
}

# 如果机器已经在域内，才单独改名。
# 对 Ghost 后未加域机器，改名交给 Add-Computer -NewName 在加域时一起完成。
function Invoke-ComputerRename {
    param(
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)]$Config
    )

    $currentName = $env:COMPUTERNAME
    if ($currentName -ieq $TargetName) {
        Write-Log -Message ("当前电脑名已经符合目标名称：{0}" -f $TargetName)
        return
    }

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computerSystem.PartOfDomain -ne $true) {
        Write-Log -Message ("当前电脑尚未加域，电脑名将在 Add-Computer 加域时通过 NewName 一并设置：{0}" -f $TargetName)
        return
    }

    if ($DryRun) {
        Write-Log -Message ("DryRun：将会把电脑名从 {0} 修改为 {1}" -f $currentName, $TargetName)
        return
    }

    $credential = Get-DomainCredential -Config $Config
    Rename-Computer -NewName $TargetName -DomainCredential $credential -Force
}

# 加入指定域和 OU；未加域机器会在这里同时设置目标电脑名。
function Invoke-DomainJoin {
    param(
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.domain.name)) {
        throw "config.json 中的 domain.name 为空。"
    }

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if (($computerSystem.PartOfDomain -eq $true) -and ($computerSystem.Domain -ieq $Config.domain.name)) {
        Write-Log -Message ("当前电脑已经加入目标域：{0}" -f $Config.domain.name)
        if ($env:COMPUTERNAME -ine $TargetName) {
            Write-Log -Message ("当前电脑名 {0} 与目标电脑名 {1} 不一致，将单独执行域内改名。" -f $env:COMPUTERNAME, $TargetName)
            if ($DryRun) {
                Write-Log -Message ("DryRun：将会把域内电脑名从 {0} 修改为 {1}" -f $env:COMPUTERNAME, $TargetName)
                return
            }

            $credential = Get-DomainCredential -Config $Config
            Rename-Computer -NewName $TargetName -DomainCredential $credential -Force
        }
        return
    }

    $domainArgs = @{
        DomainName = $Config.domain.name
        Credential = $null
        Force = $true
        ErrorAction = "Stop"
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.domain.ouPath)) {
        $domainArgs["OUPath"] = $Config.domain.ouPath
    }

    if ($env:COMPUTERNAME -ine $TargetName) {
        $domainArgs["NewName"] = $TargetName
    }

    if ($DryRun) {
        Write-Log -Message ("DryRun：将会加入域 {0}，OU {1}，目标电脑名 {2}" -f $Config.domain.name, $Config.domain.ouPath, $TargetName)
        return
    }

    $domainArgs.Credential = Get-DomainCredential -Config $Config
    Add-Computer @domainArgs
}

# 加域成功后统一重启；重启后依靠 State 目录中的状态文件继续执行。
function Request-RebootIfNeeded {
    param([Parameter(Mandatory = $true)]$Config)

    if ($DryRun) {
        Write-Log -Message "DryRun：改名/加域后将会重启。"
        return
    }

    if ($Config.rebootAfterDomainJoin -eq $true) {
        Write-Log -Message "15 秒后重启。如果没有配置开机自动运行，重启后请手动重新运行脚本。"
        if (-not (Test-StepCompleted -Step "RebootAfterDomainJoin")) {
            $Script:State.CompletedSteps = @($Script:State.CompletedSteps) + "RebootAfterDomainJoin"
        }
        Save-State -Status "Running" -CurrentStep "RebootAfterDomainJoin"
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    }
}

# 按配置检查软件是否安装成功。
# 支持服务、进程、路径、注册表、仅退出码几种方式。
function Test-SoftwareInstalled {
    param([Parameter(Mandatory = $true)]$Software)

    if ([string]::IsNullOrWhiteSpace($Software.checkType)) {
        Write-Log -Level "WARN" -Message ("{0} 未配置 checkType，将只根据安装程序退出码判断。" -f $Software.name)
        return $true
    }

    switch ($Software.checkType.ToString().ToLowerInvariant()) {
        "service" {
            return [bool](Get-Service -Name $Software.checkValue -ErrorAction SilentlyContinue)
        }
        "process" {
            return [bool](Get-Process -Name $Software.checkValue -ErrorAction SilentlyContinue)
        }
        "path" {
            return Test-Path -LiteralPath $Software.checkValue
        }
        "registry" {
            return Test-Path -LiteralPath $Software.checkValue
        }
        "none" {
            return $true
        }
        default {
            throw "$($Software.name) 使用了不支持的软件检查方式：'$($Software.checkType)'。"
        }
    }
}

# 按 config.json 中的软件顺序执行静默安装。
function Install-ConfiguredSoftware {
    param([Parameter(Mandatory = $true)]$Config)

    foreach ($software in @($Config.software)) {
        if ($software.enabled -eq $false) {
            Write-Log -Message ("跳过已禁用软件：{0}" -f $software.name)
            continue
        }

        if ([string]::IsNullOrWhiteSpace($software.name)) {
            throw "软件配置中存在空的软件名称。"
        }

        if ([string]::IsNullOrWhiteSpace($software.installer)) {
            throw "$($software.name) 的安装包路径为空。"
        }

        if ((-not $DryRun) -and (-not (Test-Path -LiteralPath $software.installer))) {
            throw "找不到 $($software.name) 的安装包：$($software.installer)"
        }

        if ($DryRun) {
            Write-Log -Message ("DryRun：将会安装 {0}：{1} {2}" -f $software.name, $software.installer, $software.arguments)
            continue
        }

        Write-Log -Message ("正在安装 {0}" -f $software.name)
        $process = Start-Process -FilePath $software.installer -ArgumentList $software.arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "$($software.name) 安装程序返回退出码 $($process.ExitCode)。"
        }

        if (-not (Test-SoftwareInstalled -Software $software)) {
            throw "$($software.name) 安装完成后的检查未通过。"
        }

        Write-Log -Level "SUCCESS" -Message ("安装完成：{0}" -f $software.name)
    }
}

# 将本地日志复制到共享目录；共享目录只保存日志，不参与安装。
function Copy-LogsToShare {
    param([Parameter(Mandatory = $true)]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.logSharePath)) {
        Write-Log -Level "WARN" -Message "logSharePath 为空；日志只保留在本地。"
        return
    }

    if ($DryRun) {
        Write-Log -Message ("DryRun：将会复制日志到 {0}" -f $Config.logSharePath)
        return
    }

    if (-not (Test-Path -LiteralPath $Config.logSharePath)) {
        throw "找不到日志共享路径：$($Config.logSharePath)"
    }

    $targetName = if ($Script:State.ComputerName) { $Script:State.ComputerName } else { $env:COMPUTERNAME }
    $targetFile = Join-Path $Config.logSharePath ("{0}_{1}.log" -f $targetName, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item -LiteralPath $Script:LogPath -Destination $targetFile -Force
}

# 全部成功后才清理本地初始化文件；失败时不清理，方便排查。
function Clear-DesktopInitFiles {
    param([Parameter(Mandatory = $true)]$Config)

    if ($Config.cleanup.enabled -ne $true) {
        Write-Log -Message "配置中未启用清理。"
        return
    }

    if ($DryRun) {
        Write-Log -Message ("DryRun：将会清理 {0} 下配置指定的路径。" -f $Root)
        return
    }

    foreach ($relativePath in @($Config.cleanup.relativePaths)) {
        $path = Join-Path $Root $relativePath
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Log -Message ("已删除 {0}" -f $path)
        }
    }

    if ($Config.cleanup.emptyRecycleBin -eq $true) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log -Message "回收站已清空。"
    }
}

# 写入完成标记，避免脚本下次开机重复执行。
function Complete-Deployment {
    New-Item -Path $CompletionMarker -ItemType File -Force | Out-Null
    Save-State -Status "Completed" -CurrentStep "Complete"
    Write-Log -Level "SUCCESS" -Message ("WinPostDeploy 执行完成。耗时：{0}" -f ((Get-Date) - $RunStartedAt))
}

Write-Log -Message "WinPostDeploy 开始执行。"
Write-Log -Message ("根目录：{0}" -f $Root)
Write-Log -Message ("DryRun 模拟模式：{0}" -f [bool]$DryRun)

if ((-not $DryRun) -and (-not $SkipAdminCheck) -and (-not (Test-IsAdministrator))) {
    Stop-Step -Step "CheckAdministrator" -Reason "请使用管理员身份运行 PowerShell。"
}

if ($DryRun -and (-not (Test-IsAdministrator))) {
    Write-Log -Level "WARN" -Message "当前 DryRun 不是管理员权限；真实部署时必须使用管理员权限。"
}

if (Test-Path -LiteralPath $CompletionMarker) {
    Write-Log -Level "SUCCESS" -Message "部署已经完成，无需重复执行。"
    return
}

$Config = Load-Config

Invoke-Step -Name "ResolveComputerName" -Action {
    $serial = Get-SerialNumber
    $computerName = Resolve-ComputerNameFromMap -SerialNumber $serial -Config $Config
    Save-State -Status "Running" -CurrentStep "ResolveComputerName" -SerialNumber $serial -ComputerName $computerName
    Write-Log -Message ("序列号：{0}" -f $serial)
    Write-Log -Message ("目标电脑名：{0}" -f $computerName)
}

Invoke-Step -Name "RenameComputer" -Action {
    Invoke-ComputerRename -TargetName $Script:State.ComputerName -Config $Config
}

Invoke-Step -Name "JoinDomain" -Action {
    Invoke-DomainJoin -TargetName $Script:State.ComputerName -Config $Config
}

Invoke-Step -Name "RebootAfterDomainJoin" -Action {
    Request-RebootIfNeeded -Config $Config
}

Invoke-Step -Name "InstallSoftware" -Action {
    Install-ConfiguredSoftware -Config $Config
}

Invoke-Step -Name "CopyLogs" -Action {
    Copy-LogsToShare -Config $Config
}

Invoke-Step -Name "Cleanup" -Action {
    Clear-DesktopInitFiles -Config $Config
}

Complete-Deployment
