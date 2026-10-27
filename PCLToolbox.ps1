# =====================================================================
#  PCLToolbox  v1.0
#  同时适配：
#    1) 官方 PCL（Plain Craft Launcher，Hex-Dragon/PCL2）
#    2) PCL CE（Plain Craft Launcher Community Edition，PCL-Community/PCL2-CE）
#
#  功能：一键修复下载限制；检测到启动器有新版本时可自动更新到最新版并修复。
#  工作方式：
#    * 读取当前目录下启动器的版本，下载「完全相同版本」的源码；
#    * 移除其中的下载限制（官方版：ModSecret.RestrictMcDownload = False；
#      CE 版：RegionAssessment.IsRestricted = False）；
#    * 使用官方发布时相同的编译配置重新编译，校验版本号后备份并替换原程序。
#
#  说明：官方 PCL 的发布版由非公开源码构建，其公开源码为「开源版」（缺少
#        联机/检查更新/公告/赞助等依赖官方服务器的私有实现）。因此官方 PCL
#        重编译后会恢复下载功能，但上述依赖官方服务器的功能不可用，详见
#        「README.md」。PCL CE 为完整开源，可做到与原版一致。
# =====================================================================

param(
    # 仅供自动化测试：不弹窗、自动确认
    [switch]$Unattended,
    # 可选：PCL 启动器所在目录（不传则用工具所在目录，或从上次记录/选择框获取）
    [string]$PclDir = '',
    # 可选：未检测到启动器时，直接下载官方 PCL（跳过询问）
    [switch]$DownloadOfficial,
    # 可选：未检测到启动器时，直接下载 PCL CE（跳过询问）
    [switch]$DownloadCe,
    # 可选：下载模式的安装目录（不传则询问或使用工具目录）
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Unattended = $Unattended.IsPresent

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolTitle = 'PCLToolbox'
$CeRepo = 'PCL-Community/PCL2-CE'
$OfficialRepo = 'Hex-Dragon/PCL2'
$OfficialCoreRepo = 'Meloong-Git/MeloongCore'

$CeRestrictedSince = [version]'2.15.1.0'
$OfficialRestrictedSince = [version]'2.99.0.0'

$WorkRoot = Join-Path $env:LOCALAPPDATA 'PCLDownloadFix'
$TargetDir = $ScriptDir
$LastPclDirFile = Join-Path $WorkRoot 'last-pcl-dir.txt'
$LogFile = Join-Path $WorkRoot '修复日志.txt'
$CeMarkerName = '.pcl-downloadfix.json'
$OfficialMarkerName = '.pcl-downloadfix.official.json'

$OfficialOAuthClientId = 'fe72edc2-3a6f-4280-90e8-e2beb64ce7e1'
$OfficialClsBaseUrl = 'https://ap-shanghai.cls.tencentcs.com/track?topic_id=pcl-remote-1253424809'
$OfficialCurseForgeKey = '$2a$10$7WWV1WELcwX8Xp7d68MHs.5grTyZVa6SynyeSyMh1rsE89nIa09zO'
$KnownOfficialSubmodules = @{
    '2.99.0.0' = '98157d65c7627721c816c02e8be96ac4fe61d615'
    '2.99.0.1' = '4c60c2962c3b50bc3fe96ed5dd9259b980173580'
}
# 没有 git 标签的版本 -> 发布提交（从 GitHub 提交记录确认）
$KnownOfficialCommits = @{
    '2.99.0.1' = '93ede5d9e638c99fcec853a9ba1eecd91ceee7f5'
}

# PCL CE v2.15.1 官方发布版内置密钥（“没有原程序可提取”时用于下载安装模式）
$KnownCeSecrets = @{
    '2.15.1.0' = @{
        MS_CLIENT_ID = 'c14b0370-8d75-42f8-b329-5b60d39e319f'
        CURSEFORGE_API_KEY = '$2a$10$TK3CR9laZ1oUb51B1rXZJ.UQ.bLHZGEZ8Y86nbMacMf1rorvdkBWG'
        NAID_CLIENT_ID = 'pclce2025'
        NAID_CLIENT_SECRET = '$2y$10$bOfGWPKw2zwB.EYvHxmiN.F1AN3fvUbruNrhL0QMyCYcTsOiMO2Ta'
        LINK_SERVER_ROOT = 'https://staticassets.naids.com/resources/pclce|https://s3.pysio.online/pcl2-ce'
        LOBBY_DEFAULT_SECRET = 'PCLCEETLOBBY2025'
        SENTRY_DSN = 'https://7956194f3e4cbb42cf2cd02250514c22@sentry.bakac.top/7'
        GITHUB_SHA = '1a7653127d578efdb2a9388999a3fdc67d9e49d5'
    }
}

# ---------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (-not (Test-Path $WorkRoot)) { New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Show-Msg {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    if ($script:Unattended) {
        Write-Log ("[弹窗] " + ($Text -replace "`r`n", ' | '))
        if ($Buttons -eq 'YesNo') { return [System.Windows.Forms.DialogResult]::Yes }
        return [System.Windows.Forms.DialogResult]::OK
    }
    $i = [System.Windows.Forms.MessageBoxIcon]::$Icon
    $b = [System.Windows.Forms.MessageBoxButtons]::$Buttons
    return [System.Windows.Forms.MessageBox]::Show($Text, $ToolTitle, $b, $i)
}
function Show-Info { param([string]$Text) [void](Show-Msg -Text $Text -Icon Information -Buttons OK) }
function Show-ErrorMsg {
    param([string]$Text)
    if ($script:Unattended) { Write-Log ("错误: " + $Text) 'ERROR'; exit 1 }
    [void](Show-Msg -Text $Text -Icon Error -Buttons OK)
    exit 1
}

function Save-LastPclDir {
    param([string]$Dir)
    if (-not $Dir) { return }
    if ($Dir -eq $ScriptDir) { return }
    try { Set-Content -Path $LastPclDirFile -Value $Dir -Encoding UTF8 } catch { }
}
function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        Write-Log "下载: $Url"
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $code = & $curl -L --ssl-no-revoke --connect-timeout 10 --retry 2 --retry-delay 2 -s -S -o $OutFile -w '%{http_code}' $Url 2>$null
                $curlExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if ($curlExit -eq 0 -and "$code" -eq '200' -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
            Write-Log "下载失败（第 $attempt/3 次），HTTP=$code，退出码=$curlExit" 'WARN'
            if ("$code" -in @('403', '404', '401', '410')) { break }
            Start-Sleep -Milliseconds 900
        }
        return $false
    }
    try {
        Write-Log "下载: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        return (Test-Path $OutFile)
    } catch {
        Write-Log "下载失败: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-DownloadAny {
    param([string[]]$Urls, [string]$OutFile)
    foreach ($u in ($Urls | Select-Object -Unique)) {
        if (Invoke-Download -Url $u -OutFile $OutFile) { return $true }
    }
    return $false
}

function Expand-Zip {
    param([string]$ZipPath, [string]$DestDir)
    if (Test-Path $DestDir) { Remove-Item -Recurse -Force $DestDir -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
    } catch {
        Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force
    }
}

# ---------------------------------------------------------------------
# 启动器识别
# ---------------------------------------------------------------------
function Get-Launchers {
    $list = New-Object System.Collections.Generic.List[object]
    $exes = @(Get-ChildItem -Path $TargetDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '原版备份|\.original|unins|setup|update' })
    foreach ($e in $exes) {
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($e.FullName)
            $ver = [version]$vi.FileVersion
        } catch { continue }
        $pn = [string]$vi.ProductName
        $kind = $null
        if ($pn -like '*Community Edition*') { $kind = 'CE' }
        elseif ($pn -eq 'Plain Craft Launcher' -or ($vi.FileDescription -like '*Plain Craft Launcher*' -and $pn -notlike '*Community*')) { $kind = 'Official' }
        if (-not $kind) { continue }
        $list.Add([pscustomobject]@{
            Path = $e.FullName; Kind = $kind; Version = $ver; ProductName = $pn
            FileVersion = [string]$vi.FileVersion; ProductVersion = [string]$vi.ProductVersion
            VersionInfo = $vi
        })
    }
    return , $list
}

function Test-ProcessRunning {
    param([string]$ExePath)
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    foreach ($p in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -and ($p.Path -ieq $ExePath)) { return $true } } catch { return $true }
    }
    return $false
}

function Select-Launchers {
    param($Items)
    if ($script:Unattended -or $Items.Count -le 1) { return , $Items }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$ToolTitle - 选择要修复的启动器"
    $form.Width = 470; $form.Height = 230
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Text = '检测到以下启动器，请勾选需要修复的项：'
    $label.AutoSize = $true; $label.Left = 16; $label.Top = 14
    $form.Controls.Add($label)
    $boxes = New-Object System.Collections.Generic.List[object]
    $top = 45
    foreach ($it in $Items) {
        $chk = New-Object System.Windows.Forms.CheckBox
        if ($it.Label) { $chk.Text = [string]$it.Label }
        else {
            $name = if ($it.Kind -eq 'CE') { 'PCL CE（社区版）' } else { 'PCL（官方版）' }
            $chk.Text = "$name  v$($it.Version)"
        }
        $chk.AutoSize = $true; $chk.Left = 24; $chk.Top = $top; $chk.Checked = $true
        $form.Controls.Add($chk)
        $boxes.Add([pscustomobject]@{ Item = $it; CheckBox = $chk })
        $top += 30
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '开始修复'; $ok.Left = 220; $ok.Top = $top + 15; $ok.Width = 90; $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.Left = 320; $cancel.Top = $top + 15; $cancel.Width = 90; $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($ok); $form.Controls.Add($cancel)
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.Height = $top + 95
    $res = $form.ShowDialog()
    if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return , @() }
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($b in $boxes) { if ($b.CheckBox.Checked) { $selected.Add($b.Item) } }
    return , $selected
}

# ---------------------------------------------------------------------
# 标记 / 备份 / 替换
# ---------------------------------------------------------------------
function Get-MarkerInfo {
    param([string]$Kind, [string]$ExePath)
    $file = Join-Path $TargetDir $(if ($Kind -eq 'CE') { $CeMarkerName } else { $OfficialMarkerName })
    if (-not (Test-Path $file)) { return $null }
    try {
        $m = Get-Content -Raw -Path $file | ConvertFrom-Json
        $curVer = [string](Get-Item $ExePath).VersionInfo.FileVersion
        if ([string]$m.version -ne $curVer) { return $null }
        $curHash = (Get-FileHash -Path $ExePath -Algorithm SHA256).Hash
        if ($m.patchedSha256 -and $m.patchedSha256 -eq $curHash) { return $m }
    } catch { }
    return $null
}

function Save-MarkerInfo {
    param([string]$Kind, [string]$Version, [string]$Ref, [string]$Sha256, [string]$Backup)
    $file = Join-Path $TargetDir $(if ($Kind -eq 'CE') { $CeMarkerName } else { $OfficialMarkerName })
    $obj = [ordered]@{
        tool = 'PCLDownloadAuthFix'; kind = $Kind; version = $Version; ref = $Ref
        patchedSha256 = $Sha256; backup = $Backup
        appliedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    ($obj | ConvertTo-Json) | Set-Content -Path $file -Encoding UTF8
}

function Backup-And-Replace {
    param([string]$ExePath, [string]$BuiltExe, [string]$Kind, [version]$Version)
    if (Test-ProcessRunning -ExePath $ExePath) {
        Show-ErrorMsg "PCL 正在运行，请先关闭 PCL 再运行本工具。"
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $backup = Join-Path $TargetDir ($base + '.原版备份.' + $Version + '.exe')
    if (-not (Test-Path $backup)) {
        Copy-Item -Path $ExePath -Destination $backup -Force
        Write-Log "已备份原程序: $backup"
    }
    Write-Log "替换程序: $ExePath"
    Copy-Item -Path $BuiltExe -Destination $ExePath -Force
    return $backup
}

# =====================================================================
#  PCL CE 分支
# =====================================================================
function Get-CeRef {
    param($Launcher)
    $sha = $null
    if ($Launcher.ProductVersion -match '\+([0-9a-fA-F]{7,40})') { $sha = $Matches[1].ToLowerInvariant() }
    if ($sha) { return @{ Kind = 'sha'; Value = $sha } }
    return @{ Kind = 'tag'; Value = ('v{0}.{1}.{2}' -f $Launcher.Version.Major, $Launcher.Version.Minor, $Launcher.Version.Build) }
}

function Get-CeSource {
    param([hashtable]$Ref)
    $dirName = ('ce-src-' + $Ref.Value) -replace '[^0-9A-Za-z\.\-]', '_'
    $srcDir = Join-Path $WorkRoot ('source\' + $dirName)
    if (Test-Path (Join-Path $srcDir 'PCL.Core')) { Write-Log "使用已缓存的源码: $srcDir"; return $srcDir }
    if ($Ref.Kind -eq 'sha') { $primary = "https://codeload.github.com/$CeRepo/zip/$($Ref.Value)" }
    else { $primary = "https://codeload.github.com/$CeRepo/zip/refs/tags/$($Ref.Value)" }
    $zip = Join-Path $WorkRoot ('source\' + $dirName + '.zip')
    $ok = Invoke-DownloadAny -Urls @(
        $primary,
        ($primary -replace '^https://codeload\.github\.com', 'https://gh-proxy.com/https://codeload.github.com'),
        ($primary -replace '^https://codeload\.github\.com', 'https://github.moeyy.xyz/https://codeload.github.com')
    ) -OutFile $zip
    if (-not $ok) { return $null }
    $tmp = Join-Path $WorkRoot 'source\_ce_extract'
    try { Expand-Zip -ZipPath $zip -DestDir $tmp } catch { Write-Log "解压失败: $($_.Exception.Message)" 'ERROR'; return $null }
    $root = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $root -or -not (Test-Path (Join-Path $root.FullName 'PCL.Core'))) { return $null }
    if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $srcDir) | Out-Null
    Move-Item -Path $root.FullName -Destination $srcDir
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    Write-Log "CE 源码已就绪: $srcDir"
    return $srcDir
}

function Test-CeSourceHasRestriction {
    param([string]$SrcDir)
    $region = Join-Path $SrcDir 'PCL.Core\App\Region\RegionPolicy.cs'
    if ((Test-Path $region) -and ([System.IO.File]::ReadAllText($region) -match 'IsRestricted\s*=>')) { return $true }
    return $false
}

function Update-CeSource {
    param([string]$SrcDir)
    $pattern = '(?<prefix>IsRestricted\s*=>\s*)[^;]+;'
    $donePattern = 'IsRestricted\s*=>\s*false;'
    $file = Join-Path $SrcDir 'PCL.Core\App\Region\RegionPolicy.cs'
    if (-not (Test-Path $file)) { return $false }
    $text = [System.IO.File]::ReadAllText($file)
    if ([regex]::IsMatch($text, $donePattern)) { Write-Log "CE 源码中的下载限制已移除: $file"; return $true }
    if (-not [regex]::IsMatch($text, $pattern)) { return $false }
    $patched = [regex]::Replace($text, $pattern, '${prefix}false;')
    [System.IO.File]::WriteAllText($file, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "已移除下载鉴权(CE): $file"
    return [regex]::IsMatch($patched, $donePattern)
}

function Test-BuiltSecrets {
    param([string]$ExePath, [hashtable]$Secrets)
    if ($Secrets.Count -eq 0) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $even = [System.Text.Encoding]::Unicode.GetString($bytes)
    $oddBytes = New-Object byte[] ($bytes.Length - 1)
    [System.Array]::Copy($bytes, 1, $oddBytes, 0, $bytes.Length - 1)
    $odd = [System.Text.Encoding]::Unicode.GetString($oddBytes)
    $missing = @()
    foreach ($k in $Secrets.Keys) {
        $v = [string]$Secrets[$k]
        if ([string]::IsNullOrEmpty($v)) { continue }
        if ($even.IndexOf($v, [System.StringComparison]::Ordinal) -lt 0 -and
            $odd.IndexOf($v, [System.StringComparison]::Ordinal) -lt 0) { $missing += $k }
    }
    return $missing
}

function Read-Utf16Run {
    param([byte[]]$Bytes, [int]$Start, [int]$MaxChars = 512)
    $sb = New-Object System.Text.StringBuilder
    $q = $Start
    while (($q + 1) -lt $Bytes.Length -and $sb.Length -lt $MaxChars) {
        $lo = $Bytes[$q]; $hi = $Bytes[$q + 1]
        if ($hi -ne 0 -or $lo -lt 0x20 -or $lo -ge 0x7F) { break }
        [void]$sb.Append([char]$lo); $q += 2
    }
    return $sb.ToString()
}

function Get-CeEmbeddedSecrets {
    param([string]$ExePath)
    $keys = @('MS_CLIENT_ID', 'CURSEFORGE_API_KEY', 'TELEMETRY_KEY', 'NAID_CLIENT_ID',
              'NAID_CLIENT_SECRET', 'LINK_SERVER_ROOT', 'LOBBY_DEFAULT_SECRET', 'SENTRY_DSN', 'GITHUB_SHA')
    $patterns = @{
        MS_CLIENT_ID        = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        CURSEFORGE_API_KEY  = '^\$2[aby]\$[0-9A-Za-z\./$]{20,}$'
        TELEMETRY_KEY       = '^[0-9a-fA-F]{32}$'
        NAID_CLIENT_ID      = '^[A-Za-z0-9_\-\.]{3,64}$'
        NAID_CLIENT_SECRET  = '^\$2[aby]\$[0-9A-Za-z\./$]{20,}$'
        LINK_SERVER_ROOT    = '^https?://\S+$'
        LOBBY_DEFAULT_SECRET = '^[A-Za-z0-9_\-]{4,128}$'
        SENTRY_DSN          = '^https?://[^@\s]+@\S+$'
        GITHUB_SHA          = '^[0-9a-fA-F]{40}$'
    }
    $result = @{}
    Write-Log "读取原版内置密钥: $ExePath"
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $even = [System.Text.Encoding]::Unicode.GetString($bytes)
    $oddBytes = New-Object byte[] ($bytes.Length - 1)
    [System.Array]::Copy($bytes, 1, $oddBytes, 0, $bytes.Length - 1)
    $odd = [System.Text.Encoding]::Unicode.GetString($oddBytes)
    $streams = @(@($even, 0), @($odd, 1))
    $anchor = -1
    foreach ($s in $streams) {
        $text = $s[0]; $align = $s[1]
        $idx = 0
        while (($idx = $text.IndexOf('MS_CLIENT_ID', $idx, [System.StringComparison]::Ordinal)) -ge 0) {
            $base = $idx * 2 + $align + ('MS_CLIENT_ID'.Length * 2)
            for ($off = 0; $off -lt 8; $off++) {
                $c = Read-Utf16Run -Bytes $bytes -Start ($base + $off)
                if ($c -match $patterns['MS_CLIENT_ID']) { $anchor = $base + $off; break }
            }
            if ($anchor -ge 0) { break }
            $idx += 1
        }
        if ($anchor -ge 0) { break }
    }
    foreach ($key in $keys) {
        $best = $null; $bestDist = [int]::MaxValue
        foreach ($s in $streams) {
            $text = $s[0]; $align = $s[1]
            $idx = 0
            while (($idx = $text.IndexOf($key, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
                $base = $idx * 2 + $align + ($key.Length * 2)
                for ($off = 0; $off -lt 8; $off++) {
                    $cand = Read-Utf16Run -Bytes $bytes -Start ($base + $off)
                    if ($cand.Length -lt 3) { continue }
                    if ($keys -contains $cand) { continue }
                    if ($cand -notmatch $patterns[$key]) { continue }
                    $pos = $base + $off; $dist = 0
                    if ($anchor -ge 0) { $dist = [Math]::Abs($pos - $anchor); if ($dist -gt 65536) { continue } }
                    if ($dist -lt $bestDist) { $best = $cand; $bestDist = $dist }
                    break
                }
                $idx += 1
            }
        }
        if ($best) { $result[$key] = $best; Write-Log ("  {0} = {1}" -f $key, $best) }
        else { Write-Log ("  {0} = <未找到>" -f $key) 'WARN' }
    }
    if ($result['GITHUB_SHA'] -eq '1a7653127d578efdb2a9388999a3fdc67d9e49d5') {
        $result['MS_CLIENT_ID'] = 'c14b0370-8d75-42f8-b329-5b60d39e319f'
        $result['CURSEFORGE_API_KEY'] = '$2a$10$TK3CR9laZ1oUb51B1rXZJ.UQ.bLHZGEZ8Y86nbMacMf1rorvdkBWG'
        $result['NAID_CLIENT_ID'] = 'pclce2025'
        $result['NAID_CLIENT_SECRET'] = '$2y$10$bOfGWPKw2zwB.EYvHxmiN.F1AN3fvUbruNrhL0QMyCYcTsOiMO2Ta'
        $result['LINK_SERVER_ROOT'] = 'https://staticassets.naids.com/resources/pclce|https://s3.pysio.online/pcl2-ce'
        $result['LOBBY_DEFAULT_SECRET'] = 'PCLCEETLOBBY2025'
        $result['SENTRY_DSN'] = 'https://7956194f3e4cbb42cf2cd02250514c22@sentry.bakac.top/7'
        Write-Log '已使用 PCL CE v2.15.1 官方发布版的已知内置密钥校准'
    }
    return $result
}

function Invoke-CePublish {
    param([string]$Dotnet, [string]$SrcDir, [hashtable]$Secrets, [string]$CommitSha, [string]$OutputDir)
    $csproj = Join-Path $SrcDir 'Plain Craft Launcher 2\Plain Craft Launcher 2.csproj'
    if (-not (Test-Path $csproj)) { throw "找不到项目文件: $csproj" }
    foreach ($p in @('PCL.Core', 'PCL.Core.SourceGenerators', 'Plain Craft Launcher 2')) {
        foreach ($sub in @('obj', 'bin')) {
            $d = Join-Path $SrcDir ("$p\$sub")
            if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
        }
    }
    if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'; $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:MSBUILDDISABLENODEREUSE = '1'; $env:DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER = '1'
    try { & $Dotnet build-server shutdown 2>&1 | Out-Null } catch { }
    foreach ($k in $Secrets.Keys) { Set-Item -Path ("Env:PCL_" + $k) -Value $Secrets[$k] }
    if ($Secrets.Count -gt 0) { $env:PCL_WRITE_SECRET = '1' }
    $args = @('publish', $csproj, '-c', 'Release', '-p:Platform=x64', '-p:DeleteExistingFiles=true',
              '-p:UseSharedCompilation=false', '--no-self-contained', '-o', $OutputDir)
    if ($CommitSha) { $args += ('-p:SourceRevisionId=' + $CommitSha) }
    Write-Log ('执行: ' + $Dotnet + ' ' + ($args -join ' '))
    $outLog = Join-Path $WorkRoot 'build-ce.log'
    if (Test-Path $outLog) { Remove-Item -Force $outLog }
    $output = (& $Dotnet @args 2>&1 | Out-String)
    Set-Content -Path $outLog -Value $output -Encoding UTF8
    if ($LASTEXITCODE -ne 0) {
        throw ("CE 编译失败（退出码 $LASTEXITCODE）。日志：$outLog`r`n" + ((($output -split "\r?\n") | Select-Object -Last 15) -join "`r`n"))
    }
    Write-Log 'CE 编译成功'
    return (Join-Path $OutputDir 'Plain Craft Launcher 2.exe')
}

# =====================================================================
#  官方 PCL 分支
# =====================================================================
function Ensure-Dotnet {
    $localDotnet = Join-Path $WorkRoot 'dotnet\dotnet.exe'
    $sys = Get-Command 'dotnet' -ErrorAction SilentlyContinue
    if ($sys) {
        try { $sdks = @(& $sys.Source --list-sdks 2>$null); if ($sdks | Where-Object { $_ -match '^10\.' }) { Write-Log "使用系统 .NET SDK: $($sys.Source)"; return $sys.Source } } catch { }
    }
    if (Test-Path $localDotnet) {
        try { $sdks = @(& $localDotnet --list-sdks 2>$null); if ($sdks | Where-Object { $_ -match '^10\.' }) { Write-Log "使用已下载的 .NET SDK: $localDotnet"; return $localDotnet } } catch { }
    }
    Write-Log '未找到 .NET 10 SDK，开始下载（约 300 MB，只需一次）…'
    $zip = Join-Path $WorkRoot 'sdk\dotnet-sdk-win-x64.zip'
    $ok = Invoke-DownloadAny -Urls @(
        'https://aka.ms/dotnet/10.0/dotnet-sdk-win-x64.zip',
        'https://dotnetcli.azureedge.net/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-win-x64.zip'
    ) -OutFile $zip
    if (-not $ok) { return $null }
    Write-Log '解压 .NET SDK…'
    $dest = Join-Path $WorkRoot 'dotnet'
    Expand-Zip -ZipPath $zip -DestDir $dest
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    if (Test-Path $localDotnet) { $env:DOTNET_ROOT = $dest; return $localDotnet }
    return $null
}

function Find-MSBuild {
# 测试钩子：设置该环境变量可模拟没有 MSBuild 的电脑
    if ($env:PCLTOOLBOX_NO_MSBUILD -eq '1') { Write-Log '测试环境：忽略 MSBuild 检测' 'WARN'; return $null }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        try {
            $p = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
            if ($p -and (Test-Path $p)) { Write-Log "使用 MSBuild: $p"; return $p }
        } catch { }
    }
    $cmd = Get-Command 'msbuild' -ErrorAction SilentlyContinue
    if ($cmd) { Write-Log "使用 MSBuild: $($cmd.Source)"; return $cmd.Source }
    return $null
}

function Ensure-Net48Refs {
    $cached = Join-Path $WorkRoot 'net48refs'
    $refRoot = Join-Path $cached 'build'
    if (Test-Path (Join-Path $refRoot '.NETFramework\v4.8\mscorlib.dll')) { return $refRoot }
    $pkgRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.netframework.referenceassemblies.net48\1.0.3\build'
    if (Test-Path (Join-Path $pkgRoot '.NETFramework\v4.8\mscorlib.dll')) { return $pkgRoot }
    Write-Log '下载 .NET Framework 4.8 参考程序集…'
    $nupkg = Join-Path $WorkRoot 'net48refs.nupkg'
    $ok = Invoke-DownloadAny -Urls @(
        'https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies.net48/1.0.3/microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg'
    ) -OutFile $nupkg
    if (-not $ok) { return $null }
    Expand-Zip -ZipPath $nupkg -DestDir $cached
    Remove-Item -Force $nupkg -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $refRoot '.NETFramework\v4.8\mscorlib.dll')) { return $refRoot }
    return $null
}

function Invoke-GitHubApiJson {
    param([string]$Url, [string]$CacheName, [int]$MaxAgeHours = 6)
    $out = Join-Path $WorkRoot ('meta\' + $CacheName)
    # 缓存有效期内直接复用（减少 GitHub API 调用，避免触发限流）
    if (Test-Path $out) {
        try {
            $age = (Get-Date) - (Get-Item $out).LastWriteTime
            $txt = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
            if ($txt.Trim().Length -gt 10 -and $age.TotalHours -lt $MaxAgeHours) {
                return ($txt | ConvertFrom-Json)
            }
        } catch { }
    }
    $tmp = $out + '.tmp'
    if (Invoke-DownloadAny -Urls @($Url) -OutFile $tmp) {
        try {
            $txt = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
            Move-Item -Path $tmp -Destination $out -Force
            return ($txt | ConvertFrom-Json)
        } catch { return $null }
    }
    # 网络/限流失败时回退到旧缓存
    if (Test-Path $out) {
        try {
            $txt = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
            if ($txt.Trim().Length -gt 10) {
                Write-Log '版本检查请求失败，改用上一次的缓存结果' 'WARN'
                return ($txt | ConvertFrom-Json)
            }
        } catch { }
    }
    return $null
}

function Get-LatestCeFromAtom {
    $out = Join-Path $WorkRoot 'meta\ce-tags.atom'
    if (-not (Invoke-DownloadAny -Urls @('https://github.com/PCL-Community/PCL2-CE/tags.atom') -OutFile $out)) { return $null }
    try {
        $atomText = Get-Content -Raw -Path $out -Encoding UTF8
        [xml]$xml = $atomText
        $best = $null; $bestTag = $null
        foreach ($e in $xml.feed.entry) {
            $tagName = $null
            $href = [string]$e.link.href
            if ($href -match '/releases/tag/([^/]+)$') { $tagName = $Matches[1] }
            if (-not $tagName) {
                $title = ([string]$e.title).Trim()
                if ($title -match '^(v?\d+\.\d+\.\d+)$') { $tagName = $title }
            }
            if ($tagName -and $tagName -match '^v?(\d+\.\d+\.\d+)$') {
                $v = [version]("$($Matches[1]).0")
                if (-not $best -or $v -gt $best) { $best = $v; $bestTag = $tagName }
            }
        }
        if ($best) { return @{ Version = $best; Tag = $bestTag } }
    } catch { }
    return $null
}

function Get-LatestOfficialFromAtom {
    $out = Join-Path $WorkRoot 'meta\official-commits.atom'
    if (-not (Invoke-DownloadAny -Urls @('https://github.com/Hex-Dragon/PCL2/commits/main.atom') -OutFile $out)) { return $null }
    try {
        $atomText = Get-Content -Raw -Path $out -Encoding UTF8
        [xml]$xml = $atomText
        $best = $null; $bestSha = $null; $bestMsg = $null
        foreach ($e in $xml.feed.entry) {
            $title = ([string]$e.title).Trim()
            if ($title -match '^(\d+(?:\.\d+){2,3})\s*正式版$') {
                $v = [version]$Matches[1]
                $sha = $null
                $link = [string]$e.link.href
                if ($link -match '/commit/([0-9a-f]{40})') { $sha = $Matches[1] }
                if (-not $sha) { $id = [string]$e.id; if ($id -match '([0-9a-f]{40})') { $sha = $Matches[1] } }
                if ($sha) { if (-not $best -or $v -gt $best) { $best = $v; $bestSha = $sha; $bestMsg = $title } }
            }
        }
        if ($best) { return @{ Version = $best; Commit = $bestSha; Message = $bestMsg } }
    } catch { }
    return $null
}
function Get-LatestCeInfo {
    # 优先读 GitHub Releases 的 latest（正式版）；失败则按 tags 取最高稳定版本
    $j = Invoke-GitHubApiJson -Url "https://api.github.com/repos/$CeRepo/releases/latest" -CacheName 'ce-latest.json'
    if ($j -and $j.tag_name) {
        $tag = [string]$j.tag_name
        if ($tag -match '^v?(\d+\.\d+\.\d+)$') { return @{ Version = [version]("$($Matches[1]).0"); Tag = ('v' + $Matches[1]) } }
    }
    $tags = Invoke-GitHubApiJson -Url "https://api.github.com/repos/$CeRepo/tags?per_page=100" -CacheName 'ce-tags.json'
    $best = $null; $bestTag = $null
    if ($tags) {
        foreach ($t in $tags) {
            $name = [string]$t.name
            if ($name -match '^v?(\d+\.\d+\.\d+)$') {
                $v = [version]("$($Matches[1]).0")
                if (-not $best -or $v -gt $best) { $best = $v; $bestTag = $name }
            }
        }
    }
    if ($best) { return @{ Version = $best; Tag = $bestTag } }
    $atom = Get-LatestCeFromAtom
    if ($atom) { Write-Log "通过 Atom 订阅获取 PCL CE 最新版本: v$($atom.Version)" 'WARN'; return $atom }
    return $null
}

function Get-LatestOfficialInfo {
    # 官方 PCL 的最新版本 = 提交记录中 <版本号> 正式版 的最大版本
    # 先取最近 30 条（数据量小、成功率高），没找到再取 100 条
    foreach ($perPage in @(30, 100)) {
        $j = Invoke-GitHubApiJson -Url "https://api.github.com/repos/$OfficialRepo/commits?per_page=$perPage" -CacheName "official-commits-$perPage.json"
        if (-not $j) { continue }
        $best = $null; $bestSha = $null; $bestMsg = $null
        foreach ($cm in $j) {
            $first = [string](($cm.commit.message -split "`n")[0]).Trim()
            if ($first -match '^(\d+(?:\.\d+){2,3})\s*正式版$') {
                $v = [version]$Matches[1]
                if (-not $best -or $v -gt $best) { $best = $v; $bestSha = [string]$cm.sha; $bestMsg = $first }
            }
        }
        if ($best) { return @{ Version = $best; Commit = $bestSha; Message = $bestMsg } }
    }
    $atom = Get-LatestOfficialFromAtom
    if ($atom) { Write-Log "通过 Atom 订阅获取官方 PCL 最新版本: v$($atom.Version)" 'WARN'; return $atom }
    return $null
}
function Get-OfficialTagCandidates {
    param([version]$Version)
    $v4 = $Version.ToString()
    $v3 = '{0}.{1}.{2}' -f $Version.Major, $Version.Minor, $Version.Build
    return @($v4, "v$v4", $v3, "v$v3")
}

function Get-OfficialSource {
    param([version]$Version, [string]$PreferredCommit = '')
        $verText = $Version.ToString()
    $srcDir = Join-Path $WorkRoot ('official\src-' + $verText)
    if ((Test-Path (Join-Path $srcDir 'Plain Craft Launcher 2\Plain Craft Launcher 2.vbproj')) -and
        (Test-Path (Join-Path $srcDir 'MeloongCore\Shared\MeloongCore.csproj'))) {
        Write-Log "使用已缓存的官方源码: $srcDir"
        return $srcDir
    }
    if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir -ErrorAction SilentlyContinue }
    $zip = Join-Path $WorkRoot ('official\pcl-' + $verText + '.zip')
    $ref = $null
    foreach ($t in (Get-OfficialTagCandidates $Version)) {
        $primary = "https://codeload.github.com/$OfficialRepo/zip/refs/tags/$t"
        $ok = Invoke-DownloadAny -Urls @(
            $primary,
            ($primary -replace '^https://codeload\.github\.com', 'https://gh-proxy.com/https://codeload.github.com'),
            ($primary -replace '^https://codeload\.github\.com', 'https://github.moeyy.xyz/https://codeload.github.com')
        ) -OutFile $zip
        if ($ok) { $ref = $t; break }
        Write-Log "标签 $t 下载失败，尝试下一个…" 'WARN'
    }
    if (-not $ref -and $PreferredCommit) {
        $ref = $PreferredCommit
        Write-Log "使用指定的发布提交: $ref"
    }
    if (-not $ref) {
        # 没有对应 git 标签（例如官方 2.99.0.1）：从提交记录中找“<版本号> 正式版”提交
        Write-Log "未找到 v$verText 的 git 标签，改为从 GitHub 提交记录定位源码…"
        $commitsOut = Join-Path $WorkRoot 'official\commits.json'
        if (Invoke-DownloadAny -Urls @("https://api.github.com/repos/$OfficialRepo/commits?per_page=100") -OutFile $commitsOut) {
            try {
                $commits = [System.IO.File]::ReadAllText($commitsOut, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $escVer = [regex]::Escape($verText)
                $matched = @($commits | Where-Object {
                    $first = [string](($_.commit.message -split "`n")[0]).Trim()
                    $first -match ("^v?" + $escVer + "(\s|$)")
                })
                if ($matched.Count -gt 0) {
                    $rel = @($matched | Where-Object { [string](($_.commit.message -split "`n")[0]) -match '正式版' })
                    if ($rel.Count -gt 0) { $ref = $rel[0].sha } else { $ref = $matched[0].sha }
                }
            } catch { Write-Log "解析提交记录失败: $($_.Exception.Message)" 'WARN' }
        }
        if (-not $ref -and $KnownOfficialCommits.ContainsKey($verText)) {
            $ref = $KnownOfficialCommits[$verText]
            Write-Log "使用已知发布提交: $ref"
        }
        if (-not $ref) { Write-Log "无法定位官方 v$verText 的源码提交（GitHub 上可能尚未提供该版本的公开源码）" 'ERROR'; return $null }
        $primary = "https://codeload.github.com/$OfficialRepo/zip/$ref"
        $ok = Invoke-DownloadAny -Urls @(
            $primary,
            ($primary -replace '^https://codeload\.github\.com', 'https://gh-proxy.com/https://codeload.github.com'),
            ($primary -replace '^https://codeload\.github\.com', 'https://github.moeyy.xyz/https://codeload.github.com')
        ) -OutFile $zip
        if (-not $ok) { Write-Log "下载源码归档失败: $ref" 'ERROR'; return $null }
        Write-Log "官方 PCL 源码提交: $ref"
    } else {
        Write-Log "官方 PCL 源码标签: $ref"
    }
    $tmp = Join-Path $WorkRoot 'official\_extract'
    try { Expand-Zip -ZipPath $zip -DestDir $tmp } catch { Write-Log "解压失败: $($_.Exception.Message)" 'ERROR'; return $null }
    $root = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $root -or -not (Test-Path (Join-Path $root.FullName 'Plain Craft Launcher 2\Plain Craft Launcher 2.vbproj'))) { return $null }
    if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $srcDir) | Out-Null
    Move-Item -Path $root.FullName -Destination $srcDir
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item -Force $zip -ErrorAction SilentlyContinue

    $subSha = $KnownOfficialSubmodules[$verText]
    if (-not $subSha) {
        Write-Log '查询 MeloongCore 子模块提交…'
        $apiUrl = "https://api.github.com/repos/$OfficialRepo/contents/MeloongCore?ref=$ref"
        $apiOut = Join-Path $WorkRoot 'official\submodule.json'
        if (Invoke-DownloadAny -Urls @($apiUrl) -OutFile $apiOut) {
            $apiText = [System.IO.File]::ReadAllText($apiOut)
            if ($apiText -match '"sha"\s*:\s*"([0-9a-fA-F]{40})"') { $subSha = $Matches[1].ToLowerInvariant() }
        }
    }
    if (-not $subSha) { Write-Log '无法确定 MeloongCore 子模块提交' 'ERROR'; return $null }
    Write-Log "MeloongCore 提交: $subSha"
    $mcZip = Join-Path $WorkRoot 'official\meloongcore.zip'
    $ok = Invoke-DownloadAny -Urls @(
        "https://codeload.github.com/$OfficialCoreRepo/zip/$subSha",
        "https://gh-proxy.com/https://codeload.github.com/$OfficialCoreRepo/zip/$subSha"
    ) -OutFile $mcZip
    if (-not $ok) { return $null }
    $mcTmp = Join-Path $WorkRoot 'official\_mc_extract'
    try { Expand-Zip -ZipPath $mcZip -DestDir $mcTmp } catch { return $null }
    $mcRoot = Get-ChildItem -Path $mcTmp -Directory | Select-Object -First 1
    if (-not $mcRoot -or -not (Test-Path (Join-Path $mcRoot.FullName 'Shared\MeloongCore.csproj'))) { Write-Log 'MeloongCore 源码结构异常' 'ERROR'; return $null }
    $mcDst = Join-Path $srcDir 'MeloongCore'
    if (Test-Path $mcDst) { Remove-Item -Recurse -Force $mcDst }
    Move-Item -Path $mcRoot.FullName -Destination $mcDst
    Remove-Item -Recurse -Force $mcTmp -ErrorAction SilentlyContinue
    Remove-Item -Force $mcZip -ErrorAction SilentlyContinue
    Write-Log "官方 PCL 源码已就绪: $srcDir"
    return $srcDir
}

function Get-OfficialRestrictionState {
    param([string]$SrcDir)
    $ms = Join-Path $SrcDir 'Plain Craft Launcher 2\Modules\ModSecret.vb'
    if (-not (Test-Path $ms)) { return 'Absent' }
    $text = [System.IO.File]::ReadAllText($ms)
    if ($text -match 'RestrictMcDownload\s+As\s+Boolean\s*=\s*True') { return 'Restricted' }
    if ($text -match 'RestrictMcDownload\s+As\s+Boolean\s*=\s*False') { return 'Patched' }
    return 'Absent'
}

function Update-OfficialSource {
    param([string]$SrcDir)
    $ms = Join-Path $SrcDir 'Plain Craft Launcher 2\Modules\ModSecret.vb'
    if (-not (Test-Path $ms)) { return $false }
    $c = [System.IO.File]::ReadAllText($ms, [System.Text.Encoding]::UTF8)
    $repl = @(
        @('Public Const RestrictMcDownload As Boolean = True', 'Public Const RestrictMcDownload As Boolean = False'),
        @('Public Const VersionBranchMain As String = "OpenSource"', 'Public Const VersionBranchMain As String = "Official"'),
        @('Public Const RegFolder As String = "PCLDebug"', 'Public Const RegFolder As String = "PCL"'),
        @('If(Environment.GetEnvironmentVariable("PCL_MS_CLIENT_ID"), "")', ('If(Environment.GetEnvironmentVariable("PCL_MS_CLIENT_ID"), "' + $OfficialOAuthClientId + '")')),
        @('Public Const ClsBaseUrl As String = ""', ('Public Const ClsBaseUrl As String = "' + $OfficialClsBaseUrl + '"')),
        @('If(Environment.GetEnvironmentVariable("PCL_CURSEFORGE_API_KEY"), "")', ('If(Environment.GetEnvironmentVariable("PCL_CURSEFORGE_API_KEY"), "' + $OfficialCurseForgeKey + '")')),
        @('$"http://{VersionCode}.open.pcl2.server/"', '$"http://{VersionCode}.pcl2.server/"')
    )
    $missing = @()
    foreach ($pair in $repl) {
        if ($c.Contains($pair[0])) { $c = $c.Replace($pair[0], $pair[1]) }
        else { $missing += $pair[0] }
    }
    if ($missing.Count -gt 0) { Write-Log ("官方源码中未找到以下待替换内容（可能版本结构已变化）：" + ($missing -join ' ; ')) 'WARN' }

    $stub = "    Friend Function GetIdentify() As String`n        Return `"0000-0000-0000-0000`"`n    End Function"
    $impl = @'
    Friend Function GetIdentify() As String
        Try
            If ModBase.ApplicationStartTick < 1 Then Return "0000-0000-0000-0000"
            Dim HardwareId As String
            Try
                HardwareId = RegistryUtils.TryRead("HKEY_LOCAL_MACHINE\SYSTEM\HardwareConfig", "LastConfig", "Unknown").ToString().ToUpperInvariant().Trim("{"c, "}"c)
            Catch ex As Exception
                Logger.Warn(ex, "获取主板标识码失败", LogBehavior.Toast)
                HardwareId = "Unknown"
            End Try
            Dim Seed As String
            Try
                Seed = Settings.Get(Of String)("Identify")
            Catch ex As Exception
                Seed = ""
            End Try
            If Seed.Length < 3 Then
                Seed = GetTimeMs().ToString() & My.Computer.Info.AvailablePhysicalMemory.ToString()
                Settings.Set("Identify", Seed)
            End If
            Dim Hash As String = (HardwareId & Seed).GetStableHashCode().ToString("X").EnsureLength("7"c, 16)
            Return $"{Hash.Substring(4, 4)}-{Hash.Substring(12, 4)}-{Hash.Substring(0, 4)}-{Hash.Substring(8, 4)}"
        Catch ex As Exception
            Logger.Warn(ex, "获取设备识别码失败", LogBehavior.Toast)
            Return "0000-0000-0000-0000"
        End Try
    End Function
'@
    $c = $c.Replace("`r`n", "`n")
    if ($c.Contains($stub)) { $c = $c.Replace($stub, $impl.Replace("`r`n", "`n")) }
    else { Write-Log '未能定位 GetIdentify 占位实现（解密兼容性可能受影响）' 'WARN' }
    [System.IO.File]::WriteAllText($ms, $c, (New-Object System.Text.UTF8Encoding($true)))
    Write-Log "已修改官方版 ModSecret.vb（关闭下载限制等）"
    return ([System.IO.File]::ReadAllText($ms) -match 'RestrictMcDownload\s+As\s+Boolean\s*=\s*False')
}

function Invoke-OfficialBuild {
    param([string]$SrcDir, [string]$Dotnet, [string]$MSBuild, [string]$RefRoot, [version]$Version)
    $dotnetRoot = Split-Path -Parent $Dotnet
    $sdkPath = Join-Path $dotnetRoot 'sdk'
    if (-not (Test-Path $sdkPath)) { throw "找不到 .NET SDK 目录: $sdkPath" }
    $sdkVerDir = Get-ChildItem $sdkPath -Directory | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $sdkVerDir) { throw "SDK 目录为空: $sdkPath" }
    $env:MSBuildSDKsPath = Join-Path $sdkVerDir.FullName 'Sdks'
    $env:MSBuildEnableWorkloadResolver = 'false'
    Write-Log "MSBuildSDKsPath: $($env:MSBuildSDKsPath)"

    Write-Log '构建 PCLCS（含依赖）…'
    $pclcs = Join-Path $SrcDir 'PCLCS\PCLCS.csproj'
    $out1 = (& $Dotnet build $pclcs -c Release --nologo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ("PCLCS 构建失败：`r`n" + ((($out1 -split "\r?\n") | Select-Object -Last 20) -join "`r`n")) }

    $proj = Join-Path $SrcDir 'Plain Craft Launcher 2\Plain Craft Launcher 2.vbproj'
    if (-not (Test-Path $proj)) { throw "找不到官方 PCL 项目文件: $proj" }
    Write-Log '使用 MSBuild 编译官方 PCL…'
    $buildLog = Join-Path $WorkRoot 'build-official.log'
    if (Test-Path $buildLog) { Remove-Item -Force $buildLog }
    $args = @(
        $proj,
        '/p:Configuration=Release',
        "/p:TargetFrameworkRootPath=$RefRoot\",
        '/p:MSBuildEnableWorkloadResolver=false',
        '/p:_NeedToDownloadMicrosoftNetSdkCompilersToolsetPackage=false',
        '/v:m', '/nologo'
    )
    $output = (& $MSBuild @args 2>&1 | Out-String)
    Set-Content -Path $buildLog -Value $output -Encoding UTF8
    if ($LASTEXITCODE -ne 0) {
        throw ("官方 PCL 编译失败（退出码 $LASTEXITCODE）。日志：$buildLog`r`n" + ((($output -split "\r?\n") | Select-Object -Last 25) -join "`r`n"))
    }
    $built = Join-Path $SrcDir 'Plain Craft Launcher 2\bin\Plain Craft Launcher 2.exe'
    if (-not (Test-Path $built)) { throw "编译未产生可执行文件: $built" }
    Write-Log '官方 PCL 编译成功'
    return $built
}

# =====================================================================
#  主流程
# =====================================================================
function Get-CeSecretsForBuild {
    param([string]$Tag, [version]$Version)
    $key = [string]$Version
    if ($KnownCeSecrets.ContainsKey($key)) {
        Write-Log "使用 PCL CE v$key 的已知内置密钥"
        return $KnownCeSecrets[$key]
    }
    Write-Log "尝试下载 PCL CE 官方发布版以提取内置密钥…"
    $assetUrl = "https://github.com/$CeRepo/releases/download/$Tag/PCL2_CE_Release_x64.exe"
    $out = Join-Path $WorkRoot 'official\ce-release-asset.exe'
    if (Invoke-DownloadAny -Urls @($assetUrl) -OutFile $out) {
        $s = Get-CeEmbeddedSecrets -ExePath $out
        if ($s -and $s.Count -gt 0) { return $s }
    }
    return $null
}

function Show-NoLauncherChoice {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$ToolTitle - 未找到启动器"
    $form.Size = New-Object System.Drawing.Size(600, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "没有在当前目录检测到 PCL 启动器（PCL2_CE.exe / Plain Craft Launcher 2.exe）。`r`n`r`n请选择下一步操作："
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(550, 60)
    $form.Controls.Add($lbl)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '选择已有 PCL 文件夹…'
    $btnBrowse.Location = New-Object System.Drawing.Point(40, 110)
    $btnBrowse.Size = New-Object System.Drawing.Size(210, 40)
    $btnBrowse.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnBrowse)
    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = '直接下载启动器'
    $btnDownload.Location = New-Object System.Drawing.Point(270, 110)
    $btnDownload.Size = New-Object System.Drawing.Size(160, 40)
    $btnDownload.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnDownload)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(450, 110)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 40)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = "「选择已有 PCL 文件夹」用于启动器放在其他位置；`r`n「直接下载启动器」由工具联网编译一个已恢复下载功能的最新版。"
    $tip.Location = New-Object System.Drawing.Point(20, 180)
    $tip.Size = New-Object System.Drawing.Size(550, 50)
    $form.Controls.Add($tip)
    $form.AcceptButton = $btnBrowse
    $form.CancelButton = $btnCancel
    $form.TopMost = $true
    $res = $form.ShowDialog()
    $form.Dispose()
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { return 'Browse' }
    if ($res -eq [System.Windows.Forms.DialogResult]::No) { return 'Download' }
    return 'Cancel'
}
function Show-DownloadDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$ToolTitle - 下载启动器"
    $form.Size = New-Object System.Drawing.Size(620, 380)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "没有检测到 PCL 启动器。`r`n`r`n是否下载一个已经恢复下载功能的最新版启动器？（可多选）"
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(570, 55)
    $form.Controls.Add($lbl)
    $chkOfficial = New-Object System.Windows.Forms.CheckBox
    $chkOfficial.Text = '官方 PCL（Plain Craft Launcher，最新正式版，已恢复下载功能）'
    $chkOfficial.Location = New-Object System.Drawing.Point(35, 80)
    $chkOfficial.Size = New-Object System.Drawing.Size(540, 24)
    $form.Controls.Add($chkOfficial)
    $chkCe = New-Object System.Windows.Forms.CheckBox
    $chkCe.Text = 'PCL CE（社区版，最新正式版，已恢复下载功能）'
    $chkCe.Location = New-Object System.Drawing.Point(35, 110)
    $chkCe.Size = New-Object System.Drawing.Size(540, 24)
    $form.Controls.Add($chkCe)
    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = "下载并编译需要联网（首次可能需要 5~20 分钟）。`r`n官方 PCL 需要本机安装 Visual Studio 2022 / VS Build Tools（含 MSBuild）；PCL CE 只需要 .NET SDK（工具会自动下载）。"
    $tip.Location = New-Object System.Drawing.Point(20, 150)
    $tip.Size = New-Object System.Drawing.Size(570, 50)
    $form.Controls.Add($tip)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '开始下载'
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = New-Object System.Drawing.Point(390, 285)
    $btnOk.Size = New-Object System.Drawing.Size(95, 30)
    $form.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(495, 285)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 30)
    $form.Controls.Add($btnCancel)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel
    $form.TopMost = $true
    $res = $form.ShowDialog()
    $kinds = New-Object System.Collections.Generic.List[string]
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($chkOfficial.Checked) { $kinds.Add('Official') }
        if ($chkCe.Checked) { $kinds.Add('CE') }
    }
    $form.Dispose()
    return , $kinds
}

function Invoke-FreshInstall {
    param([string]$Kind, [string]$InstallDir, [string]$Dotnet, [string]$MSBuild, [string]$RefRoot)
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ($Kind -eq 'CE') {
        $info = Get-LatestCeInfo
        if (-not $info) { throw "无法获取 PCL CE 最新版本（需要能访问 GitHub）" }
        $targetVer = [version]$info.Version
        $ref = @{ Kind = 'tag'; Value = [string]$info.Tag }
        Write-Log "下载模式：PCL CE v$targetVer（tag=$($ref.Value)）"
        $src = Get-CeSource -Ref $ref
        if (-not $src) { throw "下载 PCL CE v$targetVer 源码失败" }
        if (-not (Test-CeSourceHasRestriction $src)) { throw "PCL CE v$targetVer 源码中未找到下载鉴权代码" }
        if (-not (Update-CeSource -SrcDir $src)) { throw "无法移除 PCL CE 下载鉴权代码" }
        $secrets = Get-CeSecretsForBuild -Tag ([string]$ref.Value) -Version $targetVer
        if (-not $secrets) { throw "无法获取 PCL CE v$targetVer 的内置密钥" }
        $commitSha = $null
        if ($secrets['GITHUB_SHA'] -match '^[0-9a-fA-F]{40}$') { $commitSha = $secrets['GITHUB_SHA'] }
        $artifact = Join-Path $WorkRoot ('artifact-ce-' + $ref.Value)
        $built = Invoke-CePublish -Dotnet $Dotnet -SrcDir $src -Secrets $secrets -CommitSha $commitSha -OutputDir $artifact
        $bvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($built)
        if ([version]$bvi.FileVersion -ne $targetVer) { throw "CE 编译产物版本 v$($bvi.FileVersion) 与目标 v$targetVer 不一致" }
        if ($bvi.ProductName -notlike '*Community Edition*') { throw "CE 编译产物 ProductName 异常: $($bvi.ProductName)" }
        $missing = @(Test-BuiltSecrets -ExePath $built -Secrets $secrets)
        if ($missing.Count -gt 0) { throw ("CE 编译产物缺少内置密钥: " + ($missing -join ', ')) }
        $dest = Join-Path $InstallDir 'PCL2_CE.exe'
        Copy-Item $built $dest -Force
        $hash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
        Save-MarkerInfo -Kind 'CE' -Version ([string]$targetVer) -Ref ([string]$ref.Value) -Sha256 $hash -Backup ''
        return "PCL CE v$targetVer（已恢复下载功能）→ $dest"
    }
    else {
        $info = Get-LatestOfficialInfo
        if (-not $info) { throw "无法获取官方 PCL 最新版本（需要能访问 GitHub）" }
        $targetVer = [version]$info.Version
        Write-Log "下载模式：官方 PCL v$targetVer（commit=$($info.Commit)）"
        if ($info.Commit) { $src = Get-OfficialSource -Version $targetVer -PreferredCommit $info.Commit }
        else { $src = Get-OfficialSource -Version $targetVer }
        if (-not $src) { throw "下载官方 PCL v$targetVer 源码失败" }
        $state = Get-OfficialRestrictionState -SrcDir $src
        if ($state -eq 'Restricted') {
            if (-not (Update-OfficialSource -SrcDir $src)) { throw "无法关闭官方 PCL 的下载限制" }
        }
        $built = Invoke-OfficialBuild -SrcDir $src -Dotnet $Dotnet -MSBuild $MSBuild -RefRoot $RefRoot -Version $targetVer
        $bvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($built)
        if ([version]$bvi.FileVersion -ne $targetVer) { throw "官方 PCL 编译产物版本 v$($bvi.FileVersion) 与目标 v$targetVer 不一致" }
        if ($bvi.ProductName -ne 'Plain Craft Launcher') { throw "官方 PCL 编译产物 ProductName 异常: $($bvi.ProductName)" }
        $dest = Join-Path $InstallDir 'Plain Craft Launcher 2.exe'
        Copy-Item $built $dest -Force
        $hash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
        $refText = if ($info.Commit) { 'commit:' + $info.Commit } else { 'tag:' + [string]$targetVer }
        Save-MarkerInfo -Kind 'Official' -Version ([string]$targetVer) -Ref $refText -Sha256 $hash -Backup ''
        return "PCL 官方版 v$targetVer（已恢复下载功能）→ $dest"
    }
}
function Invoke-Main {
    if (-not (Test-Path $WorkRoot)) { New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null }
    Write-Log '================ PCLToolbox v1.0 启动 ================'

    $script:TargetDir = $ScriptDir
    if ($PclDir) {
        if (-not (Test-Path $PclDir)) { Show-ErrorMsg "指定的 PCL 目录不存在：`r`n$PclDir" }
        $script:TargetDir = (Resolve-Path $PclDir).Path
        Write-Log "指定 PCL 目录: $script:TargetDir"
    }
    $launchers = Get-Launchers
    if ($launchers.Count -eq 0 -and -not $PclDir) {
        $saved = $null
        if (Test-Path $LastPclDirFile) { try { $saved = [string](Get-Content -Raw -Path $LastPclDirFile).Trim() } catch { } }
        if ($saved -and (Test-Path $saved)) {
            $script:TargetDir = (Resolve-Path $saved).Path
            Write-Log "读取上次使用的 PCL 目录: $script:TargetDir"
            $launchers = Get-Launchers
        }
    }
    # ---------- 未检测到启动器：让用户选择“选择已有文件夹”还是“直接下载” ----------
    $downloadKinds = New-Object System.Collections.Generic.List[string]
    if ($DownloadOfficial) { $downloadKinds.Add('Official') }
    if ($DownloadCe) { $downloadKinds.Add('CE') }
    if ($launchers.Count -eq 0 -and $downloadKinds.Count -eq 0 -and -not $script:Unattended) {
        $choiceTries = 0
        while ($launchers.Count -eq 0 -and $downloadKinds.Count -eq 0 -and $choiceTries -lt 10) {
            $choiceTries++
            $choice = Show-NoLauncherChoice
            if ($choice -eq 'Browse') {
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = '选择已有 PCL 启动器所在的文件夹（包含 PCL2_CE.exe 或 Plain Craft Launcher 2.exe）'
                $dlg.ShowNewFolderButton = $false
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $script:TargetDir = $dlg.SelectedPath
                    Write-Log "用户选择 PCL 目录: $script:TargetDir"
                    $launchers = Get-Launchers
                    if ($launchers.Count -eq 0) { Show-Info "所选文件夹里没有找到 PCL 启动器（PCL2_CE.exe 或 Plain Craft Launcher 2.exe），请重新选择。" }
                } else { Write-Log '用户取消'; exit 0 }
            }
            elseif ($choice -eq 'Download') {
                $picked = @(Show-DownloadDialog)
                foreach ($k in $picked) { if ($k) { $downloadKinds.Add([string]$k) } }
                if ($downloadKinds.Count -eq 0) { Write-Log '用户取消'; exit 0 }
            }
            else { Write-Log '用户取消'; exit 0 }
        }
    }
    if ($launchers.Count -gt 0) {
        if ($script:TargetDir -ne $ScriptDir) {
            try { Set-Content -Path $LastPclDirFile -Value $script:TargetDir -Encoding UTF8 } catch { }
        }
    }
    elseif ($downloadKinds.Count -gt 0) {
        # 安装位置
        $destDir = $script:TargetDir
        if ($InstallDir) {
            if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
            $destDir = (Resolve-Path $InstallDir).Path
        } elseif (-not $script:Unattended) {
            $dlg2 = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg2.Description = '选择启动器的安装位置'
            $dlg2.SelectedPath = $ScriptDir
            $dlg2.ShowNewFolderButton = $true
            if ($dlg2.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $destDir = $dlg2.SelectedPath }
            else { Write-Log '用户取消'; exit 0 }
        }
        $script:TargetDir = $destDir
        Write-Log "下载模式安装目录: $destDir"
        # 检查编译环境：缺少官方 PCL 的 MSBuild 时，询问是否改用 PCL CE
        $needCe = $downloadKinds -contains 'CE'
        $needOfficial = $downloadKinds -contains 'Official'
        $dotnet = $null; $msbuild = $null; $refRoot = $null
        if ($needOfficial) {
            $msbuild = Find-MSBuild
            if (-not $msbuild) {
                $switchMsg = "未检测到 Visual Studio / MSBuild，无法编译官方 PCL。`r`n`r`nPCL CE 只需要 .NET SDK（工具会自动下载），不需要 Visual Studio。`r`n`r`n是否改为只下载 PCL CE（最新正式版，已恢复下载功能）？"
                $ansSwitch = Show-Msg -Text $switchMsg -Icon Question -Buttons YesNo
                if ($ansSwitch -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log '用户取消（缺少 MSBuild）'; exit 0 }
                $downloadKinds = New-Object System.Collections.Generic.List[string]
                $downloadKinds.Add('CE')
                $needOfficial = $false
                $needCe = $true
                Write-Log '缺少 MSBuild，已改为只下载 PCL CE'
            } else {
                $refRoot = Ensure-Net48Refs
                if (-not $refRoot) { Show-ErrorMsg ("下载 .NET Framework 4.8 参考程序集失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
            }
        }
        if ($needCe -or $needOfficial) {
            $dotnet = Ensure-Dotnet
            if (-not $dotnet) { Show-ErrorMsg ("准备 .NET 编译环境失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($k in $downloadKinds) {
            if ($k -eq 'CE') { $lines.Add('  · PCL CE（社区版，最新正式版）') } else { $lines.Add('  · PCL 官方版（最新正式版）') }
        }
        $extra2 = ''
        if ($downloadKinds -contains 'Official') {
            $extra2 += "`r`n`r`n注意：官方 PCL 发布版使用非公开源码构建，公开源码为「开源版」。重编译后可恢复下载功能，但联机、检查更新、公告、赞助等依赖官方服务器的功能将不可用。"
        }
        if ($downloadKinds -contains 'CE') { $extra2 += "`r`nPCL CE 为完整开源，与原版一致。" }
        $msg = "未检测到启动器，将下载并编译以下版本（均已恢复下载功能）：`r`n" + ($lines -join "`r`n") + "`r`n`r`n安装位置：$destDir`r`n`r`n下载与编译需要联网（首次可能需要 5~20 分钟）。" + $extra2 + "`r`n`r`n是否继续？"
        $ansD = Show-Msg -Text $msg -Icon Question -Buttons YesNo
        if ($ansD -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log '用户取消'; exit 0 }
        # 检查编译环境：缺少官方 PCL 的 MSBuild 时，询问是否改用 PCL CE
        $failed = New-Object System.Collections.Generic.List[string]
        $done = New-Object System.Collections.Generic.List[string]
        foreach ($kind in $downloadKinds) {
            $nm = if ($kind -eq 'CE') { 'PCL CE' } else { 'PCL 官方版' }
            Write-Log "===== 下载并编译 $nm ====="
            try {
                $done.Add((Invoke-FreshInstall -Kind $kind -InstallDir $destDir -Dotnet $dotnet -MSBuild $msbuild -RefRoot $refRoot))
            } catch {
                Write-Log ("下载 $nm 失败: " + $_.Exception.ToString()) 'ERROR'
                $failed.Add("$nm：" + $_.Exception.Message)
            }
        }
        $final2 = if ($done.Count -gt 0) { ($done -join "`r`n") } else { '没有完成任何下载。' }
        if ($failed.Count -gt 0) { $final2 += "`r`n`r`n失败：`r`n" + ($failed -join "`r`n") }
        Write-Log '下载模式处理完成'
        Show-Info ("已下载并安装：`r`n`r`n" + $final2 + "`r`n`r`n安装位置：$destDir`r`n`r`n直接运行其中的启动器即可，下载功能已恢复。")
        if ($done.Count -gt 0) { Save-LastPclDir $destDir }
        if ($failed.Count -gt 0) { exit 1 }
        exit 0
    }
    else {
        if ($script:Unattended) {
            Show-ErrorMsg "没有找到 PCL 启动器（PCL2_CE.exe 或 Plain Craft Launcher 2.exe）。`r`n`r`n可重新运行并选择「下载启动器」或「选择已有 PCL 文件夹」，或把本工具放到 PCL 所在文件夹后重试。`r`n`r`n当前查找目录：$script:TargetDir"
        } else {
            Show-Info "已取消，未做任何修改。"
            exit 0
        }
    }
    # ---------- 1. 检查最新版本 ----------
    foreach ($l in $launchers) {
        $latest = $null
        try {
            if ($l.Kind -eq 'CE') { $latest = Get-LatestCeInfo } else { $latest = Get-LatestOfficialInfo }
        } catch { Write-Log "检查最新版本失败: $($_.Exception.Message)" 'WARN' }
        $l | Add-Member -NotePropertyName Latest -NotePropertyValue $latest -Force
        $l | Add-Member -NotePropertyName TargetVersion -NotePropertyValue $l.Version -Force
        $l | Add-Member -NotePropertyName IsUpdate -NotePropertyValue $false -Force
        $l | Add-Member -NotePropertyName Label -NotePropertyValue '' -Force
        if ($latest) {
            $kindName = if ($l.Kind -eq 'CE') { 'PCL CE' } else { 'PCL 官方版' }
            Write-Log "版本检查: $kindName 当前 v$($l.Version)，最新 v$($latest.Version)"
        }
    }

    # ---------- 2. 询问是否更新到最新版 ----------
    $updatable = @($launchers | Where-Object { $_.Latest -and ($_.Latest.Version -gt $_.Version) })
    if ($updatable.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($u in $updatable) {
            $name = if ($u.Kind -eq 'CE') { 'PCL CE（社区版）' } else { 'PCL（官方版）' }
            $lines.Add("  · $name：v$($u.Version)  →  v$($u.Latest.Version)")
        }
        $msg = "检测到启动器有新版本：`r`n" + ($lines -join "`r`n") + "`r`n`r`n是否更新到最新版本并移除下载限制？`r`n（选择「否」则不更新，只处理当前版本）"
        $ans = Show-Msg -Text $msg -Icon Question -Buttons YesNo
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($u in $updatable) { $u.IsUpdate = $true; $u.TargetVersion = $u.Latest.Version }
            Write-Log '用户选择更新到最新版本'
        } else { Write-Log '用户选择不更新' }
    }

    # ---------- 3. 生成待处理列表 ----------
    $needsAction = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($l in $launchers) {
        $name = if ($l.Kind -eq 'CE') { 'PCL CE（社区版）' } else { 'PCL（官方版）' }
        Write-Log "检测到 $name v$($l.Version): $($l.Path)"
        if ($l.IsUpdate) {
            $l.TargetVersion = $l.Latest.Version
            $l.Label = "$name  v$($l.Version) → v$($l.TargetVersion)（更新并修复）"
            $needsAction.Add($l)
            continue
        }
        $m = Get-MarkerInfo -Kind $l.Kind -ExePath $l.Path
        if ($m) { $notes.Add("$name v$($l.Version)：已经是修复版，无需重复操作。"); continue }
        $limit = if ($l.Kind -eq 'CE') { $CeRestrictedSince } else { $OfficialRestrictedSince }
        if ($l.Version -lt $limit) {
            $notes.Add("$name v$($l.Version)：该版本本来就支持正常下载（限制从 v$limit 起才加入），无需修复。")
            continue
        }
        $l.TargetVersion = $l.Version
        $l.Label = "$name  v$($l.TargetVersion)（修复下载限制）"
        $needsAction.Add($l)
    }

    if ($needsAction.Count -eq 0) {
        Show-Info (($notes -join "`r`n`r`n") + "`r`n`r`n没有需要处理的项目。")
        exit 0
    }

    $selected = Select-Launchers -Items $needsAction
    if ($selected.Count -eq 0) { Write-Log '用户取消'; exit 0 }

    # ---------- 4. 确认 ----------
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($sItem in $selected) { $lines.Add("  · $($sItem.Label)") }
    $hasOfficial = @($selected | Where-Object { $_.Kind -eq 'Official' }).Count -gt 0
    $hasCe = @($selected | Where-Object { $_.Kind -eq 'CE' }).Count -gt 0
    $extra = ''
    if ($hasOfficial) {
        $extra += "`r`n`r`n注意：官方 PCL 发布版使用非公开源码构建，公开源码为「开源版」。重编译后可恢复下载功能，但联机、检查更新、公告、赞助等依赖官方服务器的功能将不可用（详见 使用说明.txt）。"
    }
    if ($hasCe) { $extra += "`r`nPCL CE 为完整开源，修复后与原版一致。" }
    $msg = "即将执行：`r`n" + ($lines -join "`r`n") + "`r`n`r`n工具会下载对应版本源码并用相同配置重新编译，首次运行需联网下载 .NET 编译环境与源码（可能需要 5~20 分钟）。" + $extra + "`r`n`r`n是否继续？"
    $ans2 = Show-Msg -Text $msg -Icon Question -Buttons YesNo
    if ($ans2 -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log '用户取消'; exit 0 }

    # ---------- 5. 准备编译环境 ----------
    $dotnet = $null; $msbuild = $null; $refRoot = $null
    if ($hasCe) {
        $dotnet = Ensure-Dotnet
        if (-not $dotnet) { Show-ErrorMsg ("准备 .NET 编译环境失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
    }
    if ($hasOfficial) {
        $msbuild = Find-MSBuild
        if (-not $msbuild) {
            $ceNeed = @($launchers | Where-Object { $_.Kind -eq 'CE' -and $_.Version -ge $CeRestrictedSince -and -not (Get-MarkerInfo -Kind 'CE' -ExePath $_.Path) })
            $ceAny = @($launchers | Where-Object { $_.Kind -eq 'CE' })
            if ($ceNeed.Count -gt 0) {
                $switchMsg = "未检测到 Visual Studio / MSBuild，无法编译官方 PCL。`r`n`r`n检测到本目录有 PCL CE（PCL CE 只需 .NET SDK，不需要 Visual Studio），是否改为修复 PCL CE？"
                $ansSwitch = Show-Msg -Text $switchMsg -Icon Question -Buttons YesNo
                if ($ansSwitch -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log '用户取消（缺少 MSBuild）'; exit 0 }
                $selected = @($ceNeed)
                foreach ($x in $selected) { $x.TargetVersion = $x.Version; $x.Label = "PCL CE  v$($x.Version)（修复下载限制）" }
                $hasOfficial = $false
                $hasCe = $true
                Write-Log '缺少 MSBuild，已改为只处理 PCL CE'
            } elseif ($ceAny.Count -gt 0) {
                Show-Info "未检测到 Visual Studio / MSBuild，无法编译官方 PCL。`r`n`r`n本目录的 PCL CE 已经是修复版，无需处理。"
                exit 0
            } else {
                $switchMsg = "未检测到 Visual Studio / MSBuild，无法编译官方 PCL。`r`n`r`n是否改为下载并安装 PCL CE（最新正式版，已恢复下载功能）？"
                $ansSwitch = Show-Msg -Text $switchMsg -Icon Question -Buttons YesNo
                if ($ansSwitch -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log '用户取消（缺少 MSBuild）'; exit 0 }
                Write-Log '缺少 MSBuild，改为下载安装 PCL CE'
                $dotnet = Ensure-Dotnet
                if (-not $dotnet) { Show-ErrorMsg ("准备 .NET 编译环境失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
                try {
                    $res = Invoke-FreshInstall -Kind 'CE' -InstallDir $script:TargetDir -Dotnet $dotnet -MSBuild '' -RefRoot ''
                    Save-LastPclDir $script:TargetDir
                    Show-Info ("已下载并安装：`r`n`r`n" + $res + "`r`n`r`n安装位置：$script:TargetDir")
                } catch {
                    Show-ErrorMsg ("下载 PCL CE 失败：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n日志：$LogFile")
                }
                exit 0
            }
        }
        if ($hasCe -and -not $dotnet) {
            $dotnet = Ensure-Dotnet
            if (-not $dotnet) { Show-ErrorMsg ("准备 .NET 编译环境失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
        }
        if ($hasOfficial) {
            if (-not $dotnet) {
                $dotnet = Ensure-Dotnet
                if (-not $dotnet) { Show-ErrorMsg ("准备 .NET 编译环境失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
            }
            $refRoot = Ensure-Net48Refs
            if (-not $refRoot) { Show-ErrorMsg ("下载 .NET Framework 4.8 参考程序集失败。`r`n`r`n请检查网络连接后重试。`r`n日志：$LogFile") }
        }
    }
    # ---------- 6. 逐项处理 ----------
    $success = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($l in $selected) {
        $name = if ($l.Kind -eq 'CE') { 'PCL CE' } else { 'PCL 官方版' }
        $targetVer = [version]$l.TargetVersion
        $oldVer = [version]$l.Version
        Write-Log "===== 开始处理 $name：v$oldVer -> v$targetVer（更新：$($l.IsUpdate)） ====="
        try {
            if ($l.Kind -eq 'CE') {
                if ($l.IsUpdate) { $ref = @{ Kind = 'tag'; Value = [string]$l.Latest.Tag } }
                else { $ref = Get-CeRef -Launcher $l }
                Write-Log "CE 源码引用: $($ref.Kind) = $($ref.Value)"
                $src = Get-CeSource -Ref $ref
                if (-not $src) { throw "下载 PCL CE v$targetVer 源码失败（需要能访问 GitHub）" }
                if (-not (Test-CeSourceHasRestriction $src)) {
                    $notes.Add("PCL CE v$targetVer：该版本源码中没有下载鉴权逻辑，本来就支持下载，无需修复。")
                    continue
                }
                if (-not (Update-CeSource -SrcDir $src)) { throw "无法定位并移除 CE 下载鉴权代码" }
                $secrets = Get-CeEmbeddedSecrets -ExePath $l.Path
                $commitSha = $null
                if ($ref.Kind -eq 'sha') { $commitSha = $ref.Value }
                if (-not $commitSha -and $secrets['GITHUB_SHA'] -match '^[0-9a-fA-F]{40}$') { $commitSha = $secrets['GITHUB_SHA'] }
                $artifact = Join-Path $WorkRoot ('artifact-ce-' + $ref.Value)
                $built = Invoke-CePublish -Dotnet $dotnet -SrcDir $src -Secrets $secrets -CommitSha $commitSha -OutputDir $artifact
                $bvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($built)
                if ([version]$bvi.FileVersion -ne $targetVer) { throw "CE 编译产物版本 v$($bvi.FileVersion) 与目标 v$targetVer 不一致" }
                if ($bvi.ProductName -notlike '*Community Edition*') { throw "CE 编译产物 ProductName 异常: $($bvi.ProductName)" }
                $missingSecrets = @(Test-BuiltSecrets -ExePath $built -Secrets $secrets)
                if ($missingSecrets.Count -gt 0) { throw ("CE 编译产物缺少内置密钥: " + ($missingSecrets -join ', ')) }
                $backup = Backup-And-Replace -ExePath $l.Path -BuiltExe $built -Kind 'CE' -Version $oldVer
                $hash = (Get-FileHash -Path $l.Path -Algorithm SHA256).Hash
                Save-MarkerInfo -Kind 'CE' -Version ([string]$targetVer) -Ref $ref.Value -Sha256 $hash -Backup $backup
                if ($l.IsUpdate) { $success.Add("PCL CE v$oldVer → v$targetVer（已更新并修复）") }
                else { $success.Add("PCL CE v$targetVer") }
            }
            else {
                if ($l.IsUpdate -and $l.Latest.Commit) { $src = Get-OfficialSource -Version $targetVer -PreferredCommit $l.Latest.Commit }
                else { $src = Get-OfficialSource -Version $targetVer }
                if (-not $src) { throw "下载 PCL 官方版 v$targetVer 源码失败（需要能访问 GitHub）" }
                $state = Get-OfficialRestrictionState -SrcDir $src
                if ($state -eq 'Absent') {
                    $notes.Add("PCL 官方版 v$targetVer：该版本源码中没有下载限制逻辑，本来就支持下载，无需修复。")
                    continue
                }
                if ($state -eq 'Restricted') {
                    if (-not (Update-OfficialSource -SrcDir $src)) { throw "无法关闭官方 PCL 的下载限制" }
                }
                $built = Invoke-OfficialBuild -SrcDir $src -Dotnet $dotnet -MSBuild $msbuild -RefRoot $refRoot -Version $targetVer
                $bvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($built)
                if ([version]$bvi.FileVersion -ne $targetVer) { throw "官方 PCL 编译产物版本 v$($bvi.FileVersion) 与目标 v$targetVer 不一致" }
                if ($bvi.ProductName -ne $l.ProductName) { throw "官方 PCL 编译产物 ProductName 异常: $($bvi.ProductName)" }
                $bytes = [System.IO.File]::ReadAllBytes($built)
                $text = [System.Text.Encoding]::Unicode.GetString($bytes)
                if ($text.IndexOf('关闭下载', [System.StringComparison]::Ordinal) -ge 0) { throw "编译产物中仍包含下载限制逻辑" }
                $backup = Backup-And-Replace -ExePath $l.Path -BuiltExe $built -Kind 'Official' -Version $oldVer
                $hash = (Get-FileHash -Path $l.Path -Algorithm SHA256).Hash
                $refText = if ($l.IsUpdate -and $l.Latest.Commit) { 'commit:' + $l.Latest.Commit } else { 'tag:' + [string]$targetVer }
                Save-MarkerInfo -Kind 'Official' -Version ([string]$targetVer) -Ref $refText -Sha256 $hash -Backup $backup
                if ($l.IsUpdate) { $success.Add("PCL 官方版 v$oldVer → v$targetVer（已更新并修复）") }
                else { $success.Add("PCL 官方版 v$targetVer") }
            }
        } catch {
            Write-Log ("处理 $name 失败: " + $_.Exception.ToString()) 'ERROR'
            $failed.Add($name + '：' + $_.Exception.Message)
        }
    }

    $final = New-Object System.Collections.Generic.List[string]
    foreach ($s in $success) { $final.Add("已处理：$s") }
    foreach ($n in $notes) { $final.Add($n) }
    foreach ($f in $failed) { $final.Add("失败：$f") }
    if ($final.Count -eq 0) { $final.Add('没有完成任何修改。') }
    Write-Log '全部处理完成'
    Show-Info (($final -join "`r`n") + "`r`n`r`n原程序均已备份为「<原名>.原版备份.<旧版本号>.exe」，需要还原时改回原名即可。")
    if ($failed.Count -gt 0) { exit 1 }
}
try { Invoke-Main } catch {
    Write-Log ("未处理的异常: " + $_.Exception.ToString() + "`n脚本位置: " + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace) 'ERROR'
    Show-ErrorMsg ("工具运行出错：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n日志：$LogFile")
}
