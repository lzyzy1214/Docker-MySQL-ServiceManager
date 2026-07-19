<#
.SYNOPSIS
    Docker MySQL 单一菜单管理器（All-in-One）
.DESCRIPTION
    一个自包含脚本，无需任何外部功能脚本：
    - 在 BasePath (D:\develop\Docker_Repository) 运行时，可创建新的 mysql${port} 实例。
    - 复制到 mysql${port} 目录运行时，进入运维菜单。
    所有密码通过 DPAPI 加密保存到项目根目录 .mysqlcred，脚本文件中不含任何敏感信息。
    右键“使用 PowerShell 运行”时，窗口会在操作完成后暂停，避免一闪而过。
.EXAMPLE
    右键 -> 使用 PowerShell 运行 mysql-manager.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 设置控制台输入输出编码为 UTF-8，确保 docker exec 捕获的中文不会被误解析为 GBK
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 全局常量
$Global:BasePath = 'D:\develop\Docker_Repository'

# 检测运行位置
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
$isProject = (Split-Path -Leaf $scriptDir) -match '^mysql\d+$'

if ($isProject) {
    $Global:ProjectPath = $scriptDir
    $Global:Port = [regex]::Match((Split-Path -Leaf $scriptDir), '\d+').Value
}
else {
    $Global:ProjectPath = $null
    $Global:Port = $null
}

#region 配置

function Get-ProjectConfig {
    <#
    .SYNOPSIS
        读取项目配置，若不存在则返回基于目录名的默认配置
    #>
    [CmdletBinding()]
    param()

    $defaults = [ordered]@{
        BasePath      = $Global:BasePath
        Port          = if ($Global:Port) { $Global:Port } else { '3308' }
        ContainerName = 'mysql-locals'
        DefaultDb     = 'myapp'
        Image         = 'mysql'
        Version       = 'latest'
    }

    if ($Global:ProjectPath) {
        $configFile = Join-Path $Global:ProjectPath 'project.config.json'
        if (Test-Path $configFile) {
            $json = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                $defaults[$prop.Name] = $prop.Value
            }
        }
        else {
            # 根据目录名推断端口
            $dirName = Split-Path -Leaf $Global:ProjectPath
            if ($dirName -match '(\d+)$') {
                $defaults.Port = $matches[1]
            }
            $defaults.ContainerName = "mysql-locals-$($defaults.Port)"
        }
    }

    $defaults.ProjectPath = Join-Path $defaults.BasePath "mysql$($defaults.Port)"
    $defaults.ConfDir     = Join-Path $defaults.ProjectPath 'conf'
    $defaults.DataDir     = Join-Path $defaults.ProjectPath 'data'
    $defaults.LogDir      = Join-Path $defaults.ProjectPath 'log'
    $defaults.BackupDir   = Join-Path $defaults.ProjectPath 'backups'

    # 转换为 PSCustomObject，确保后续属性访问稳定
    return [PSCustomObject]$defaults
}

function Save-ProjectConfig {
    <#
    .SYNOPSIS
        保存项目配置到 project.config.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $configFile = Join-Path $Config.ProjectPath 'project.config.json'
    $saveData = @{
        BasePath      = $Config.BasePath
        Port          = $Config.Port
        ContainerName = $Config.ContainerName
        DefaultDb     = $Config.DefaultDb
        Image         = $Config.Image
        Version       = $Config.Version
    }
    $saveData | ConvertTo-Json | Out-File -FilePath $configFile -Encoding UTF8 -Force
}

#endregion

#region 日志输出

function Write-LogInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO]  $Message" -ForegroundColor White
}

function Write-LogStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n[STEP]  $Message ..." -ForegroundColor Cyan
}

function Write-LogSuccess {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[OK]    $Message" -ForegroundColor Green
}

function Write-LogWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN]  $Message" -ForegroundColor Yellow
}

function Write-LogError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-LogCommand {
    <#
    .SYNOPSIS
        打印即将执行的命令，并对密码等敏感信息进行脱敏
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )
    # 对常见密码参数进行脱敏
    $masked = $Command -replace '(MYSQL_ROOT_PASSWORD|MYSQL_PWD)=\S+', '$1=********'
    $masked = $masked -replace '-p\S+', '-p********'
    Write-Host "[CMD]   $masked" -ForegroundColor DarkGray
}

#endregion

#region 安全凭据

function Get-CredentialPath {
    if (-not $Global:ProjectPath) { return $null }
    return Join-Path $Global:ProjectPath '.mysqlcred'
}

function Save-MySqlCredential {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Password
    )

    $credPath = Get-CredentialPath
    if (-not $credPath) { throw '当前不在项目目录，无法保存凭据。' }

    $encrypted = ConvertFrom-SecureString -SecureString $Password
    $encrypted | Out-File -FilePath $credPath -Encoding UTF8 -Force
}

function Get-MySqlCredential {
    $credPath = Get-CredentialPath
    if (-not $credPath -or -not (Test-Path $credPath)) { return $null }

    try {
        $encrypted = (Get-Content $credPath -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($encrypted)) { return $null }
        $secure = ConvertTo-SecureString -String $encrypted
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    catch {
        throw "读取凭据失败（可能是在其他用户/机器创建）: $_"
    }
}

function ConvertTo-PlainText {
    param([Security.SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}

function Read-MySqlPassword {
    <#
    .SYNOPSIS
        交互式读取并确认密码，最多重试 5 次
    #>
    param([int]$MaxRetries = 5)

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $p1 = Read-Host '请输入 MySQL root 密码' -AsSecureString
        $p2 = Read-Host '请再次输入密码确认' -AsSecureString

        $plain1 = ConvertTo-PlainText $p1
        $plain2 = ConvertTo-PlainText $p2

        if ($plain1 -ne $plain2) {
            Write-LogWarning '两次输入不一致，请重新输入。'
            continue
        }
        if ([string]::IsNullOrWhiteSpace($plain1)) {
            Write-LogWarning '密码不能为空，请重新输入。'
            continue
        }
        return $p1
    }
    throw "密码输入失败，已达到最大重试次数 ($MaxRetries)。"
}

function Read-MySqlPasswordOnce {
    <#
    .SYNOPSIS
        单次输入密码，最多重试 5 次（用于运维操作）
    #>
    param([int]$MaxRetries = 5)

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $secure = Read-Host '请输入 MySQL root 密码' -AsSecureString
        $plain = ConvertTo-PlainText $secure
        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            return $plain
        }
        Write-LogWarning '密码不能为空，请重新输入。'
    }
    throw "密码输入失败，已达到最大重试次数 ($MaxRetries)。"
}

function Get-MySqlPasswordOnce {
    <#
    .SYNOPSIS
        获取 MySQL 密码：优先使用会话缓存，其次保存的凭据，最后单次输入
    #>
    param([int]$MaxRetries = 5)

    if ($script:MySqlPasswordCache) { return $script:MySqlPasswordCache }

    $stored = Get-MySqlCredential
    if ($stored) {
        $script:MySqlPasswordCache = $stored
        return $stored
    }

    Write-LogWarning '未找到保存的凭据，需要手动输入。'
    $password = Read-MySqlPasswordOnce -MaxRetries $MaxRetries
    $script:MySqlPasswordCache = $password
    return $password
}

function Get-MySqlPassword {
    $stored = Get-MySqlCredential
    if ($stored) { return $stored }

    Write-LogWarning '未找到保存的凭据，需要手动输入。'
    return ConvertTo-PlainText (Read-MySqlPassword)
}

#endregion

#region Docker 与 MySQL 工具

function Test-DockerAvailable {
    <#
    .SYNOPSIS
        检测 Docker 守护进程是否可用（Docker Desktop 是否已启动）
    #>
    try {
        $output = & docker version --format '{{.Server.Version}}' 2>&1
        return $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)
    }
    catch { return $false }
}

function Get-ContainerStatus {
    param([string]$ContainerName)
    return docker ps -a --filter "name=^/${ContainerName}$" --format '{{.Status}}' 2>$null
}

function Test-ContainerExists {
    param([string]$ContainerName)
    return -not [string]::IsNullOrWhiteSpace((Get-ContainerStatus -ContainerName $ContainerName))
}

function Test-ContainerRunning {
    param([string]$ContainerName)
    $running = docker ps --filter "name=^/${ContainerName}$" --filter 'status=running' --format '{{.Names}}' 2>$null
    return -not [string]::IsNullOrWhiteSpace($running)
}

function Assert-ContainerRunning {
    param([string]$ContainerName)
    if (-not (Test-DockerAvailable)) { throw 'Docker 未运行或未安装。' }
    if (-not (Test-ContainerExists -ContainerName $ContainerName)) { throw "容器 $ContainerName 不存在。" }
    if (-not (Test-ContainerRunning -ContainerName $ContainerName)) { throw "容器 $ContainerName 未运行。" }
}

function Test-PortAvailable {
    param([int]$Port)
    try {
        $inUse = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        return $null -eq $inUse
    }
    catch {
        $result = netstat -ano | Select-String ":$Port " | Select-String 'LISTENING'
        return $null -eq $result
    }
}

function Get-MySqlTrueVersion {
    <#
    .SYNOPSIS
        通过临时运行容器获取镜像内 MySQL 的真实版本号
    .PARAMETER ImageSpec
        镜像规格，如 mysql:latest
    .OUTPUTS
        String 版本号字符串，获取失败返回空
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageSpec
    )

    try {
        $output = docker run --rm $ImageSpec mysql --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            # 典型输出: mysql  Ver 8.0.37 for Linux on x86_64 (MySQL Community Server - GPL)
            if ($output -match '(\d+\.\d+(\.\d+)?)') {
                return $matches[0]
            }
            return $output.Trim()
        }
    }
    catch {
        Write-LogWarning "获取真实版本失败: $_"
    }
    return ''
}

function Test-DockerContainer {
    <#
    .SYNOPSIS
        检查指定容器是否正在运行
    #>
    param([string]$ContainerName)
    if ([string]::IsNullOrWhiteSpace($ContainerName)) { return $false }
    if (-not (Test-DockerAvailable)) { return $false }
    try {
        $info = & docker ps -q -f "name=^${ContainerName}$" 2>&1
        return [bool]$info
    }
    catch { return $false }
}

function Invoke-MySqlCli {
    <#
    .SYNOPSIS
        通过 docker exec 执行 mysql 命令
    .PARAMETER SkipColumnNames
        不输出列名（用于获取数据库/表列表等结构化查询）
    .PARAMETER Quiet
        静默模式，不将 stderr 混入 stdout（用于需要清洗输出的查询）
    .PARAMETER Batch
        使用 --batch 输出（制表符分隔，无表格边框，用于 CSV 等解析）
    #>
    param(
        [string]$ContainerName,
        [string]$Password,
        [string]$Database = '',
        [string]$Sql = '',
        [string]$SqlFile = '',
        [switch]$Interactive,
        [switch]$SkipColumnNames,
        [switch]$Quiet,
        [switch]$Batch
    )

    $argsList = @(
        'exec'
        if ($Interactive) { '-it' } else { '-i' }
        '-e', "MYSQL_PWD=$Password"
        $ContainerName
        'mysql'
        '-h', '127.0.0.1'
        '-u', 'root'
        '--default-character-set=utf8mb4'
    )

    if ($SkipColumnNames) { $argsList += '--skip-column-names' }
    if ($Batch) { $argsList += '--batch' }

    if ($Database) { $argsList += $Database }

    if ($SqlFile) {
        if (-not (Test-Path $SqlFile)) { throw "SQL 文件不存在: $SqlFile" }
        $fileName = Split-Path -Leaf $SqlFile
        Write-LogCommand -Command "docker cp $SqlFile ${ContainerName}:/tmp/$fileName"
        docker cp $SqlFile "${ContainerName}:/tmp/$fileName" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '无法将 SQL 文件复制到容器内。' }
        $argsList += @('-e', "source /tmp/$fileName")
    }
    elseif ($Sql) {
        $argsList += @('-e', $Sql)
    }

    $commandString = "docker $($argsList -join ' ')"
    Write-LogCommand -Command $commandString

    if ($Interactive) {
        & docker $argsList
    }
    else {
        if ($Quiet) {
            $output = & docker $argsList 2>$null
        }
        else {
            $output = & docker $argsList 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            $err = if ($output) { ": $output" } else { '' }
            throw "MySQL 命令执行失败$err"
        }
        return $output
    }
}

function Invoke-MySqlDump {
    <#
    .SYNOPSIS
        通过 docker exec 执行 mysqldump 导出
    .PARAMETER Tables
        要导出的表名数组；为空则导出整个数据库
    .PARAMETER Databases
        要合并导出的多个数据库名数组，使用 --databases 参数
    #>
    param(
        [string]$ContainerName,
        [string]$Password,
        [string]$OutputPath,
        [string]$Database = '',
        [string]$Table = '',
        [string[]]$Tables = @(),
        [string[]]$Databases = @(),
        [switch]$AllDatabases
    )

    $argsList = @(
        'exec', '-e', "MYSQL_PWD=$Password", $ContainerName
        'mysqldump'
        '-h', '127.0.0.1'
        '-u', 'root'
        '--single-transaction', '--routines', '--triggers', '--events'
        '--set-gtid-purged=OFF'
    )

    if ($AllDatabases) {
        $argsList += '--all-databases'
    }
    elseif ($Databases) {
        $argsList += '--databases'
        $argsList += $Databases
    }
    else {
        if (-not $Database) { throw '未指定要导出的数据库。' }
        $argsList += $Database
        if ($Table) { $argsList += $Table }
        if ($Tables) { $argsList += $Tables }
    }

    $parentDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $commandString = "docker $($argsList -join ' ') > $OutputPath"
    Write-LogCommand -Command $commandString

    & docker $argsList > $OutputPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'mysqldump 导出失败。' }
    if (-not (Test-Path $OutputPath) -or (Get-Item $OutputPath).Length -eq 0) { throw '导出文件为空。' }
}

function Get-MySqlDatabases {
    <#
    .SYNOPSIS
        获取 MySQL 中所有用户数据库列表（排除四个系统库）
    .DESCRIPTION
        使用 SHOW DATABASES 命令，显式过滤 information_schema / mysql / performance_schema / sys，
        并对每行结果进行清洗，确保只返回真实存在的用户数据库名。
    #>
    param([string]$ContainerName, [string]$Password)

    $excluded = @('information_schema', 'mysql', 'performance_schema', 'sys')
    $result = Invoke-MySqlCli -ContainerName $ContainerName -Password $Password -Sql 'SHOW DATABASES;' -SkipColumnNames -Quiet
    if (-not $result) { return @() }

    # 显式转换为字符串数组，防止单条结果被当作标量字符串处理
    return [string[]]($result |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($_ -notin $excluded) } |
        Select-Object -Unique)
}

function Get-MySqlTables {
    <#
    .SYNOPSIS
        获取指定数据库中的所有表列表
    #>
    param([string]$ContainerName, [string]$Password, [string]$Database)
    $sql = "SELECT table_name FROM information_schema.tables WHERE table_schema = '$Database';"
    $result = Invoke-MySqlCli -ContainerName $ContainerName -Password $Password -Sql $sql -SkipColumnNames -Quiet
    if (-not $result) { return @() }
    return [string[]]($result |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-MySqlDatabaseExists {
    <#
    .SYNOPSIS
        检查指定数据库是否存在
    #>
    param([string]$ContainerName, [string]$Password, [string]$Database)
    $dbs = Get-MySqlDatabases -ContainerName $ContainerName -Password $Password
    return $dbs -contains $Database
}

function Read-MultiSelection {
    <#
    .SYNOPSIS
        提示用户输入空格分隔的序号，返回选中的条目数组
    .PARAMETER Items
        待选项数组
    .PARAMETER Prompt
        提示文本
    .OUTPUTS
        String[] 选中的条目；若用户取消返回空数组
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Items,

        [string]$Prompt = '请选择（多个序号用空格分隔，C 取消）'
    )

    do {
        $inputValue = Read-Host $Prompt
        if ($inputValue -eq 'C' -or $inputValue -eq 'c') { return @() }
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return @() }

        $indices = $inputValue -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
        $selected = $indices | Where-Object { $_ -ge 0 -and $_ -lt $Items.Count } | ForEach-Object { $Items[$_] }
        $selected = @($selected | Select-Object -Unique)

        if ($selected.Count -gt 0) { return $selected }
        Write-LogWarning '无效选择，请重新输入（或输入 C 取消）。'
    } while ($true)
}

function Get-MySqlColumns {
    <#
    .SYNOPSIS
        获取指定表的所有列名
    #>
    param(
        [string]$ContainerName,
        [string]$Password,
        [string]$Database,
        [string]$Table
    )
    $sql = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '$Database' AND TABLE_NAME = '$Table' ORDER BY ORDINAL_POSITION;"
    $result = Invoke-MySqlCli -ContainerName $ContainerName -Password $Password -Sql $sql -SkipColumnNames -Quiet
    if (-not $result) { return @() }
    return @($result | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Convert-TabRowToCsv {
    <#
    .SYNOPSIS
        将 mysql --batch 输出的一行（制表符分隔）转换为 CSV 行
    #>
    param([string]$Row)
    $fields = $Row.Split("`t")
    return ($fields | ForEach-Object {
        $val = $_
        if ($val -eq '\N') { $val = '' }
        $val = $val -replace '"', '""'
        '"' + $val + '"'
    }) -join ','
}

function Export-MySqlTablesToCsv {
    <#
    .SYNOPSIS
        将指定数据库中的一个或多个表导出为 CSV 文件
    .PARAMETER OutputDir
        输出目录，每个表生成一个 <表名>.csv 文件
    #>
    [CmdletBinding()]
    param(
        [string]$ContainerName,
        [string]$Password,
        [string]$Database,
        [string[]]$Tables,
        [string]$OutputDir
    )

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

    foreach ($table in $Tables) {
        $columns = Get-MySqlColumns -ContainerName $ContainerName -Password $Password -Database $Database -Table $table
        if ($columns.Count -eq 0) { throw "无法获取表 [$table] 的列信息。" }

        $header = ($columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','
        $sql = 'SELECT * FROM `' + $Database + '`.`' + $table + '`;'
        $rows = Invoke-MySqlCli -ContainerName $ContainerName -Password $Password -Sql $sql -SkipColumnNames -Batch -Quiet

        $outFile = Join-Path $OutputDir "$table.csv"
        $lines = [System.Collections.Generic.List[string]]::new()
        [void]$lines.Add($header)
        if ($rows) {
            $rows | ForEach-Object { [void]$lines.Add((Convert-TabRowToCsv -Row $_)) }
        }

        # 使用 UTF-8 BOM 写入，确保 Excel 等工具打开中文不乱码
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllLines($outFile, $lines.ToArray(), $utf8Bom)
        Write-LogInfo "已导出 CSV: $outFile"
    }
}

function Export-ContainerLog {
    param([string]$ContainerName, [string]$OutputPath)
    $parentDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    & docker logs $ContainerName > $OutputPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw '容器日志导出失败。' }
}

function Export-MySqlLogFile {
    param([string]$ContainerName, [string]$LogName, [string]$OutputPath)
    $parentDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    docker cp "${ContainerName}:/var/log/mysql/$LogName" $OutputPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "无法复制日志文件 $LogName。" }
}

#endregion

#region UI 辅助

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Read-HostChoice {
    param(
        [string]$Prompt,
        [System.Collections.Specialized.OrderedDictionary]$Options,
        [string]$DefaultKey = ''
    )

    $index = 1
    $keyByIndex = @{}
    Write-Host "`n$Prompt" -ForegroundColor Cyan
    foreach ($key in $Options.Keys) {
        Write-Host "  [$index] $($Options[$key])" -ForegroundColor Gray
        $keyByIndex["$index"] = $key
        $index++
    }

    do {
        $hint = if ($DefaultKey) { " (默认: $DefaultKey)" } else { '' }
        $inputValue = Read-Host "请选择$hint"
        if ([string]::IsNullOrWhiteSpace($inputValue) -and $DefaultKey) { return $DefaultKey }
        if ($Options.Contains($inputValue)) { return $inputValue }
        if ($keyByIndex.Contains($inputValue)) { return $keyByIndex[$inputValue] }
        Write-LogWarning '无效选择，请重新输入。'
    } while ($true)
}

function Select-FromList {
    <#
    .SYNOPSIS
        从列表中选择一项，支持手动输入和取消
    .PARAMETER AllowCancel
        允许用户输入 C 取消并返回空字符串
    #>
    param(
        [string]$Title,
        [string[]]$Items,
        [switch]$AllowManual,
        [switch]$AllowCancel
    )

    if (-not $Items -and -not $AllowManual) { throw '列表为空且不允许手动输入。' }

    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Items[$i])" -ForegroundColor Gray
    }
    if ($AllowManual) { Write-Host '  [M] 手动输入' -ForegroundColor Gray }
    if ($AllowCancel) { Write-Host '  [C] 取消/返回' -ForegroundColor Gray }

    do {
        $inputValue = Read-Host '请选择'
        if ($AllowCancel -and ($inputValue -eq 'C' -or $inputValue -eq 'c')) { return '' }
        if ($inputValue -match '^\d+$') {
            $idx = [int]$inputValue - 1
            if ($idx -ge 0 -and $idx -lt $Items.Count) { return $Items[$idx] }
        }
        if ($AllowManual -and ($inputValue -eq 'M' -or $inputValue -eq 'm')) {
            $manual = Read-Host '请输入名称（B 取消）'
            if ($manual -eq 'B' -or $manual -eq 'b') { continue }
            if ($manual) { return $manual }
        }
        if ($Items -contains $inputValue) { return $inputValue }
        Write-LogWarning '无效选择，请重新输入。'
    } while ($true)
}

function Show-SelectionListWithMarkers {
    <#
    .SYNOPSIS
        显示带圆点/空格标记的选择列表
    .PARAMETER SelectedItems
        已选中的条目集合（List[string]）
    #>
    param(
        [string]$Title,
        [string[]]$Items,
        [System.Collections.Generic.List[string]]$SelectedItems = @()
    )

    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $marker = if ($SelectedItems.Contains($Items[$i])) { '[•]' } else { '[ ]' }
        Write-Host "  $marker [$($i + 1)] $($Items[$i])" -ForegroundColor Gray
    }
}

function Read-MultiSelectionWithMarkers {
    <#
    .SYNOPSIS
        交互式多选：输入空格分隔序号切换选中状态，Enter 确认，C 取消
    .PARAMETER Single
        仅允许选择一个
    .OUTPUTS
        String[] 选中的条目；取消返回空数组
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string[]]$Items,

        [switch]$Single
    )

    if (-not $Items) { throw '列表为空，无法选择。' }

    $selected = New-Object System.Collections.Generic.List[string]

    do {
        Show-SelectionListWithMarkers -Title $Title -Items $Items -SelectedItems $selected

        if ($Single) {
            Write-Host '  [M] 手动输入' -ForegroundColor Gray
            Write-Host '  [C] 取消' -ForegroundColor Gray
            $prompt = '请输入序号（Enter 确认当前选择）'
        }
        else {
            Write-Host '  输入空格分隔序号可切换选中，再次输入同一序号取消选中' -ForegroundColor DarkGray
            Write-Host '  [M] 手动输入' -ForegroundColor Gray
            Write-Host '  [C] 取消' -ForegroundColor Gray
            $prompt = '请选择（Enter 确认，空格分隔序号切换）'
        }

        $inputValue = Read-Host $prompt
        if ($inputValue -eq 'C' -or $inputValue -eq 'c') { return [string[]]@() }
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            if ($selected.Count -gt 0) {
                Write-LogInfo "已选择: $($selected -join ', ')"
                return [string[]]$selected.ToArray()
            }
            Write-LogWarning '尚未选择任何项。'
            continue
        }
        if ($inputValue -eq 'M' -or $inputValue -eq 'm') {
            $manual = Read-Host '请输入名称（B 取消）'
            if ($manual -eq 'B' -or $manual -eq 'b') { continue }
            if (-not [string]::IsNullOrWhiteSpace($manual)) {
                Write-LogInfo "已选择: $manual"
                if ($Single) { return [string[]]@($manual) }
                if (-not $selected.Contains($manual)) { [void]$selected.Add($manual) }
            }
            continue
        }

        $indices = $inputValue -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
        foreach ($idx in $indices) {
            if ($idx -ge 0 -and $idx -lt $Items.Count) {
                $item = $Items[$idx]
                if ($selected.Contains($item)) {
                    [void]$selected.Remove($item)
                }
                else {
                    if ($Single) { $selected.Clear() }
                    [void]$selected.Add($item)
                }
            }
        }
    } while ($true)
}

function Select-MySqlDatabases {
    <#
    .SYNOPSIS
        统一的数据库选择入口，支持 a（全部）/ s（选择）/ m（手动输入）三种模式
    .PARAMETER Single
        只允许选择一个数据库，此时不显示 [A] 全部模式
    .OUTPUTS
        String[] 选中的数据库名数组；取消返回空数组
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [switch]$Single
    )

    [string[]]$databases = Get-MySqlDatabases -ContainerName $ContainerName -Password $Password
    if (-not $databases) { throw '没有可选择的数据库。' }

    # 明确告知可用数据库数量及名称，并说明已排除系统库
    Write-Host "`n当前共有 $($databases.Count) 个数据库（已排除 information_schema / mysql / performance_schema / sys）：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $databases.Count; $i++) {
        Write-Host "  [$($i + 1)] $($databases[$i])" -ForegroundColor Gray
    }
    Write-Host ''

    if ($Single) {
        Write-Host '请选择模式：' -ForegroundColor Cyan
        Write-Host '  [S] 滑动/列表选择' -ForegroundColor Gray
        Write-Host '  [M] 手动输入数据库名' -ForegroundColor Gray
        Write-Host '  [C] 取消' -ForegroundColor Gray
    }
    else {
        Write-Host '请选择模式：' -ForegroundColor Cyan
        Write-Host '  [A] 全部导出：导出所有数据库' -ForegroundColor Gray
        Write-Host '  [S] 选择导出：选择部分数据库' -ForegroundColor Gray
        Write-Host '  [M] 手动输入数据库名' -ForegroundColor Gray
        Write-Host '  [C] 取消' -ForegroundColor Gray
    }

    do {
        $mode = Read-Host '请选择模式'

        if ($mode -eq 'C' -or $mode -eq 'c') { return [string[]]@() }

        if ($mode -eq 'A' -or $mode -eq 'a') {
            if ($Single) {
                Write-LogWarning '当前场景仅允许连接一个数据库，不支持“全部”模式。'
                continue
            }
            return [string[]]$databases
        }

        if ($mode -eq 'M' -or $mode -eq 'm') {
            $manual = Read-Host '请输入数据库名（B 取消）'
            if ($manual -eq 'B' -or $manual -eq 'b') { continue }
            if ([string]::IsNullOrWhiteSpace($manual)) { continue }
            if (-not (Test-MySqlDatabaseExists -ContainerName $ContainerName -Password $Password -Database $manual)) {
                Write-LogWarning "数据库 [$manual] 不存在。"
                continue
            }
            return [string[]]@($manual)
        }

        if ($mode -eq 'S' -or $mode -eq 's') {
            $title = if ($Single) { '请选择要连接的数据库' } else { '请选择要导出的数据库（可多选）' }
            return [string[]](Read-MultiSelectionWithMarkers -Title $title -Items $databases -Single:$Single)
        }

        $validOptions = if ($Single) { 'M/S/C' } else { 'A/M/S/C' }
        Write-LogWarning "无效选择，请重新输入（$validOptions）。"
    } while ($true)
}

function Select-MySqlTablesForExport {
    <#
    .SYNOPSIS
        表级导出选择：全部 / 选择部分 / 指定表名
    .OUTPUTS
        Hashtable：@{ All = $true } 或 @{ Tables = @('t1','t2') }；取消返回 $null
    #>
    param(
        [string]$ContainerName,
        [string]$Password,
        [string]$Database
    )

    [string[]]$tables = Get-MySqlTables -ContainerName $ContainerName -Password $Password -Database $Database

    Write-LogStep "已选择数据库 [$Database]，请选择表级导出方式"
    Write-Host '  [A] 全部导出：导出该数据库所有表' -ForegroundColor Gray
    if ($tables) { Write-Host '  [S] 选择导出：选择该数据库中的部分表' -ForegroundColor Gray }
    Write-Host '  [Z] 指定导出：指定特定表进行导出' -ForegroundColor Gray
    Write-Host '  [C] 取消' -ForegroundColor Gray

    do {
        $choice = Read-Host '请选择'
        if ($choice -eq 'C' -or $choice -eq 'c') { return $null }
        if ($choice -eq 'A' -or $choice -eq 'a') { return @{ All = $true } }

        if ($choice -eq 'S' -or $choice -eq 's') {
            if (-not $tables) {
                Write-LogWarning "数据库 [$Database] 中没有表，将导出整个数据库。"
                return @{ All = $true }
            }
            $selected = @(Read-MultiSelectionWithMarkers -Title '请选择要导出的表' -Items $tables)
            if ($selected.Count -eq 0) {
                Write-LogInfo '未选择表，将导出整个数据库。'
                return @{ All = $true }
            }
            return @{ Tables = $selected }
        }

        if ($choice -eq 'Z' -or $choice -eq 'z') {
            $specified = Read-Host '请输入表名（多个用空格分隔，B 取消）'
            if ($specified -eq 'B' -or $specified -eq 'b') { continue }
            $tableList = @($specified -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            if ($tableList.Count -eq 0) {
                Write-LogWarning '未输入表名，将导出整个数据库。'
                return @{ All = $true }
            }
            return @{ Tables = $tableList }
        }

        Write-LogWarning '无效选择，请重新输入（A/S/Z/C）。'
    } while ($true)
}

function Select-TableWithFuzzySearch {
    param([string]$Database, [string[]]$Tables)

    if (-not $Tables) {
        Write-LogWarning "数据库 [$Database] 中没有表。"
        return ''
    }

    $currentItems = $Tables
    do {
        Write-Host "`n数据库 [$Database] 中的表:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $currentItems.Count; $i++) {
            Write-Host "  [$($i + 1)] $($currentItems[$i])" -ForegroundColor Gray
        }
        Write-Host '  [M] 手动输入表名' -ForegroundColor Gray
        Write-Host '  [F] 输入关键字过滤列表' -ForegroundColor Gray
        Write-Host '  [Enter] 不选表，导出整个数据库' -ForegroundColor Gray

        $inputValue = Read-Host '请选择'
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return '' }
        if ($inputValue -match '^\d+$') {
            $idx = [int]$inputValue - 1
            if ($idx -ge 0 -and $idx -lt $currentItems.Count) { return $currentItems[$idx] }
        }
        if ($inputValue -eq 'M' -or $inputValue -eq 'm') {
            $manual = Read-Host '请输入表名'
            if ($manual) { return $manual }
        }
        if ($inputValue -eq 'F' -or $inputValue -eq 'f') {
            $keyword = Read-Host '请输入关键字（支持模糊匹配）'
            if ($keyword) {
                $filtered = $Tables | Where-Object { $_ -like "*$keyword*" }
                if ($filtered) { $currentItems = $filtered }
                else {
                    Write-LogWarning '未找到匹配的表，显示全部列表。'
                    $currentItems = $Tables
                }
            }
            continue
        }
        Write-LogWarning '无效选择，请重新输入。'
    } while ($true)
}

function Test-DockerImageExists {
    <#
    .SYNOPSIS
        使用 docker manifest inspect 检查远端镜像是否存在（不下载）
    .PARAMETER ImageSpec
        完整镜像规格，如 mysql:8.0
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageSpec
    )

    try {
        & docker manifest inspect $ImageSpec 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Search-DockerImages {
    <#
    .SYNOPSIS
        使用 docker search 搜索镜像
    .PARAMETER Keyword
        搜索关键词
    .PARAMETER Limit
        返回结果数量上限
    .OUTPUTS
        PSCustomObject[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Keyword,

        [int]$Limit = 20
    )

    Write-LogInfo "正在搜索镜像: $Keyword ..."
    $lines = docker search $Keyword --limit $Limit --format '{{.Name}}\t{{.Description}}\t{{.IsOfficial}}\t{{.StarCount}}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker search 执行失败: $lines" }

    $results = @()
    foreach ($line in $lines) {
        $parts = $line -split "`t", 4
        if ($parts.Count -lt 4) { continue }
        $results += [PSCustomObject]@{
            Name        = $parts[0]
            Description = $parts[1]
            IsOfficial  = $parts[2]
            StarCount   = $parts[3]
        }
    }
    return $results
}

function Select-DockerImage {
    <#
    .SYNOPSIS
        交互式选择 Docker 镜像
    .DESCRIPTION
        支持 docker search 搜索、手动输入、常用列表三种方式
    .OUTPUTS
        String 选中的镜像名
    #>
    [CmdletBinding()]
    param()

    $modeOptions = [ordered]@{
        'search' = 'Docker 搜索镜像（推荐）'
        'manual' = '手动输入镜像名'
        'common' = '从常用镜像列表选择'
    }

    $mode = Read-HostChoice -Prompt '请选择镜像获取方式' -Options $modeOptions

    switch ($mode) {
        'search' {
            $keyword = 'mysql'
            Write-LogInfo "正在使用关键词 [$keyword] 搜索镜像..."

            try {
                $images = Search-DockerImages -Keyword $keyword -Limit 15
            }
            catch {
                Write-LogWarning $_.Exception.Message
                Write-LogInfo '将切换到手动输入方式。'
                $mode = 'manual'
            }

            if ($mode -eq 'search') {
                # 始终确保官方 mysql 在结果中
                $hasOfficial = $images | Where-Object { $_.Name -eq 'mysql' }
                if (-not $hasOfficial) {
                    $officialMysql = [PSCustomObject]@{
                        Name        = 'mysql'
                        Description = 'MySQL Official Image'
                        IsOfficial  = 'True'
                        StarCount   = 'official'
                    }
                    $images = @($officialMysql) + $images
                }

                if (-not $images) {
                    Write-LogWarning '未找到匹配的镜像。'
                    $mode = 'manual'
                }
                else {
                    Write-Host "`n搜索结果:" -ForegroundColor Cyan
                    Write-Host ('{0,-4} {1,-30} {2,-10} {3,-8} {4}' -f '序号', '镜像名称', '官方', 'Stars', '描述') -ForegroundColor Gray
                    Write-Host ('-' * 90) -ForegroundColor Gray
                    for ($i = 0; $i -lt $images.Count; $i++) {
                        $official = if ($images[$i].IsOfficial -eq 'True') { '[官方]' } else { '' }
                        $desc = if ($images[$i].Description.Length -gt 40) { $images[$i].Description.Substring(0, 37) + '...' } else { $images[$i].Description }
                        Write-Host ('[{0,-2}] {1,-30} {2,-10} {3,-8} {4}' -f ($i + 1), $images[$i].Name, $official, $images[$i].StarCount, $desc) -ForegroundColor White
                    }
                    Write-Host '  [M] 手动输入镜像名' -ForegroundColor Gray

                    do {
                        $inputValue = Read-Host '请选择镜像'
                        if ($inputValue -match '^\d+$') {
                            $idx = [int]$inputValue - 1
                            if ($idx -ge 0 -and $idx -lt $images.Count) { return $images[$idx].Name }
                        }
                        if ($inputValue -eq 'M' -or $inputValue -eq 'm') { break }
                        Write-LogWarning '无效选择，请重新输入。'
                    } while ($true)
                }
            }
        }
        'common' {
            $commonImages = [ordered]@{
                'mysql' = 'mysql (官方 MySQL)'
            }
            $choice = Read-HostChoice -Prompt '请选择常用 MySQL 镜像' -Options $commonImages
            return $choice
        }
    }

    # manual 或搜索失败后的兜底
    $manual = Read-Host '请输入完整镜像名（例如 mysql、bitnami/mysql、registry.example.com/mysql）'
    if ([string]::IsNullOrWhiteSpace($manual)) { throw '镜像名不能为空。' }
    return $manual
}

function Get-DockerImageTags {
    <#
    .SYNOPSIS
        从 Docker Hub API 获取镜像 tag 列表
    .PARAMETER ImageName
        镜像名，如 mysql 或 bitnami/mysql
    .PARAMETER Limit
        返回数量上限
    .OUTPUTS
        String[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName,

        [int]$Limit = 30
    )

    # 解析命名空间和仓库名
    $parts = $ImageName -split '/'
    if ($parts.Count -eq 1) {
        $namespace = 'library'
        $repo = $parts[0]
    }
    else {
        $namespace = $parts[0]
        $repo = $parts[1]
    }

    $url = "https://hub.docker.com/v2/repositories/${namespace}/${repo}/tags/?page_size=$Limit"
    Write-LogInfo "正在获取镜像 $ImageName 的版本列表..."

    try {
        $response = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 15 -UseBasicParsing
        if ($response.results) {
            return $response.results | Select-Object -ExpandProperty name | Sort-Object
        }
        return @()
    }
    catch {
        Write-LogWarning "无法从 Docker Hub 获取版本列表: $_"
        return @()
    }
}

function Select-DockerImageTag {
    <#
    .SYNOPSIS
        选择或手动输入镜像 tag，并验证有效性
    .PARAMETER ImageName
        镜像名
    .OUTPUTS
        String tag
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName
    )

    $tags = Get-DockerImageTags -ImageName $ImageName -Limit 20

    if ($tags.Count -gt 0) {
        Write-Host "`n镜像 [$ImageName] 的可用版本/tag（前 20 个）:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $tags.Count; $i++) {
            Write-Host "  [$($i + 1)] $($tags[$i])" -ForegroundColor Gray
        }
        Write-Host '  [M] 手动输入版本/tag' -ForegroundColor Gray

        do {
            $inputValue = Read-Host '请选择版本'
            if ($inputValue -match '^\d+$') {
                $idx = [int]$inputValue - 1
                if ($idx -ge 0 -and $idx -lt $tags.Count) {
                    $selected = $tags[$idx]
                    # 从 Docker Hub API 列表中选择的 tag，直接认为有效
                    Write-LogSuccess "已选择版本: $selected"
                    return $selected
                }
            }
            if ($inputValue -eq 'M' -or $inputValue -eq 'm') { break }
            Write-LogWarning '无效选择，请重新输入。'
        } while ($true)
    }
    else {
        Write-LogWarning '未能获取版本列表，请手动输入。'
    }

    # 手动输入并验证
    do {
        $manual = Read-Host '请输入版本/tag（例如 latest、8.0、10.11）'
        if ([string]::IsNullOrWhiteSpace($manual)) {
            Write-LogWarning '版本/tag 不能为空。'
            continue
        }

        $imageSpec = "$($ImageName):$($manual)"
        Write-LogInfo "正在验证 $imageSpec ..."
        if (Test-DockerImageExists -ImageSpec $imageSpec) {
            Write-LogSuccess "镜像 $imageSpec 验证通过。"
            return $manual
        }

        Write-LogWarning "无法验证 $imageSpec（可能不存在或网络不通）。"
        $choice = Read-Host '请选择: (R)重新输入, (S)跳过验证使用该版本, (C)取消'
        switch ($choice.ToUpper()) {
            'R' { continue }
            'S' { return $manual }
            default { throw '已取消版本选择。' }
        }
    } while ($true)
}

function Test-ContainerNameValid {
    <#
    .SYNOPSIS
        验证容器名是否符合 Docker 命名规范
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -lt 2 -or $Name.Length -gt 64) { return $false }
    if ($Name -match '^[-]') { return $false }
    if ($Name -match '[^a-zA-Z0-9_.-]') { return $false }
    return $true
}

function Read-ContainerName {
    <#
    .SYNOPSIS
        交互式读取并验证容器名
    #>
    [CmdletBinding()]
    param(
        [string]$DefaultName = 'mysql-locals'
    )

    do {
        $name = Read-Host "请输入容器名称（默认: $DefaultName）"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $DefaultName }
        if (Test-ContainerNameValid -Name $name) { return $name }
        Write-LogWarning '容器名不规范：长度 2-64，只能包含字母、数字、下划线、点、短横线，且不能以短横线开头。'
    } while ($true)
}

function Read-HostPort {
    <#
    .SYNOPSIS
        交互式读取主机端口并检测占用
    #>
    [CmdletBinding()]
    param(
        [string]$DefaultPort = '3308'
    )

    do {
        $port = Read-Host "请输入主机映射端口（默认: $DefaultPort）"
        if ([string]::IsNullOrWhiteSpace($port)) { $port = $DefaultPort }
        if ($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) {
            Write-LogWarning '端口号必须是 1-65535 之间的数字。'
            continue
        }
        if (Test-PortAvailable -Port $port) { return $port }
        Write-LogWarning "端口 $port 已被占用，请选择其他端口。"
    } while ($true)
}

function Build-DockerRunCommand {
    <#
    .SYNOPSIS
        构建 docker run 命令参数数组
    .OUTPUTS
        Hashtable 包含 Args 和 ImageSpec
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $cnfHost   = ($Config.ConfDir -replace '\\', '/')
    $dataHost  = ($Config.DataDir -replace '\\', '/')
    $logHost   = ($Config.LogDir -replace '\\', '/')
    $imageSpec = "$($Config.Image):$($Config.Version)"

    $args = @(
        'run', '-d'
        '--name', $Config.ContainerName
        '--restart', 'unless-stopped'
        '-p', "$($Config.Port):3306"
        '-e', "MYSQL_ROOT_PASSWORD=$Password"
        '-e', "MYSQL_PWD=$Password"
        '-e', "MYSQL_DATABASE=$($Config.DefaultDb)"
        '-v', "${cnfHost}:/etc/mysql/conf.d"
        '-v', "${dataHost}:/var/lib/mysql"
        '-v', "${logHost}:/var/log/mysql"
        '--health-cmd', "mysqladmin ping -h localhost -u root"
        '--health-interval', '10s'
        '--health-timeout', '5s'
        '--health-retries', '10'
        '--entrypoint', 'sh'
        $imageSpec
        '-c', "chmod 644 /etc/mysql/conf.d/my.cnf && exec /usr/local/bin/docker-entrypoint.sh mysqld"
    )

    return @{
        Args      = $args
        ImageSpec = $imageSpec
        Command   = "docker $($args -join ' ')"
    }
}

function Show-DockerRunPreview {
    <#
    .SYNOPSIS
        展示 docker run 命令预览
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $preview = Build-DockerRunCommand -Config $Config -Password $Password
    $maskedCommand = $preview.Command -replace "MYSQL_ROOT_PASSWORD=$([regex]::Escape($Password))", 'MYSQL_ROOT_PASSWORD=********'
    Write-Host "`n========== 容器创建命令预览 ==========" -ForegroundColor Cyan
    Write-Host $maskedCommand -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "配置摘要:" -ForegroundColor Gray
    Write-Host "  镜像: $($preview.ImageSpec)" -ForegroundColor Gray
    Write-Host "  容器名: $($Config.ContainerName)" -ForegroundColor Gray
    Write-Host "  端口映射: $($Config.Port) -> 3306" -ForegroundColor Gray
    Write-Host "  默认数据库: $($Config.DefaultDb)" -ForegroundColor Gray
    Write-Host "  数据目录: $($Config.DataDir)" -ForegroundColor Gray
    Write-Host ''
    return $preview
}

function Confirm-Action {
    param([string]$Message)
    $choice = Read-Host "$Message (y/N)"
    return $choice -eq 'y' -or $choice -eq 'Y'
}

function Pause-AnyKey {
    Write-Host "`n按任意键继续..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

#endregion

#region 菜单动作

function Start-MySqlContainer {
    <#
    .SYNOPSIS
        启动/重建 MySQL 容器
    #>
    param(
        [switch]$Force,
        [switch]$SkipPreview
    )

    $config = Get-ProjectConfig
    $ContainerName = $config.ContainerName
    $Port = $config.Port
    $DefaultDb = $config.DefaultDb
    $Version = $config.Version

    Write-LogStep 'Docker 环境检测'
    if (-not (Test-DockerAvailable)) { throw 'Docker 未运行或未安装。' }
    Write-LogSuccess 'Docker 运行正常。'

    # 若容器不存在，询问用户确认容器名
    if (-not (Test-ContainerExists -ContainerName $ContainerName)) {
        Write-LogStep '配置容器名称'
        Write-Host "容器尚未创建，当前默认容器名: $ContainerName" -ForegroundColor Cyan
        $customName = Read-Host '请输入想要的容器名（直接回车使用默认值，B 取消）'
        if ($customName -eq 'B' -or $customName -eq 'b') {
            Write-LogInfo '已取消。'
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($customName)) {
            if (-not (Test-ContainerNameValid -Name $customName)) {
                throw '容器名不符合规范：长度 2-64，只能包含字母、数字、下划线、点、短横线，且不能以短横线开头。'
            }
            $ContainerName = $customName
            $config.ContainerName = $ContainerName
            Save-ProjectConfig -Config $config
            Write-LogSuccess "容器名已设置为: $ContainerName"
        }
    }

    Write-LogStep "端口 $Port 占用检查"
    if (-not (Test-PortAvailable -Port $Port)) {
        Write-LogWarning "端口 $Port 已被占用，请选择其他端口。"
        $newPort = Read-Host '请输入其他端口号，或按 Enter 取消'
        if ($newPort -notmatch '^\d+$') { throw '未提供有效端口，已取消。' }
        $Port = $newPort
        $config.Port = $Port

        $suggestedName = "mysql-locals-$Port"
        if ($ContainerName -ne $suggestedName) {
            Write-Host "端口已变更为 $Port，建议容器名同步为 $suggestedName" -ForegroundColor Cyan
            $nameChoice = Read-Host "是否修改容器名？（Y 修改 / N 保留 $ContainerName）"
            if ($nameChoice -eq 'Y' -or $nameChoice -eq 'y') {
                $ContainerName = $suggestedName
                $config.ContainerName = $ContainerName
            }
        }
        else {
            $ContainerName = $suggestedName
            $config.ContainerName = $ContainerName
        }
        Save-ProjectConfig -Config $config
    }
    else {
        Write-LogSuccess "端口 $Port 可用。"
    }

    $password = Get-MySqlPasswordOnce

    Write-LogStep '准备目录和配置文件'
    # 校验路径非空
    if (-not $config.ConfDir -or -not $config.DataDir -or -not $config.LogDir) {
        throw "配置路径不完整: ConfDir=$($config.ConfDir), DataDir=$($config.DataDir), LogDir=$($config.LogDir)"
    }
    @($config.ConfDir, $config.DataDir, $config.LogDir) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    $cnfFile = Join-Path $config.ConfDir 'my.cnf'
    if (-not (Test-Path $cnfFile)) {
        $cnfContent = @"
[mysqld]
port=3306                         # 容器内固定 3306，不要改
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-time-zone='+08:00'
max_connections=200
innodb_buffer_pool_size=256M

# 日志配置
log-error=/var/log/mysql/error.log
general_log=1
general_log_file=/var/log/mysql/general.log
slow_query_log=1
slow_query_log_file=/var/log/mysql/slow.log
long_query_time=2

[client]
default-character-set=utf8mb4
"@
        $cnfContent = $cnfContent -replace "`r`n", "`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($cnfFile, $cnfContent, $utf8NoBom)
        Write-LogSuccess "已生成 my.cnf"
    }

    Write-LogStep "容器 $ContainerName 状态检查"
    if (Test-ContainerExists -ContainerName $ContainerName) {
        Write-LogWarning "容器 $ContainerName 已存在"
        if ($Force -or (Confirm-Action -Message '是否删除并重建容器？')) {
            docker rm -f $ContainerName | Out-Null
        }
        else {
            Write-LogInfo '已取消。'
            return
        }
    }

    $image = "$($config.Image):$Version"
    Write-LogStep "镜像 $image 检查"
    $localImage = docker images --format '{{.Repository}}:{{.Tag}}' | Where-Object { $_ -eq $image }
    if (-not $localImage) {
        Write-LogInfo "正在拉取 $image ..."
        docker pull $image
        if ($LASTEXITCODE -ne 0) { throw '镜像拉取失败。' }
    }

    # 命令预览
    if (-not $SkipPreview) {
        Show-DockerRunPreview -Config $config -Password $password | Out-Null
        if (-not (Confirm-Action -Message '是否执行上述命令创建容器？')) {
            Write-LogInfo '已取消容器创建。'
            return
        }
    }

    Write-LogStep '启动 MySQL 容器'
    $preview = Build-DockerRunCommand -Config $config -Password $password
    $maskedCommand = $preview.Command -replace "MYSQL_ROOT_PASSWORD=$([regex]::Escape($password))", 'MYSQL_ROOT_PASSWORD=********'
    Write-LogInfo "执行命令: $maskedCommand"
    & docker @($preview.Args)
    if ($LASTEXITCODE -ne 0) { throw '容器启动失败。' }

    Write-LogStep '等待 MySQL 就绪'
    $healthy = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 2
        $status = docker inspect --format '{{.State.Health.Status}}' $ContainerName 2>$null
        if ($status -eq 'healthy') { $healthy = $true; break }
    }
    if ($healthy) { Write-LogSuccess 'MySQL 已就绪！' }
    else { Write-LogWarning '健康检查超时，请手动验证。' }

    # 展示容器状态
    Show-ContainerStatusUI

    # 如果配置的是 latest，尝试解析真实版本号并写回配置
    if ($Version -eq 'latest') {
        Write-LogStep '解析 latest 对应的真实版本号'
        $trueVersion = Get-MySqlTrueVersion -ImageSpec $image
        if ($trueVersion) {
            Write-LogSuccess "latest 对应的真实版本为: $trueVersion"
            $config.Version = $trueVersion
            Save-ProjectConfig -Config $config
            Write-LogInfo "已将配置中的 Version 更新为: $trueVersion"
        }
        else {
            Write-LogWarning '无法解析 latest 对应的真实版本号。'
        }
    }

    # 生成 mysql_info.txt（不含密码）
    $info = @()
    $info += '=========================================='
    $info += '  MySQL 容器部署信息'
    $info += "  生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $info += '=========================================='
    $info += "容器名称   : $ContainerName"
    $info += "端口映射   : $Port -> 3306"
    $info += "默认数据库 : $DefaultDb"
    $info += "数据目录   : $($config.ProjectPath)"
    $info += ''
    $info += '连接命令:'
    $info += "  mysql -h 127.0.0.1 -P $Port -u root -p"
    $info += "  docker exec -it $ContainerName mysql -uroot -p"
    $info += ''
    $info += '常用管理:'
    $info += "  查看日志: docker logs $ContainerName"
    $info += "  停止容器: docker stop $ContainerName"
    $info += "  删除容器: docker rm -f $ContainerName"
    $info += '=========================================='
    $infoFile = Join-Path $config.ProjectPath 'mysql_info.txt'
    $info -join "`r`n" | Out-File -FilePath $infoFile -Encoding UTF8
    Write-LogSuccess "部署信息已保存到: $infoFile"

    Write-Host "`n========== 部署成功 ==========" -ForegroundColor Green
    $info | ForEach-Object { Write-Host $_ -ForegroundColor White }
    Write-Host ''
    Write-Host "  root 密码: $password" -ForegroundColor Yellow
    Write-Host '  （请妥善保存，此密码不会写入任何文件）' -ForegroundColor Gray
}

function Connect-MySql {
    <#
    .SYNOPSIS
        直接连接 MySQL 交互终端，不预先选择数据库
    #>
    $config = Get-ProjectConfig
    Assert-ContainerRunning -ContainerName $config.ContainerName
    $password = Get-MySqlPasswordOnce

    Write-LogStep '正在连接 MySQL 服务器'
    Write-Host '输入 exit 或 quit 退出 MySQL 终端' -ForegroundColor Gray
    Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Interactive
}

function Execute-SqlFile {
    <#
    .SYNOPSIS
        执行本地 SQL 文件（支持取消）
    #>
    $config = Get-ProjectConfig
    Assert-ContainerRunning -ContainerName $config.ContainerName
    $password = Get-MySqlPasswordOnce

    Write-LogStep '请选择要执行的数据库'
    $selected = @(Select-MySqlDatabases -ContainerName $config.ContainerName -Password $password -Single)
    if ($selected.Count -eq 0) {
        Write-LogInfo '已取消。'
        return
    }
    $db = $selected[0]

    $sqlFile = Read-Host '请输入 SQL 文件完整路径（B 取消）'
    if ($sqlFile -eq 'B' -or $sqlFile -eq 'b') {
        Write-LogInfo '已取消。'
        return
    }
    if (-not (Test-Path $sqlFile)) { throw "SQL 文件不存在: $sqlFile" }

    if (-not (Confirm-Action -Message "确认在 [$db] 中执行 $sqlFile ?")) {
        Write-LogInfo '已取消。'
        return
    }

    Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Database $db -SqlFile $sqlFile
    Write-LogSuccess 'SQL 文件执行完成。'
}

function Import-SqlFile {
    <#
    .SYNOPSIS
        导入 SQL 文件到指定库（支持取消）
    #>
    $config = Get-ProjectConfig
    Assert-ContainerRunning -ContainerName $config.ContainerName
    $password = Get-MySqlPasswordOnce

    Write-LogStep '请选择要导入的目标数据库'
    $selected = @(Select-MySqlDatabases -ContainerName $config.ContainerName -Password $password -Single)
    if ($selected.Count -eq 0) {
        Write-LogInfo '已取消。'
        return
    }
    $db = $selected[0]

    $sqlFile = Read-Host '请输入要导入的 SQL 文件完整路径（B 取消）'
    if ($sqlFile -eq 'B' -or $sqlFile -eq 'b') {
        Write-LogInfo '已取消。'
        return
    }
    if (-not (Test-Path $sqlFile)) { throw "SQL 文件不存在: $sqlFile" }

    if (-not (Confirm-Action -Message "确认导入到 [$db] ?")) {
        Write-LogInfo '已取消。'
        return
    }

    Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Database $db -SqlFile $sqlFile
    Write-LogSuccess '导入完成。'
}

function Get-MySqlDdlForTables {
    <#
    .SYNOPSIS
        获取指定数据库中一个或多个表的 DDL 语句（仅结构，不包含数据）
    .OUTPUTS
        String DDL 文本
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string[]]$Tables
    )

    if (-not $Tables) { return '' }

    $argsList = @(
        'exec', '-e', "MYSQL_PWD=$Password", $ContainerName
        'mysqldump'
        '-h', '127.0.0.1'
        '-u', 'root'
        '--no-data'
        '--single-transaction'
        '--set-gtid-purged=OFF'
        $Database
    )
    $argsList += $Tables

    $commandString = "docker $($argsList -join ' ')"
    Write-LogCommand -Command $commandString

    $output = & docker $argsList 2>$null
    if ($LASTEXITCODE -ne 0) { throw '获取表 DDL 失败。' }
    return $output
}

function Export-MySqlDatabase {
    <#
    .SYNOPSIS
        导出数据库/表：支持库级多选（a/m/s）、单库表级导出（全部/选择/指定）、SQL/CSV/SQL+CSV 格式
        库级不支持合并导出，仅支持表级多选合并导出
    #>
    $config = Get-ProjectConfig
    Assert-ContainerRunning -ContainerName $config.ContainerName
    $password = Get-MySqlPasswordOnce

    # 1. 选择数据库（A 全部 / S 选择 / M 手动）
    Write-LogStep '请选择要导出的数据库'
    $selectedDbs = @(Select-MySqlDatabases -ContainerName $config.ContainerName -Password $password)
    if ($selectedDbs.Count -eq 0) {
        Write-LogInfo '已取消导出。'
        return
    }

    # 二次确认所选数据库真实存在，防止解析异常导致误操作
    foreach ($dbName in $selectedDbs) {
        if (-not (Test-MySqlDatabaseExists -ContainerName $config.ContainerName -Password $password -Database $dbName)) {
            throw "数据库 [$dbName] 不存在，无法导出。"
        }
    }
    Write-LogInfo "确认导出数据库: $($selectedDbs -join ', ')"

    # 2. 单库场景：选择表级导出方式
    $tableScopes = @{}  # key: dbName, value: @{ All = $true } 或 @{ Tables = @(...) }
    if ($selectedDbs.Count -eq 1) {
        $scope = Select-MySqlTablesForExport -ContainerName $config.ContainerName -Password $password -Database $selectedDbs[0]
        if (-not $scope) {
            Write-LogInfo '已取消导出。'
            return
        }
        $tableScopes[$selectedDbs[0]] = $scope
        if ($scope.All) {
            Write-LogInfo "表级范围: 全部表"
        }
        else {
            Write-LogInfo "表级范围: $($scope.Tables -join ', ')"
        }
    }
    else {
        # 多库场景：库级不支持合并导出，强制按数据库分开导出
        Write-LogStep "已选择 $($selectedDbs.Count) 个数据库，将按库分开导出"
    }

    # 3. 选择导出格式
    Write-LogStep '请选择导出格式'
    Write-Host '  [S] SQL 文件（.sql）' -ForegroundColor Gray
    Write-Host '  [C] CSV 文件（.csv）' -ForegroundColor Gray
    Write-Host '  [B] SQL + CSV 同时导出' -ForegroundColor Gray
    Write-Host '  [Q] 返回/取消' -ForegroundColor Gray
    $format = ''
    do {
        $formatChoice = Read-Host '请选择格式'
        if ($formatChoice -eq 'Q' -or $formatChoice -eq 'q') {
            Write-LogInfo '已取消导出。'
            return
        }
        if ($formatChoice -eq 'S' -or $formatChoice -eq 's') { $format = 'sql'; break }
        if ($formatChoice -eq 'C' -or $formatChoice -eq 'c') { $format = 'csv'; break }
        if ($formatChoice -eq 'B' -or $formatChoice -eq 'b') { $format = 'both'; break }
        Write-LogWarning '无效选择，请重新输入（S/C/B/Q）。'
    } while ($true)

    # 4. 准备输出目录
    $dateDir = Get-Date -Format 'yyyyMMdd'
    $backupDir = Join-Path $config.BackupDir $dateDir
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $timestamp = Get-Date -Format 'HHmmss'

    # 5. 执行导出
    switch ($format) {
        'sql' {
            $null = Export-SelectedDatabasesToSql -Config $config -Password $password -SelectedDbs $selectedDbs -TableScopes $tableScopes -BackupDir $backupDir -Timestamp $timestamp
        }
        'csv' {
            $baseInfo = Get-ExportBaseInfo -Config $config -SelectedDbs $selectedDbs -TableScopes $tableScopes -BackupDir $backupDir -Timestamp $timestamp
            Export-SelectedDatabasesToCsv -Config $config -Password $password -SelectedDbs $selectedDbs -TableScopes $tableScopes -SqlBaseInfo $baseInfo
        }
        'both' {
            $sqlBaseInfo = Export-SelectedDatabasesToSql -Config $config -Password $password -SelectedDbs $selectedDbs -TableScopes $tableScopes -BackupDir $backupDir -Timestamp $timestamp
            if ($sqlBaseInfo) {
                Export-SelectedDatabasesToCsv -Config $config -Password $password -SelectedDbs $selectedDbs -TableScopes $tableScopes -SqlBaseInfo $sqlBaseInfo
            }
        }
    }
}

function Export-Logs {
    $config = Get-ProjectConfig
    $logOptions = [ordered]@{
        'docker'  = 'Docker 容器日志 (docker logs)'
        'error'   = 'MySQL error.log'
        'general' = 'MySQL general.log'
        'slow'    = 'MySQL slow.log'
        'back'    = '返回上级菜单'
    }

    do {
        $choice = Read-HostChoice -Prompt '请选择要导出的日志类型' -Options $logOptions -DefaultKey 'back'
        if ($choice -eq 'back') { return }

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if (-not (Test-Path $config.LogDir)) { New-Item -ItemType Directory -Path $config.LogDir -Force | Out-Null }

        switch ($choice) {
            'docker' {
                $outFile = Join-Path $config.LogDir "container_${timestamp}.log"
                Export-ContainerLog -ContainerName $config.ContainerName -OutputPath $outFile
            }
            'error' {
                $outFile = Join-Path $config.LogDir "error_${timestamp}.log"
                Export-MySqlLogFile -ContainerName $config.ContainerName -LogName 'error.log' -OutputPath $outFile
            }
            'general' {
                $outFile = Join-Path $config.LogDir "general_${timestamp}.log"
                Export-MySqlLogFile -ContainerName $config.ContainerName -LogName 'general.log' -OutputPath $outFile
            }
            'slow' {
                $outFile = Join-Path $config.LogDir "slow_${timestamp}.log"
                Export-MySqlLogFile -ContainerName $config.ContainerName -LogName 'slow.log' -OutputPath $outFile
            }
        }
        Write-LogSuccess "日志已导出: $outFile"

        $again = Read-Host '是否继续导出其他日志？(y/N)'
        if ($again -ne 'y' -and $again -ne 'Y') { return }
    } while ($true)
}

function Show-ContainerStatusUI {
    $config = Get-ProjectConfig
    if (-not (Test-DockerAvailable)) { throw 'Docker 未运行。' }
    $status = Get-ContainerStatus -ContainerName $config.ContainerName
    if ($status) {
        Write-LogInfo "容器 $($config.ContainerName) 状态: $status"
        docker ps --filter "name=^/$($config.ContainerName)$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    }
    else {
        Write-LogWarning "容器 $($config.ContainerName) 不存在。"
    }
}

function StopOrRemove-Container {
    $config = Get-ProjectConfig
    if (-not (Test-DockerAvailable)) { throw 'Docker 未运行。' }
    if (-not (Test-ContainerExists -ContainerName $config.ContainerName)) {
        Write-LogWarning "容器 $($config.ContainerName) 不存在。"
        return
    }

    $action = Read-Host '请输入操作: (S)停止, (R)删除, (C)取消'
    switch ($action.ToUpper()) {
        'S' {
            docker stop $config.ContainerName | Out-Null
            Write-LogSuccess "容器 $($config.ContainerName) 已停止。"
        }
        'R' {
            if (Confirm-Action -Message "确定删除容器 $($config.ContainerName) 吗？数据卷不会删除。") {
                docker rm -f $config.ContainerName | Out-Null
                Write-LogSuccess "容器 $($config.ContainerName) 已删除。"
            }
            else {
                Write-LogInfo '已取消。'
            }
        }
        default { Write-LogInfo '已取消。' }
    }
}

function Update-Credential {
    Write-LogStep '更新 root 密码凭据'

    $config = Get-ProjectConfig
    $containerName = $config.ContainerName

    if (-not (Test-DockerContainer -ContainerName $containerName)) {
        throw "容器 $containerName 不存在或未运行，无法验证当前密码。"
    }

    # 验证当前密码
    $maxRetry = 5
    $verified = $false
    $currentPlain = $null
    for ($i = 1; $i -le $maxRetry; $i++) {
        $currentSecure = Read-Host '请输入当前 MySQL root 密码' -AsSecureString
        $currentPlain = ConvertTo-PlainText $currentSecure

        Write-LogInfo '正在验证当前密码...'
        try {
            $result = Invoke-MySqlCli -ContainerName $containerName -Password $currentPlain -Sql 'SELECT 1 AS verify'
            if ($result -match 'verify') {
                $verified = $true
                break
            }
        }
        catch {
            Write-LogWarning "当前密码验证失败（第 $i / $maxRetry 次）。"
        }
    }

    if (-not $verified) {
        throw '当前密码连续验证失败，无法更新凭据。'
    }

    # 输入新密码并确认
    $newSecure = Read-MySqlPassword
    $newPlain = ConvertTo-PlainText $newSecure

    if ($newPlain -eq $currentPlain) {
        Write-LogWarning '新密码与当前密码相同，无需更新。'
        return
    }

    # 修改 MySQL root 密码
    Write-LogInfo '正在修改 MySQL root 密码...'
    $sql = "ALTER USER 'root'@'%' IDENTIFIED BY '$newPlain'; FLUSH PRIVILEGES;"
    Invoke-MySqlCli -ContainerName $containerName -Password $currentPlain -Sql $sql | Out-Null

    Save-MySqlCredential -Password $newSecure
    $script:MySqlPasswordCache = $newPlain
    Write-LogSuccess 'MySQL root 密码及本地凭据已更新。'
}

#endregion

function Get-ExportBaseInfo {
    <#
    .SYNOPSIS
        根据所选数据库和表范围计算导出的基础路径与名称（不执行导出）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string[]]$SelectedDbs,

        [Parameter(Mandatory = $true)]
        [hashtable]$TableScopes,

        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [string]$Timestamp
    )

    if ($SelectedDbs.Count -eq 1) {
        $db = $SelectedDbs[0]
        $scope = $TableScopes[$db]
        if ($scope.Tables -and $scope.Tables.Count -gt 0) {
            $dateFolder = Get-Date -Format 'yyyy-MM-dd'
            $outputDir = Join-Path $Config.ProjectPath 'output' $dateFolder
            return @{
                Mode     = 'single-table'
                BasePath = $outputDir
                BaseName = "$($db -replace '\s+', '_')_$Timestamp"
            }
        }
        else {
            return @{
                Mode     = 'single-full'
                BasePath = $BackupDir
                BaseName = "${db}_mysql$($Config.Port)_$Timestamp"
            }
        }
    }
    else {
        return @{
            Mode     = 'multi'
            BasePath = $BackupDir
            BaseName = "databases_separate_mysql$($Config.Port)_$Timestamp"
        }
    }
}

function Export-SelectedDatabasesToSql {
    <#
    .SYNOPSIS
        将选中的数据库导出为 SQL 文件
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string[]]$SelectedDbs,

        [Parameter(Mandatory = $true)]
        [hashtable]$TableScopes,

        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [string]$Timestamp
    )

    try {
        $baseInfo = Get-ExportBaseInfo -Config $Config -SelectedDbs $SelectedDbs -TableScopes $TableScopes -BackupDir $BackupDir -Timestamp $Timestamp

        switch ($baseInfo.Mode) {
            'single-table' {
                $outputDir = $baseInfo.BasePath
                if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

                $db = $SelectedDbs[0]
                $scope = $TableScopes[$db]
                $sqlFileName = "$($baseInfo.BaseName).sql"
                $ddlFileName = "$($baseInfo.BaseName)_DDL.txt"

                Write-LogStep "正在导出 SQL 文件: $sqlFileName"
                $sqlOutput = Join-Path $outputDir $sqlFileName
                Invoke-MySqlDump -ContainerName $Config.ContainerName -Password $Password -OutputPath $sqlOutput -Database $db -Tables $scope.Tables

                Write-LogStep "正在生成 DDL 汇总文件: $ddlFileName"
                $ddlContent = Get-MySqlDdlForTables -ContainerName $Config.ContainerName -Password $Password -Database $db -Tables $scope.Tables
                $summary = @()
                $summary += "数据库: $db"
                $summary += "导出时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                $summary += "导出表数量: $($scope.Tables.Count)"
                $summary += "表名列表: $($scope.Tables -join ', ')"
                $summary += '===================================='
                $summary += ''
                $summary += $ddlContent

                $ddlOutput = Join-Path $outputDir $ddlFileName
                $summary -join "`r`n" | Out-File -FilePath $ddlOutput -Encoding UTF8 -Force

                $sizeKB = [math]::Round((Get-Item $sqlOutput).Length / 1KB, 2)
                Write-LogSuccess 'SQL + DDL 导出完成！'
                Write-LogInfo "SQL 文件大小: $sizeKB KB"
                Write-LogInfo "SQL 文件: $sqlOutput"
                Write-LogInfo "DDL 汇总: $ddlOutput"

                return @{
                    Mode        = 'single-table'
                    BasePath    = $outputDir
                    BaseName    = $baseInfo.BaseName
                    SqlPath     = $sqlOutput
                    IsDirectory = $false
                }
            }
            'single-full' {
                $defaultName = "$($baseInfo.BaseName).sql"
                $fileName = Read-Host "请输入导出文件名（直接回车使用默认: $defaultName，B 取消）"
                if ($fileName -eq 'B' -or $fileName -eq 'b') { Write-LogInfo '已取消导出。'; return $null }
                if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = $defaultName }
                if (-not $fileName.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) { $fileName += '.sql' }
                $output = Join-Path $baseInfo.BasePath $fileName

                Invoke-MySqlDump -ContainerName $Config.ContainerName -Password $Password -OutputPath $output -Database $SelectedDbs[0]

                $sizeKB = [math]::Round((Get-Item $output).Length / 1KB, 2)
                Write-LogSuccess 'SQL 导出完成！'
                Write-LogInfo "文件大小: $sizeKB KB"
                Write-LogInfo "保存路径: $output"

                return @{
                    Mode        = 'single-full'
                    BasePath    = $baseInfo.BasePath
                    BaseName    = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                    SqlPath     = $output
                    IsDirectory = $false
                }
            }
            'multi' {
                $outputDir = Join-Path $baseInfo.BasePath "$($baseInfo.BaseName)_sql"
                if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

                foreach ($db in $SelectedDbs) {
                    $fileName = "${db}_mysql$($Config.Port)_$Timestamp.sql"
                    $output = Join-Path $outputDir $fileName
                    Invoke-MySqlDump -ContainerName $Config.ContainerName -Password $Password -OutputPath $output -Database $db
                    Write-LogInfo "已导出: $output"
                }
                Write-LogSuccess 'SQL 分开导出完成！'
                Write-LogInfo "保存目录: $outputDir"

                return @{
                    Mode        = 'multi'
                    BasePath    = $baseInfo.BasePath
                    BaseName    = "$($baseInfo.BaseName)_sql"
                    SqlPath     = $outputDir
                    IsDirectory = $true
                }
            }
        }
    }
    catch {
        Write-LogError "SQL 导出失败: $_"
        throw
    }
}

function Export-SelectedDatabasesToCsv {
    <#
    .SYNOPSIS
        将选中的数据库导出为 CSV 文件
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string[]]$SelectedDbs,

        [Parameter(Mandatory = $true)]
        [hashtable]$TableScopes,

        [Parameter(Mandatory = $true)]
        [hashtable]$SqlBaseInfo
    )

    try {
        $csvBaseName = $SqlBaseInfo.BaseName -replace '_sql$', ''
        $csvDir = Join-Path $SqlBaseInfo.BasePath "${csvBaseName}_csv"
        if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }

        if ($SelectedDbs.Count -eq 1) {
            $db = $SelectedDbs[0]
            $scope = $TableScopes[$db]
            $tables = if ($scope.All) { Get-MySqlTables -ContainerName $Config.ContainerName -Password $Password -Database $db } else { $scope.Tables }
            if (-not $tables) { throw "数据库 [$db] 中没有表，无法导出 CSV。" }
            Export-MySqlTablesToCsv -ContainerName $Config.ContainerName -Password $Password -Database $db -Tables $tables -OutputDir $csvDir
        }
        else {
            foreach ($db in $SelectedDbs) {
                $outputDir = Join-Path $csvDir $db
                $tables = Get-MySqlTables -ContainerName $Config.ContainerName -Password $Password -Database $db
                if ($tables) {
                    Export-MySqlTablesToCsv -ContainerName $Config.ContainerName -Password $Password -Database $db -Tables $tables -OutputDir $outputDir
                }
            }
        }

        Write-LogSuccess 'CSV 导出完成！'
        Write-LogInfo "保存目录: $csvDir"
    }
    catch {
        Write-LogError "CSV 导出失败: $_"
        throw
    }
}

function Show-MySqlDatabasesList {
    <#
    .SYNOPSIS
        列出所有数据库（含系统库，系统库标灰）
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        Write-LogStep '查询所有数据库'
        $result = Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql 'SHOW DATABASES;' -SkipColumnNames -Quiet
        if (-not $result) { throw '无法获取数据库列表。' }

        $systemDbs = @('information_schema', 'mysql', 'performance_schema', 'sys')
        Write-Host "`n数据库列表:" -ForegroundColor Cyan
        foreach ($line in $result) {
            $db = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($db)) { continue }
            if ($db -in $systemDbs) {
                Write-Host "  [系统] $db" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  [用户] $db" -ForegroundColor White
            }
        }
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function New-MySqlDatabase {
    <#
    .SYNOPSIS
        创建数据库，已存在则报错
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        $dbName = Read-Host '请输入要创建的数据库名（B 取消）'
        if ($dbName -eq 'B' -or $dbName -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($dbName)) { throw '数据库名不能为空。' }

        if (Test-MySqlDatabaseExists -ContainerName $config.ContainerName -Password $password -Database $dbName) {
            throw "数据库 [$dbName] 已存在。"
        }

        $sql = 'CREATE DATABASE IF NOT EXISTS `' + $dbName + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $sql | Out-Null
        Write-LogSuccess "数据库 [$dbName] 创建成功。"
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Remove-MySqlDatabase {
    <#
    .SYNOPSIS
        删除数据库，删除前要求输入 y 确认
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        $dbName = Read-Host '请输入要删除的数据库名（B 取消）'
        if ($dbName -eq 'B' -or $dbName -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($dbName)) { throw '数据库名不能为空。' }

        $systemDbs = @('information_schema', 'mysql', 'performance_schema', 'sys')
        if ($dbName -in $systemDbs) { throw "不能删除系统数据库 [$dbName]。" }

        if (-not (Test-MySqlDatabaseExists -ContainerName $config.ContainerName -Password $password -Database $dbName)) {
            throw "数据库 [$dbName] 不存在。"
        }

        if (-not (Confirm-Action -Message "确定删除数据库 [$dbName] 吗？此操作不可恢复。")) {
            Write-LogInfo '已取消。'
            return
        }

        $sql = 'DROP DATABASE `' + $dbName + '`;'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $sql | Out-Null
        Write-LogSuccess "数据库 [$dbName] 已删除。"
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Get-MySqlUsers {
    <#
    .SYNOPSIS
        查询所有用户及主机
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        Write-LogStep '查询所有 MySQL 用户'
        $result = Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql "SELECT user, host FROM mysql.user ORDER BY user, host;" -SkipColumnNames -Quiet
        if (-not $result) {
            Write-LogWarning '未查询到用户。'
            return @()
        }

        $users = @()
        foreach ($line in $result) {
            $parts = $line.Split("`t")
            if ($parts.Count -ge 2) {
                $users += [PSCustomObject]@{
                    User = $parts[0].Trim()
                    Host = $parts[1].Trim()
                }
            }
        }

        Write-Host "`nMySQL 用户列表:" -ForegroundColor Cyan
        $users | ForEach-Object { Write-Host "  $($_.User)@$($_.Host)" -ForegroundColor White }
        return $users
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function New-MySqlUser {
    <#
    .SYNOPSIS
        创建用户并授权
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        $userName = Read-Host '请输入用户名（B 取消）'
        if ($userName -eq 'B' -or $userName -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($userName)) { throw '用户名不能为空。' }

        $hostPart = Read-Host '请输入主机（默认: %）'
        if ([string]::IsNullOrWhiteSpace($hostPart)) { $hostPart = '%' }

        $userPasswordSecure = Read-Host '请输入密码（B 取消）' -AsSecureString
        $plainPassword = ConvertTo-PlainText $userPasswordSecure
        if ($plainPassword -eq 'B' -or $plainPassword -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw '密码不能为空。' }

        $privileges = Read-Host '请输入权限（如 ALL PRIVILEGES, SELECT, INSERT，默认: ALL PRIVILEGES）'
        if ([string]::IsNullOrWhiteSpace($privileges)) { $privileges = 'ALL PRIVILEGES' }

        $targetDb = Read-Host '请输入目标数据库（默认: *）'
        if ([string]::IsNullOrWhiteSpace($targetDb)) { $targetDb = '*' }

        $sql = 'CREATE USER IF NOT EXISTS `' + $userName + '`@`' + $hostPart + '` IDENTIFIED BY ''' + $plainPassword + ''';'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $sql | Out-Null

        $grantSql = 'GRANT ' + $privileges + ' ON `' + $targetDb + '`.* TO `' + $userName + '`@`' + $hostPart + '`;'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $grantSql | Out-Null

        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql 'FLUSH PRIVILEGES;' | Out-Null
        Write-LogSuccess "用户 [$userName@$hostPart] 创建并授权成功。"
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Remove-MySqlUser {
    <#
    .SYNOPSIS
        删除用户，确认后执行
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        $userName = Read-Host '请输入要删除的用户名（B 取消）'
        if ($userName -eq 'B' -or $userName -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($userName)) { throw '用户名不能为空。' }

        $hostPart = Read-Host '请输入主机（默认: %）'
        if ([string]::IsNullOrWhiteSpace($hostPart)) { $hostPart = '%' }

        if (-not (Confirm-Action -Message "确定删除用户 [$userName@$hostPart] 吗？")) {
            Write-LogInfo '已取消。'
            return
        }

        $sql = 'DROP USER `' + $userName + '`@`' + $hostPart + '`;'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $sql | Out-Null
        Write-LogSuccess "用户 [$userName@$hostPart] 已删除。"
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Grant-MySqlPrivileges {
    <#
    .SYNOPSIS
        给用户授权/修改权限
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        $userName = Read-Host '请输入用户名（B 取消）'
        if ($userName -eq 'B' -or $userName -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($userName)) { throw '用户名不能为空。' }

        $hostPart = Read-Host '请输入主机（默认: %）'
        if ([string]::IsNullOrWhiteSpace($hostPart)) { $hostPart = '%' }

        $targetDb = Read-Host '请输入目标数据库（默认: *）'
        if ([string]::IsNullOrWhiteSpace($targetDb)) { $targetDb = '*' }

        $privileges = Read-Host '请输入权限（如 ALL PRIVILEGES, SELECT, INSERT，默认: ALL PRIVILEGES）'
        if ([string]::IsNullOrWhiteSpace($privileges)) { $privileges = 'ALL PRIVILEGES' }

        $sql = 'GRANT ' + $privileges + ' ON `' + $targetDb + '`.* TO `' + $userName + '`@`' + $hostPart + '`;'
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql $sql | Out-Null
        Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql 'FLUSH PRIVILEGES;' | Out-Null
        Write-LogSuccess "用户 [$userName@$hostPart] 权限更新成功。"
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Show-MySqlTableData {
    <#
    .SYNOPSIS
        查看表数据，支持选择数据库、表名和 LIMIT
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        Write-LogStep '请选择数据库'
        $selected = @(Select-MySqlDatabases -ContainerName $config.ContainerName -Password $password -Single)
        if ($selected.Count -eq 0) { Write-LogInfo '已取消。'; return }
        $db = $selected[0]

        $tables = Get-MySqlTables -ContainerName $config.ContainerName -Password $password -Database $db
        $tableName = Select-FromList -Title "数据库 [$db] 中的表" -Items $tables -AllowManual -AllowCancel
        if ([string]::IsNullOrWhiteSpace($tableName)) { Write-LogInfo '已取消。'; return }

        $limitInput = Read-Host '请输入 LIMIT 数量（默认: 50，B 取消）'
        if ($limitInput -eq 'B' -or $limitInput -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($limitInput)) { $limitInput = '50' }
        if ($limitInput -notmatch '^\d+$') { throw 'LIMIT 必须是正整数。' }
        $limit = [int]$limitInput
        if ($limit -lt 1 -or $limit -gt 100000) { throw 'LIMIT 范围必须在 1-100000 之间。' }

        $sql = 'SELECT * FROM `' + $db + '`.`' + $tableName + '` LIMIT ' + $limit + ';'
        Write-LogStep "正在查询 [$db.$tableName]，LIMIT $limit"
        $result = Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Database $db -Sql $sql
        Write-Host ''
        $result | ForEach-Object { Write-Host $_ -ForegroundColor White }
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Import-RemoteMySqlDatabase {
    <#
    .SYNOPSIS
        从远程 MySQL 导入到当前容器
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $localPassword = Get-MySqlPasswordOnce

        Write-LogStep '从远程 MySQL 导入'
        $remoteHost = Read-Host '请输入远程主机地址（B 取消）'
        if ($remoteHost -eq 'B' -or $remoteHost -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($remoteHost)) { throw '远程主机不能为空。' }

        $remotePort = Read-Host '请输入远程端口（默认: 3306）'
        if ([string]::IsNullOrWhiteSpace($remotePort)) { $remotePort = '3306' }
        if ($remotePort -notmatch '^\d+$') { throw '端口必须是数字。' }

        $remoteUser = Read-Host '请输入远程用户名（默认: root）'
        if ([string]::IsNullOrWhiteSpace($remoteUser)) { $remoteUser = 'root' }

        $remotePasswordSecure = Read-Host '请输入远程密码' -AsSecureString
        $remotePassword = ConvertTo-PlainText $remotePasswordSecure
        if ([string]::IsNullOrWhiteSpace($remotePassword)) { throw '远程密码不能为空。' }

        $sourceDb = Read-Host '请输入远程源数据库名（B 取消）'
        if ($sourceDb -eq 'B' -or $sourceDb -eq 'b') { Write-LogInfo '已取消。'; return }
        if ([string]::IsNullOrWhiteSpace($sourceDb)) { throw '源数据库名不能为空。' }

        $targetDb = Read-Host '请输入本地目标数据库名（默认与源库相同）'
        if ([string]::IsNullOrWhiteSpace($targetDb)) { $targetDb = $sourceDb }

        if (-not (Test-MySqlDatabaseExists -ContainerName $config.ContainerName -Password $localPassword -Database $targetDb)) {
            Write-LogInfo "本地目标数据库 [$targetDb] 不存在，正在创建..."
            $createSql = 'CREATE DATABASE IF NOT EXISTS `' + $targetDb + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
            Invoke-MySqlCli -ContainerName $config.ContainerName -Password $localPassword -Sql $createSql | Out-Null
        }

        $containerName = $config.ContainerName
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $tempFile = Join-Path $env:TEMP "remote_import_${containerName}_${sourceDb}_$timestamp.sql"

        $dumpArgs = @(
            'exec', '-i', $containerName
            'mysqldump'
            '-h', $remoteHost
            '-P', $remotePort
            '-u', $remoteUser
            "-p$remotePassword"
            '--single-transaction'
            '--set-gtid-purged=OFF'
            $sourceDb
        )

        $mysqlArgs = @(
            'exec', '-i', '-e', "MYSQL_PWD=$localPassword", $containerName
            'mysql'
            '-h', '127.0.0.1'
            '-u', 'root'
            $targetDb
        )

        Write-LogStep "正在从 $remoteHost`:$remotePort/$sourceDb 导出到临时文件"
        Write-LogCommand -Command "docker $($dumpArgs -join ' ') > $tempFile"
        & docker $dumpArgs > $tempFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw '远程 mysqldump 导出失败。' }
        if (-not (Test-Path $tempFile) -or (Get-Item $tempFile).Length -eq 0) { throw '远程导出文件为空。' }

        Write-LogStep "正在导入到本地数据库 [$targetDb]"
        Write-LogCommand -Command "docker $($mysqlArgs -join ' ') < $tempFile"
        $importProcess = Start-Process -FilePath 'docker' -ArgumentList $mysqlArgs -RedirectStandardInput $tempFile -RedirectStandardError (Join-Path $env:TEMP 'remote_import_err.log') -NoNewWindow -Wait -PassThru
        if ($importProcess.ExitCode -ne 0) {
            $err = Get-Content -Path (Join-Path $env:TEMP 'remote_import_err.log') -Raw -ErrorAction SilentlyContinue
            throw "本地导入失败: $err"
        }

        Remove-Item -Path $tempFile, (Join-Path $env:TEMP 'remote_import_err.log') -Force -ErrorAction SilentlyContinue
        Write-LogSuccess '远程数据库导入完成。'
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Show-MySqlProcessList {
    <#
    .SYNOPSIS
        执行 SHOW PROCESSLIST
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName
        $password = Get-MySqlPasswordOnce

        Write-LogStep '查看 MySQL 进程列表'
        $result = Invoke-MySqlCli -ContainerName $config.ContainerName -Password $password -Sql 'SHOW PROCESSLIST;'
        Write-Host ''
        $result | ForEach-Object { Write-Host $_ -ForegroundColor White }
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Show-ContainerStats {
    <#
    .SYNOPSIS
        执行 docker stats --no-stream 显示容器资源
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        Assert-ContainerRunning -ContainerName $config.ContainerName

        Write-LogStep '查看容器资源占用'
        & docker stats --no-stream $config.ContainerName
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Show-ContainerConfig {
    <#
    .SYNOPSIS
        查看并修改容器配置
    #>
    [CmdletBinding()]
    param()

    try {
        $config = Get-ProjectConfig
        $configFile = Join-Path $config.ProjectPath 'project.config.json'

        do {
            Show-Header '查看/修改容器配置'
            Write-Host "  项目路径: $($config.ProjectPath)" -ForegroundColor Gray
            Write-Host "  配置文件: $configFile" -ForegroundColor Gray
            Write-Host ''
            Write-Host "  [1] 容器名: $($config.ContainerName)" -ForegroundColor White
            Write-Host "  [2] 端口: $($config.Port)" -ForegroundColor White
            Write-Host "  [3] 默认数据库: $($config.DefaultDb)" -ForegroundColor White
            Write-Host "  [4] 镜像: $($config.Image):$($config.Version)" -ForegroundColor White
            Write-Host '  [B] 返回' -ForegroundColor White
            Write-Host ''

            $choice = Read-Host '请选择要修改的配置项'
            switch ($choice.ToUpper()) {
                '1' {
                    $newName = Read-Host '请输入新容器名（B 取消）'
                    if ($newName -eq 'B' -or $newName -eq 'b') { continue }
                    if (-not (Test-ContainerNameValid -Name $newName)) {
                        Write-LogWarning '容器名不规范：长度 2-64，只能包含字母、数字、下划线、点、短横线，且不能以短横线开头。'
                        continue
                    }
                    $config.ContainerName = $newName
                    Save-ProjectConfig -Config $config
                    Write-LogSuccess '容器名已更新。'
                }
                '2' {
                    Write-LogWarning '修改端口后需要重新创建容器才能生效。'
                    $newPort = Read-Host '请输入新端口（B 取消）'
                    if ($newPort -eq 'B' -or $newPort -eq 'b') { continue }
                    if ($newPort -notmatch '^\d+$' -or [int]$newPort -lt 1 -or [int]$newPort -gt 65535) {
                        Write-LogWarning '端口号必须是 1-65535 之间的数字。'
                        continue
                    }
                    $config.Port = $newPort
                    Save-ProjectConfig -Config $config
                    Write-LogSuccess '端口已更新（请重新创建容器生效）。'
                }
                '3' {
                    $newDb = Read-Host '请输入新默认数据库名（B 取消）'
                    if ($newDb -eq 'B' -or $newDb -eq 'b') { continue }
                    if ([string]::IsNullOrWhiteSpace($newDb)) {
                        Write-LogWarning '数据库名不能为空。'
                        continue
                    }
                    $config.DefaultDb = $newDb
                    Save-ProjectConfig -Config $config
                    Write-LogSuccess '默认数据库已更新。'
                }
                '4' {
                    Write-LogWarning '修改镜像后需要重新创建容器才能生效。'
                    $newImage = Read-Host '请输入新镜像名（B 取消）'
                    if ($newImage -eq 'B' -or $newImage -eq 'b') { continue }
                    if ([string]::IsNullOrWhiteSpace($newImage)) {
                        Write-LogWarning '镜像名不能为空。'
                        continue
                    }
                    $config.Image = $newImage
                    Save-ProjectConfig -Config $config
                    Write-LogSuccess '镜像已更新（请重新创建容器生效）。'
                }
                'B' { return }
                default { Write-LogWarning '无效选择。' }
            }

            Pause-AnyKey
        } while ($true)
    }
    catch {
        Write-LogError $_.Exception.Message
        throw
    }
}

function Show-ContainerOperationsMenu {
    [CmdletBinding()]
    param()

    $config = Get-ProjectConfig
    do {
        Show-Header '容器运维中心'
        Write-Host "  容器名: $($config.ContainerName)" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  [1] 查看/修改容器配置' -ForegroundColor White
        Write-Host '  [2] 查看容器状态' -ForegroundColor White
        Write-Host '  [3] 查看/导出日志' -ForegroundColor White
        Write-Host '  [4] 查看容器资源占用' -ForegroundColor White
        Write-Host '  [5] 停止/删除容器' -ForegroundColor White
        Write-Host '  [B] 返回' -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '1' { Show-ContainerConfig }
                '2' { Show-ContainerStatusUI }
                '3' { Export-Logs }
                '4' { Show-ContainerStats }
                '5' { StopOrRemove-Container }
                'B' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }
        Pause-AnyKey
    } while ($true)
}

function Show-DatabaseManagementMenu {
    [CmdletBinding()]
    param()

    do {
        Show-Header '数据库管理'
        Write-Host '  [1] 查看所有数据库' -ForegroundColor White
        Write-Host '  [2] 创建数据库' -ForegroundColor White
        Write-Host '  [3] 删除数据库' -ForegroundColor White
        Write-Host '  [B] 返回' -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '1' { Show-MySqlDatabasesList }
                '2' { New-MySqlDatabase }
                '3' { Remove-MySqlDatabase }
                'B' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }
        Pause-AnyKey
    } while ($true)
}

function Show-SqlFileOperationsMenu {
    [CmdletBinding()]
    param()

    do {
        Show-Header 'SQL 文件操作'
        Write-Host '  [1] 执行 SQL 文件' -ForegroundColor White
        Write-Host '  [2] 导入 SQL 文件' -ForegroundColor White
        Write-Host '  [3] 从远程 MySQL 导入' -ForegroundColor White
        Write-Host '  [B] 返回' -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '1' { Execute-SqlFile }
                '2' { Import-SqlFile }
                '3' { Import-RemoteMySqlDatabase }
                'B' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }
        Pause-AnyKey
    } while ($true)
}

function Show-UserManagementMenu {
    [CmdletBinding()]
    param()

    do {
        Show-Header '用户与权限管理'
        Write-Host '  [1] 查看所有用户' -ForegroundColor White
        Write-Host '  [2] 创建用户' -ForegroundColor White
        Write-Host '  [3] 删除用户' -ForegroundColor White
        Write-Host '  [4] 授权/修改权限' -ForegroundColor White
        Write-Host '  [B] 返回' -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '1' { $null = Get-MySqlUsers }
                '2' { New-MySqlUser }
                '3' { Remove-MySqlUser }
                '4' { Grant-MySqlPrivileges }
                'B' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }
        Pause-AnyKey
    } while ($true)
}

function Show-SystemToolsMenu {
    [CmdletBinding()]
    param()

    do {
        Show-Header '系统工具'
        Write-Host '  [1] 更新 root 密码凭据' -ForegroundColor White
        Write-Host '  [2] 查看 MySQL 进程列表' -ForegroundColor White
        Write-Host '  [B] 返回' -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '1' { Update-Credential }
                '2' { Show-MySqlProcessList }
                'B' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }
        Pause-AnyKey
    } while ($true)
}

#region 菜单

function Show-OperationalMenu {
    $config = Get-ProjectConfig
    $dockerAvailable = Test-DockerAvailable
    $containerExists = $false
    if ($dockerAvailable) {
        try {
            $containerExists = Test-DockerContainer -ContainerName $config.ContainerName
        }
        catch {
            Write-LogWarning "检测容器状态时出错: $_"
        }
    }

    do {
        Show-Header "MySQL 实例管理 - mysql$($config.Port)"
        Write-Host "  项目路径: $($config.ProjectPath)" -ForegroundColor Gray

        if (-not $dockerAvailable) {
            Write-Host '  [ERROR] Docker 未运行或未安装，请先启动 Docker Desktop。' -ForegroundColor Red
        }
        elseif ($containerExists) {
            Write-Host '  实例已创建并运行。' -ForegroundColor Green
        }
        else {
            Write-Host '  检测到容器尚未创建，可使用 [0] 创建并启动容器。' -ForegroundColor Yellow
        }
        Write-Host ''

        Write-Host '  [0] 创建/启动 MySQL 容器' -ForegroundColor Green
        Write-Host '  [1] 容器运维中心' -ForegroundColor White
        Write-Host '  [2] 连接 MySQL 终端（直接进入）' -ForegroundColor White
        Write-Host '  [3] 数据库管理' -ForegroundColor White
        Write-Host '  [4] SQL 文件操作' -ForegroundColor White
        Write-Host '  [5] 导出数据库/表（SQL / CSV / SQL+CSV / DDL）' -ForegroundColor White
        Write-Host '  [6] 用户与权限管理' -ForegroundColor White
        Write-Host '  [7] 表数据查看' -ForegroundColor White
        Write-Host '  [8] 系统工具' -ForegroundColor White
        Write-Host '  [B] 返回上级菜单（实例选择列表）' -ForegroundColor White
        Write-Host '  [Q] 退出' -ForegroundColor White
        Write-Host ''
        Write-Host '============================================' -ForegroundColor Cyan

        $choice = Read-Host '请选择操作'
        try {
            switch ($choice.ToUpper()) {
                '0' {
                    if (-not $containerExists) {
                        Start-MySqlContainer
                    }
                    elseif (Confirm-Action -Message '容器已存在，是否重新创建？') {
                        Start-MySqlContainer
                    }
                    else {
                        Write-LogInfo '已取消。'
                    }
                    $containerExists = Test-DockerContainer -ContainerName $config.ContainerName
                }
                '1' { Show-ContainerOperationsMenu }
                '2' { Connect-MySql }
                '3' { Show-DatabaseManagementMenu }
                '4' { Show-SqlFileOperationsMenu }
                '5' { Export-MySqlDatabase }
                '6' { Show-UserManagementMenu }
                '7' { Show-MySqlTableData }
                '8' { Show-SystemToolsMenu }
                'B' { return }
                'Q' { return }
                default { Write-LogWarning '无效选择，请重新输入。' }
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }

        Pause-AnyKey
    } while ($true)
}

function Show-SetupMenu {
    do {
        Show-Header 'Docker MySQL 实例管理器'
        Write-Host "  BasePath: $Global:BasePath" -ForegroundColor Gray
        Write-Host ''

        $instances = Get-ChildItem -Path $Global:BasePath -Directory |
            Where-Object { $_.Name -match '^mysql\d+$' } |
            Select-Object -ExpandProperty Name |
            Sort-Object

        if ($instances.Count -gt 0) {
            Write-Host '  实例列表（已创建的 mysql${port} 目录）:' -ForegroundColor Gray
            for ($i = 0; $i -lt $instances.Count; $i++) {
                Write-Host "    [$($i + 1)] $($instances[$i])" -ForegroundColor Gray
            }
            Write-Host ''
        }
        else {
            Write-Host '  暂无实例。' -ForegroundColor Gray
            Write-Host ''
        }

        Write-Host '  [0] 创建新的 MySQL 实例' -ForegroundColor Green
        if ($instances.Count -gt 0) {
            Write-Host '  [1..N] 进入对应实例的管理菜单' -ForegroundColor White
        }
        Write-Host '  [Q] 退出' -ForegroundColor White
        Write-Host ''
        Write-Host '============================================' -ForegroundColor Cyan

        $choice = Read-Host '请选择操作'
        try {
            if ($choice -eq '0') {
                New-MySqlInstance
            }
            elseif ($choice -match '^\d+$') {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $instances.Count) {
                    $instanceMenu = Join-Path $Global:BasePath $instances[$idx] 'mysql-manager.ps1'
                    if (Test-Path $instanceMenu) {
                        & $instanceMenu
                    }
                    else {
                        Write-LogError "未找到实例菜单: $instanceMenu"
                    }
                }
                else {
                    Write-LogWarning '无效选择。'
                }
            }
            elseif ($choice -eq 'Q' -or $choice -eq 'q') {
                return
            }
            else {
                Write-LogWarning '无效选择，请重新输入。'
            }
        }
        catch {
            Write-LogError $_.Exception.Message
        }

        Pause-AnyKey
    } while ($true)
}

function New-MySqlInstance {
    <#
    .SYNOPSIS
        创建新的 MySQL 实例目录与配置
    .DESCRIPTION
        引导用户完成镜像搜索、版本选择、容器配置、命令预览、执行创建的全流程
    #>
    Write-LogStep '创建新的 MySQL 实例'

    # 1. 镜像搜索与选择
    Write-LogStep '步骤 1/6：选择 MySQL 镜像'
    $image = Select-DockerImage

    # 2. 版本/tag 选择
    Write-LogStep '步骤 2/6：选择镜像版本'
    $version = Select-DockerImageTag -ImageName $image

    # 2.5 拉取镜像并解析 latest 真实版本
    Write-LogStep '步骤 2.5/6：拉取 Docker 镜像'
    $imageSpec = "$($image):$($version)"
    Write-LogInfo "正在拉取 $imageSpec ..."
    docker pull $imageSpec
    if ($LASTEXITCODE -ne 0) { throw "镜像拉取失败: $imageSpec" }
    Write-LogSuccess "镜像 $imageSpec 拉取完成。"

    if ($version -eq 'latest') {
        Write-LogInfo '正在解析 latest 对应的真实版本...'
        $trueVersion = Get-MySqlTrueVersion -ImageSpec $imageSpec
        if ($trueVersion) {
            Write-LogSuccess "latest 对应的真实版本为: $trueVersion"
            $version = $trueVersion
        }
        else {
            Write-LogWarning '无法解析 latest 对应的真实版本号，将继续使用 latest。'
        }
    }

    # 3. 容器端口配置
    Write-LogStep '步骤 3/6：配置主机端口'
    $port = Read-HostPort -DefaultPort '3308'

    $projectPath = Join-Path $Global:BasePath "mysql$port"
    $pathExisted = Test-Path $projectPath
    if ($pathExisted) {
        Write-LogWarning "目录 $projectPath 已存在。"
        if (-not (Confirm-Action -Message '是否覆盖/继续使用该目录？')) {
            Write-LogInfo '已取消创建。'
            return
        }
    }

    # 4. 容器名称
    Write-LogStep '步骤 4/6：配置容器名称'
    $containerName = Read-ContainerName -DefaultName "mysql-locals-$port"

    # 5. 默认数据库与密码
    Write-LogStep '步骤 5/6：配置数据库与密码'
    $defaultDb = Read-Host '请输入默认数据库名（默认: myapp）'
    if (-not $defaultDb) { $defaultDb = 'myapp' }

    $passwordSecure = Read-MySqlPassword

    $initSql = ''
    if (Confirm-Action -Message '是否需要从 SQL 文件初始化数据库架构/数据？') {
        do {
            $initSql = Read-Host '请输入 SQL 文件完整路径（或留空跳过）'
            if ($initSql -and -not (Test-Path $initSql)) {
                Write-LogWarning '文件不存在，请重新输入。'
                $initSql = ''
            }
        } while ($initSql -and -not (Test-Path $initSql))
    }

    try {
        # 6. 创建目录和配置
        Write-LogStep '步骤 6/6：生成项目配置'
        $confDir = Join-Path $projectPath 'conf'
        $dataDir = Join-Path $projectPath 'data'
        $logDir = Join-Path $projectPath 'log'
        $backupsDir = Join-Path $Global:BasePath 'backups'

        @($projectPath, $confDir, $dataDir, $logDir, $backupsDir) | ForEach-Object {
            if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
        }

        $config = [ordered]@{
            BasePath      = $Global:BasePath
            Port          = $port
            ContainerName = $containerName
            DefaultDb     = $defaultDb
            Image         = $image
            Version       = $version
        }
        $config | ConvertTo-Json | Out-File -FilePath (Join-Path $projectPath 'project.config.json') -Encoding UTF8
        (ConvertFrom-SecureString -SecureString $passwordSecure) | Out-File -FilePath (Join-Path $projectPath '.mysqlcred') -Encoding UTF8

        $cnfFile = Join-Path $confDir 'my.cnf'
        if (-not (Test-Path $cnfFile)) {
            $cnfContent = @"
[mysqld]
port=3306                         # 容器内固定 3306，不要改
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-time-zone='+08:00'
max_connections=200
innodb_buffer_pool_size=256M

# 日志配置
log-error=/var/log/mysql/error.log
general_log=1
general_log_file=/var/log/mysql/general.log
slow_query_log=1
slow_query_log_file=/var/log/mysql/slow.log
long_query_time=2

[client]
default-character-set=utf8mb4
"@
            # Linux 容器内 MySQL 只认 LF 换行，不能是 CRLF；同时不能有 BOM
            $cnfContent = $cnfContent -replace "`r`n", "`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($cnfFile, $cnfContent, $utf8NoBom)
        }

        # 复制本菜单脚本到项目目录
        $targetMenu = Join-Path $projectPath 'mysql-manager.ps1'
        $sourceMenu = $MyInvocation.MyCommand.Path
        if (-not $sourceMenu) {
            $sourceMenu = $PSCommandPath
        }
        if (-not $sourceMenu) {
            throw '无法确定当前脚本路径，无法生成项目管理菜单。请确保通过 .ps1 文件直接运行。'
        }
        Copy-Item -Path $sourceMenu -Destination $targetMenu -Force
        if (Test-Path $targetMenu) {
            Write-LogSuccess "管理菜单已生成: $targetMenu"
        }
        else {
            throw "管理菜单复制失败，目标文件不存在: $targetMenu"
        }

        # 命令预览与确认
        $plainPassword = ConvertTo-PlainText $passwordSecure
        $Global:ProjectPath = $projectPath
        $Global:Port = $port
        $previewConfig = Get-ProjectConfig
        Show-DockerRunPreview -Config $previewConfig -Password $plainPassword | Out-Null

        $executeCreate = Read-Host '是否执行上述命令创建容器？ [Y/n] (直接回车=创建)'
    if ($executeCreate -match '^[Nn]$') {
        Write-LogInfo '已取消立即创建。项目配置已保存，可稍后通过项目菜单启动。'
        return
    }

        # 执行创建
        Start-MySqlContainer -SkipPreview

        Write-LogSuccess "实例 mysql$port 创建完成。"
    }
    catch {
        if (-not $pathExisted -and (Test-Path $projectPath)) {
            Write-LogWarning "创建失败，正在清理创建的目录: $projectPath"
            try {
                Remove-Item -Path $projectPath -Recurse -Force
                Write-LogInfo '清理完成。'
            }
            catch {
                Write-LogWarning "清理失败: $_"
            }
        }
        throw
    }
}

#endregion

#region 主入口

function Main {
    if ($isProject) {
        Show-OperationalMenu
    }
    else {
        Show-SetupMenu
    }
}

try {
    Main
}
catch {
    Write-LogError $_.Exception.Message
}
finally {
    Write-Host "`n脚本执行结束，按任意键关闭窗口..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

#endregion
