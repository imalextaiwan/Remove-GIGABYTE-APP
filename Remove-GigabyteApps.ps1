<#
.SYNOPSIS
  一鍵移除 Windows 上所有 GIGABYTE(技嘉)安裝的軟體。

.DESCRIPTION
  依序:建立還原點 → 移除排程工作 → 停止服務 → 結束程序 → 移除 Store App
  → 靜默執行每個解除安裝程式 → 清除殘留服務 / 開機啟動 / 資料夾 / 捷徑 / 登錄。
  不會移除任何驅動程式。

.PARAMETER DryRun
  只列出會被移除的項目,不做任何變更(不需系統管理員權限)。

.PARAMETER PurgeUserData
  一併刪除使用者設定資料夾(%APPDATA% / %LOCALAPPDATA% 下的 GIGABYTE、GiMATE)。

.PARAMETER NoRestorePoint
  不建立系統還原點。
#>
param(
    [switch]$DryRun,
    [switch]$PurgeUserData,
    [switch]$NoRestorePoint
)

$NamePattern = 'GIGA-?BYTE|AORUS|GiMATE'
$PathPattern = '\\GIGABYTE\\|\\GiMATE'

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DryRun -and -not $IsAdmin) {
    Write-Host '需要系統管理員權限。請改用 Remove-GIGABYTE.bat 執行(會跳出 UAC 視窗)。' -ForegroundColor Red
    exit 1
}

if (-not $DryRun) {
    $LogFile = Join-Path $PSScriptRoot ('Remove-GIGABYTE_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    Start-Transcript -Path $LogFile | Out-Null
}

$script:Failed = @()
$script:RanUninstallers = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# 解除安裝程式即使加了 /S 仍可能跳出「Will uninstall / Uninstall Success」等確認視窗,
# 由這段自動按「是 / 確定」;若視窗內容提到重新開機則按「否 / 取消」,避免電腦被重開。
$DialogPathPattern = "$PathPattern|\\~nsu|\\Un_[A-Z]\.exe$|\\Au_\.exe$"
$RebootPattern = 'restart|reboot|重新啟動|重新開機|重開機|重启'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public static class GbtDialogClicker {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder s, ref int size);

    static string ProcessPath(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return "";
        try {
            var sb = new StringBuilder(1024); int n = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : "";
        } finally { CloseHandle(h); }
    }

    static string Text(IntPtr h) { var sb = new StringBuilder(1024); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }

    // 找出屬於解除安裝程式的對話框 (#32770) 並按下按鈕;回傳處理過的視窗說明
    public static string[] ClickAll(string pathPattern, int extraPid, string avoidPattern, bool click) {
        var result = new List<string>();
        var rxPath = new Regex(pathPattern, RegexOptions.IgnoreCase);
        var rxAvoid = new Regex(avoidPattern, RegexOptions.IgnoreCase);
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var cls = new StringBuilder(64); GetClassName(h, cls, 64);
            if (cls.ToString() != "#32770") return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != extraPid && !rxPath.IsMatch(ProcessPath(pid))) return true;
            var all = new StringBuilder();
            EnumChildWindows(h, (c, l2) => { all.Append(' ').Append(Text(c)); return true; }, IntPtr.Zero);
            string body = all.ToString().Trim();
            // 6=是 1=確定 2=取消/確定 7=否
            int[] order = rxAvoid.IsMatch(Text(h) + " " + body) ? new[] { 7, 2, 1 } : new[] { 6, 1, 2 };
            foreach (int id in order) {
                IntPtr btn = GetDlgItem(h, id);
                if (btn != IntPtr.Zero && IsWindowVisible(btn) && IsWindowEnabled(btn)) {
                    if (click) PostMessage(h, 0x0111 /* WM_COMMAND */, (IntPtr)id, btn);
                    result.Add("[" + Text(h) + "] " + body + " -> " + Text(btn));
                    break;
                }
            }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@

function Invoke-DialogClicker([int]$ProcessId = 0) {
    foreach ($c in [GbtDialogClicker]::ClickAll($DialogPathPattern, $ProcessId, $RebootPattern, $true)) {
        Write-Host "     自動點選:$c" -ForegroundColor DarkGray
    }
}

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Invoke-Action([string]$Description, [scriptblock]$Action) {
    if ($DryRun) { Write-Host "  [預覽] $Description" -ForegroundColor Yellow; return }
    Write-Host "  -> $Description"
    try { & $Action }
    catch {
        Write-Host "     失敗:$($_.Exception.Message)" -ForegroundColor Red
        $script:Failed += $Description
    }
}

# ---------- 偵測 ----------

$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-GigabyteUninstallEntries {
    Get-ItemProperty $UninstallKeys -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -and (
            ($_.Publisher -match $NamePattern) -or
            ($_.DisplayName -match $NamePattern) -or
            ("$($_.UninstallString)" -match $PathPattern))
    }
}

function Get-GigabyteServices {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match $PathPattern -or $_.DisplayName -match $NamePattern }
}

function Get-GigabyteTasks {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -match $NamePattern -or $_.TaskName -match $NamePattern -or
        ((@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match $PathPattern
    }
}

function Get-GigabyteAppx {
    $all = if ($IsAdmin) { Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue } else { Get-AppxPackage -ErrorAction SilentlyContinue }
    $all | Where-Object { $_.Name -match $NamePattern -or $_.Publisher -match $NamePattern }
}

function Get-GigabyteProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -match $PathPattern }
}

# ---------- 工具 ----------

function Split-CommandLine([string]$CommandLine) {
    $CommandLine = $CommandLine.Trim()
    if ($CommandLine.StartsWith('"')) {
        $end = $CommandLine.IndexOf('"', 1)
        return @($CommandLine.Substring(1, $end - 1), $CommandLine.Substring($end + 1).Trim())
    }
    $i = $CommandLine.ToLower().IndexOf('.exe')
    if ($i -lt 0) { return @($CommandLine, '') }
    return @($CommandLine.Substring(0, $i + 4), $CommandLine.Substring($i + 4).Trim())
}

function Test-NsisUninstaller([string]$Exe) {
    try { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Exe)) -match 'Nullsoft' } catch { $false }
}

function Invoke-Uninstaller([string]$Exe, [string]$Arguments) {
    if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到解除安裝程式:$Exe" }
    [void]$script:RanUninstallers.Add($Exe)
    if (Test-NsisUninstaller $Exe) {
        if ($Arguments -notmatch '(^|\s)/S(\s|$)') { $Arguments = "$Arguments /S".Trim() }
        # _?= 讓 NSIS 在原地執行並等它跑完(否則它會複製到 TEMP 後立刻返回)
        $Arguments = "$Arguments _?=$(Split-Path -Parent $Exe)".Trim()
    }
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru
    $null = $p.Handle
    $deadline = (Get-Date).AddMinutes(10)
    while (-not $p.HasExited) {
        Invoke-DialogClicker $p.Id
        if ((Get-Date) -gt $deadline) { $p.Kill(); throw '逾時 10 分鐘,已強制結束' }
        Start-Sleep -Milliseconds 300
    }
    # 主程式結束後,它啟動的子程序可能還會跳視窗
    for ($i = 0; $i -lt 6; $i++) { Invoke-DialogClicker; Start-Sleep -Milliseconds 300 }
    if ($p.ExitCode -notin 0, 1605, 3010) { throw "結束代碼 $($p.ExitCode)" }
}

function Get-UninstallPriority($Entry) {
    $u = "$($Entry.UninstallString)"
    if ($u -match '\\Control Center\\Lib\\') { 0 }        # 子元件先移除
    elseif ($u -match '\\Control Center\\uninst\.exe') { 2 }  # 主程式最後
    else { 1 }
}

function Stop-GigabyteProcesses {
    foreach ($p in Get-GigabyteProcesses) {
        Invoke-Action "結束程序 $($p.Name) ($($p.Path))" { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
    }
}

function Remove-GigabyteTasks {
    foreach ($t in Get-GigabyteTasks) {
        Invoke-Action "刪除排程工作 $($t.TaskPath)$($t.TaskName)" {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        }
    }
}

# ================= 開始 =================

if ($DryRun) {
    Write-Host '【預覽模式】只列出項目,不會做任何變更。' -ForegroundColor Yellow
}
else {
    Write-Host '開始移除所有 GIGABYTE 軟體…' -ForegroundColor Green
}

if (-not $DryRun -and -not $NoRestorePoint) {
    Write-Step '建立系統還原點'
    try {
        Checkpoint-Computer -Description 'Before removing GIGABYTE software' -RestorePointType APPLICATION_UNINSTALL -ErrorAction Stop
        Write-Host '  已建立還原點'
    }
    catch { Write-Host "  略過(系統保護可能未開啟):$($_.Exception.Message)" -ForegroundColor DarkYellow }
}

Write-Step '1. 移除排程工作(避免程式被重新啟動)'
Remove-GigabyteTasks

Write-Step '2. 停止並停用服務'
foreach ($s in Get-GigabyteServices) {
    Invoke-Action "停止服務 $($s.Name) [$($s.DisplayName)]" {
        if ($s.State -ne 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction Stop }
        Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop
    }
}

Write-Step '3. 結束執行中的程序'
Stop-GigabyteProcesses

Write-Step '4. 移除 Microsoft Store App'
foreach ($a in Get-GigabyteAppx) {
    Invoke-Action "移除 App $($a.Name) ($($a.PackageFullName))" {
        if ($IsAdmin) { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop }
        else { Remove-AppxPackage -Package $a.PackageFullName -ErrorAction Stop }
    }
}
if ($IsAdmin) {
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $NamePattern } |
        ForEach-Object {
            $pp = $_
            Invoke-Action "移除預載 App $($pp.DisplayName)" { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null }
        }
}

Write-Step '5. 執行解除安裝程式(靜默)'
$entries = @(Get-GigabyteUninstallEntries | Sort-Object @{ Expression = { Get-UninstallPriority $_ } }, DisplayName)
if ($entries.Count -eq 0) { Write-Host '  (沒有找到已安裝的 GIGABYTE 程式)' }
foreach ($e in $entries) {
    if (-not $DryRun -and -not (Test-Path -LiteralPath $e.PSPath)) {
        Write-Host "  略過 $($e.DisplayName)(已被其他解除安裝程式一併移除)"
        continue
    }
    $u = "$($e.UninstallString)"
    if ($u -match 'GiMATE_ai\\uninstall\.bat') {
        # 官方 bat 會跳出確認視窗,這裡直接做它做的事
        Invoke-Action "解除安裝 $($e.DisplayName)" {
            Get-Process GiMATE_ai, GiMATE_llm, GiMATE_heartbeat -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            $dir = Join-Path $env:ProgramFiles 'GIGABYTE\GiMATE_ai'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
            Remove-Item -LiteralPath $e.PSPath -Recurse -Force -ErrorAction Stop
        }
    }
    elseif ($u -match 'msiexec' -and $e.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        Invoke-Action "解除安裝 $($e.DisplayName) (MSI)" {
            Invoke-Uninstaller "$env:SystemRoot\System32\msiexec.exe" "/x $($e.PSChildName) /qn /norestart"
        }
    }
    else {
        $cmd = if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $u }
        $exe, $args_ = Split-CommandLine $cmd
        Invoke-Action "解除安裝 $($e.DisplayName)  <$exe>" { Invoke-Uninstaller $exe $args_ }
    }
}

Write-Step '6. 執行資料夾內其餘的解除安裝程式'
$InstallRoots = @("$env:ProgramFiles\GIGABYTE", "${env:ProgramFiles(x86)}\GIGABYTE") | Where-Object { Test-Path -LiteralPath $_ }
$leftUninst = @()
if ($InstallRoots) {
    $leftUninst = @(Get-ChildItem -Path $InstallRoots -Recurse -File -Include 'uninst*.exe', 'Uninstall *.exe' -ErrorAction SilentlyContinue |
        Where-Object { -not $script:RanUninstallers.Contains($_.FullName) -and (Test-NsisUninstaller $_.FullName) } |
        Sort-Object { $_.FullName.Length } -Descending)
}
if ($DryRun) {
    # 預覽時只列出「不在已安裝清單中」的
    $known = @($entries | ForEach-Object { (Split-CommandLine "$($_.UninstallString)")[0] })
    $leftUninst = @($leftUninst | Where-Object { $known -notcontains $_.FullName })
}
if ($leftUninst.Count -eq 0) { Write-Host '  (無)' }
foreach ($f in $leftUninst) {
    Invoke-Action "解除安裝 $($f.Directory.Name)  <$($f.FullName)>" { Invoke-Uninstaller $f.FullName '/S' }
}

Write-Step '7. 清除殘留的程序 / 服務 / 排程 / 開機啟動'
Stop-GigabyteProcesses
foreach ($s in Get-GigabyteServices) {
    Invoke-Action "刪除殘留服務 $($s.Name)" {
        if ($s.State -ne 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
        $out = & sc.exe delete $s.Name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "$out" }
    }
}
if (-not $DryRun) { Remove-GigabyteTasks }
$RunKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($k in $RunKeys) {
    if (-not (Test-Path $k)) { continue }
    (Get-ItemProperty $k).PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' -and "$($_.Value)" -match $PathPattern } |
        ForEach-Object {
            $name = $_.Name
            Invoke-Action "刪除開機啟動項目 $name" { Remove-ItemProperty -Path $k -Name $name -ErrorAction Stop }
        }
}

Write-Step '8. 刪除殘留資料夾與捷徑'
$leftovers = @(
    "$env:ProgramFiles\GIGABYTE",
    "${env:ProgramFiles(x86)}\GIGABYTE",
    "$env:ProgramData\GIGABYTE",
    "$env:ProgramData\GiMATE_ai"
) | Where-Object { Test-Path -LiteralPath $_ }
$startMenus = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
$desktops = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'))
$leftovers += @(Get-ChildItem -Path $startMenus -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $NamePattern } | ForEach-Object FullName)
$leftovers += @(Get-ChildItem -Path $desktops -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $NamePattern } | ForEach-Object FullName)

$userData = @(Get-ChildItem -Path $env:APPDATA, $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $NamePattern } | ForEach-Object FullName)
if ($PurgeUserData) { $leftovers += $userData }

if ($leftovers.Count -eq 0) { Write-Host '  (無)' }
foreach ($path in $leftovers) {
    Invoke-Action "刪除 $path" {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    }
}
if (-not $PurgeUserData -and $userData.Count -gt 0) {
    Write-Host '  保留使用者設定資料(加 -PurgeUserData 才會刪除):' -ForegroundColor DarkGray
    $userData | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

Write-Step '9. 清除失效的「已安裝的應用程式」項目'
$orphans = @(Get-GigabyteUninstallEntries | Where-Object {
        $exe = (Split-CommandLine "$($_.UninstallString)")[0]
        $exe -match $PathPattern -and -not (Test-Path -LiteralPath $exe)
    })
if ($DryRun) { Write-Host '  (實際執行後才會判斷)' }
elseif ($orphans.Count -eq 0) { Write-Host '  (無)' }
foreach ($o in $orphans) {
    Invoke-Action "刪除登錄項目 $($o.DisplayName)" { Remove-Item -LiteralPath $o.PSPath -Recurse -Force -ErrorAction Stop }
}

# ================= 結果 =================

Write-Step '結果'
if ($DryRun) {
    Write-Host '以上為預覽。實際移除請雙擊 Remove-GIGABYTE.bat。' -ForegroundColor Yellow
    exit 0
}

$remainApps = @(Get-GigabyteUninstallEntries)
$remainAppx = @(Get-GigabyteAppx)
$remainSvc = @(Get-GigabyteServices)
$remainDirs = @("$env:ProgramFiles\GIGABYTE", "${env:ProgramFiles(x86)}\GIGABYTE") | Where-Object { Test-Path -LiteralPath $_ }

if ($remainApps.Count + $remainAppx.Count + $remainSvc.Count + @($remainDirs).Count -eq 0 -and $script:Failed.Count -eq 0) {
    Write-Host '所有 GIGABYTE 軟體都已移除。建議重新開機。' -ForegroundColor Green
}
else {
    Write-Host '部分項目未能移除(通常是檔案使用中)。請重新開機後再執行一次 Remove-GIGABYTE.bat:' -ForegroundColor Yellow
    $remainApps | ForEach-Object { Write-Host "  程式:$($_.DisplayName)" }
    $remainAppx | ForEach-Object { Write-Host "  App:$($_.Name)" }
    $remainSvc | ForEach-Object { Write-Host "  服務:$($_.Name)" }
    $remainDirs | ForEach-Object { Write-Host "  資料夾:$_" }
    $script:Failed | ForEach-Object { Write-Host "  失敗:$_" -ForegroundColor Red }
}
Write-Host "`n記錄檔:$LogFile"
Stop-Transcript | Out-Null
