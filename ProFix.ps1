# Copyright (c) 2026 Syed Osman (PRO SUPPORT). All rights reserved. Licensed under the MIT License.
<#
.SYNOPSIS
    ProFix v1.0.0 - Slow PC Doctor for Windows 10 / 11 (GUI)
.DESCRIPTION
    Diagnose why a PC is slow, show a Health Score 0-100, then fix
    only the safe things you tick. Diagnose first, preview everything,
    then fix only what you choose.

    7 diagnostics:
      1. Junk files - Temp (%TEMP%, C:\Windows\Temp, 24h skip),
         Browser caches (Chrome/Edge/Firefox/Opera, all profiles),
         Old Logs 7+ days, Shader cache 7+ days, Error Reports 7+ days.
         Reuses ProClean v1.1.0 collection logic exactly.
      2. C: drive free space - % free and GB free.
      3. Startup apps - Win32_StartupCommand + HKCU/HKLM Run keys
         + Startup folder. Count + full command per app.
      4. Memory pressure - total RAM, free RAM, % used.
      5. CPU load + Uptime - CPU %, days since last restart.
      6. Windows Update / Pending reboot - RebootPending registry keys
         + wuauserv status. Report only, never forces an update.
      7. Recycle Bin size + DNS - bin count/size, DNS flush as a fix.

    Health Score - 75/25 Split Architecture (SCORE_SPEC_75_25.md):
      System Health /75: C: free space 20, RAM pressure (3-sec avg) 15,
      Startup (non-Microsoft) 12, CPU (5-sec avg) + Uptime 10, Junk 8,
      Windows Update / Pending Restart 6, Recycle Bin + DNS 4.
      Hardware Health /25 (read-only WMI/CIM): OS drive type 12
      (NVMe/SSD 12, Unknown 7, HDD 0), Total RAM 8 (16GB+ 8, 8-15GB 5,
      <8GB 0), SMART + CPU/Battery 5.
      Hard caps AFTER the total: SMART failing -> min(score, 39);
      C: drive under 2 GB free -> min(score, 44).
      Grade: 85+ Excellent, 65-84 Good, 45-64 Fair, 0-44 Poor.
      CPU/RAM are sampled over 3-5 sec (never a 1-sec snapshot).
      Non-admin fallback: drive Unknown 7 pts, SMART Unchecked 5 pts.

    Safe fixes only:
      - Clean junk (only scanned files, 24h rule, locked files skipped)
      - Disable selected startup apps - ONLY HKCU Run entries in v1.
        The value is moved to HKCU\Software\ProFix\DisabledStartup\<name>
        and written in full to the log, so it is reversible.
        HKLM Run and Startup-folder items are Info only in v1.
      - Empty Recycle Bin (own confirmation) + Flush DNS
      - C: drive full, CPU high, RAM high, pending reboot, long uptime:
        NO automatic fix - a plain-English recommendation is shown.
        Never kills processes, never changes power plans, never touches
        the registry except the HKCU Run disable above, never deletes
        all Prefetch, never auto-restarts the PC.
      - Optional System Restore Point before fixing (admin only).

    Every run writes a log file to your Desktop.
    Every Fix also writes ProFix_Restore.json (see below) and a
    Before vs After Health Report (ProFix-Report-*.txt on the Desktop).

    Undo / restore (v1.0):
      - Every Fix writes %LOCALAPPDATA%\ProFix\ProFix_Restore.json with
        the Health Score before fixing and every reversible change.
        In v1.0 the only reversible changes are HKCU Run startup
        disables: each entry has the full original command value.
        Junk files deleted, Recycle Bin emptied and DNS flushed are
        recorded as NOT restorable.
      - The GUI has an "Undo Last Fix" button. It restores the startup
        apps from the JSON, deletes their backup entries, then renames
        the JSON to ProFix_Restore-UNDONE-<timestamp>.json so Undo
        cannot run twice on the same backup.
      - After every Fix, ProFix re-runs Diagnose silently and writes a
        Before vs After report (score before -> after, space freed,
        startup apps disabled, recommendations still open).

.NOTES
    Author  : PRO SUPPORT (Syed Osman)
    Version : 1.0.0 - 19 Nov 2026
    License : MIT - free to use, share and modify
    Needs   : Windows 10 / 11, Windows PowerShell 5.1 (built in)
              Admin rights for the System Restore Point.
              Without admin, the restore point is disabled, the rest works.

    HOW TO RUN:
      1. Double-click Run-ProFix.bat (same folder), or
         right-click ProFix.ps1 -> "Run with PowerShell".
      2. Press Diagnose, review the Health Score and the list,
         tick the issues to fix, press Fix Selected.
      Double-click a row to see details (Junk: largest files;
      Startup: pick which HKCU apps to disable; others: explanation).
      "Undo Last Fix" restores the startup apps disabled by the last
      fix (from ProFix_Restore.json). Deleted junk cannot be undone.
      Console scan only:  ProFix.ps1 -DiagnoseOnly
      Silent safe fix:    ProFix.ps1 -AutoFix
#>

param(
    [switch]$DiagnoseOnly,  # Console-only diagnose, no GUI, deletes nothing
    [switch]$AutoFix        # Silent diagnose + fix of default safe items only, no GUI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.0.0'

# ---------------------------------------------------------------------------
# The 7 diagnostics - DATA, not hardcoded logic.
#   DefaultFix: ticked for fixing after a Diagnose (GUI + AutoFix defaults
#   are defined separately below - AutoFix uses only Junk + DNS).
# ---------------------------------------------------------------------------
$script:Diagnostics = @(
    [pscustomobject]@{ Id='Junk';        Name='Junk Files';              Desc='Temp + browser caches + old logs / shader / error reports'; DefaultFix=$true }
    [pscustomobject]@{ Id='DriveC';      Name='C: Drive Free Space';     Desc='How full the system drive is';                              DefaultFix=$false }
    [pscustomobject]@{ Id='Startup';     Name='Startup Apps';            Desc='Apps that launch at Windows startup';                       DefaultFix=$false }
    [pscustomobject]@{ Id='Memory';      Name='Memory (RAM) Pressure';   Desc='Total RAM, free RAM, % used';                               DefaultFix=$false }
    [pscustomobject]@{ Id='CpuUptime';   Name='CPU Load + Uptime';       Desc='CPU load and days since last restart';                      DefaultFix=$false }
    [pscustomobject]@{ Id='UpdateReboot';Name='Windows Update / Reboot'; Desc='Pending reboot + Windows Update service status';            DefaultFix=$false }
    [pscustomobject]@{ Id='RecycleDns';  Name='Recycle Bin + DNS';       Desc='Recycle Bin size + DNS cache';                              DefaultFix=$false }
    [pscustomobject]@{ Id='HwDrive';     Name='Hardware: OS Drive';      Desc='HDD vs SSD/NVMe boot drive (read-only)';                   DefaultFix=$false }
    [pscustomobject]@{ Id='HwRam';       Name='Hardware: Total RAM';      Desc='Total physical RAM installed (read-only)';                 DefaultFix=$false }
    [pscustomobject]@{ Id='HwHealth';    Name='Hardware: Disk + CPU';     Desc='SMART disk health + CPU threads + battery (read-only)';     DefaultFix=$false }
)

$script:LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("ProFix-Log-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:Diagnosis = $null    # @{ Score; Grade; Verdict; Items = @{ Id -> item } }
$script:JunkFiles = @()      # scanned junk files (preview only until Fix)
$script:StartupApps = @()    # @{ Name; Command; Location; Source } ; Source = HKCU Run | HKLM Run | Startup Folder | WMI
$script:StartupDisable = @{} # Name -> $true/$false, chosen in the Startup detail dialog
$script:Populating = $false  # suppresses the stale-preview guard while the list is filled
$script:RestoreJsonDir = Join-Path $env:LOCALAPPDATA 'ProFix'
$script:RestoreJsonPath = Join-Path $script:RestoreJsonDir 'ProFix_Restore.json'
$script:btnUndo = $null
$script:txtLog = $null
$script:progressBar = $null
$script:listView = $null
$script:lblStatus = $null
$script:lblScore = $null
$script:lblSystemHealth = $null
$script:lblHardwareHealth = $null
$script:barSystem = $null
$script:barHardware = $null

# ---------------------------------------------------------------------------
# Helpers (Format-Size, log, browser paths, file collection - ProClean logic)
# ---------------------------------------------------------------------------
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return '{0} bytes' -f $Bytes
}

function Write-ProFixLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($script:txtLog) {
        $script:txtLog.AppendText("$line`r`n")
        $script:txtLog.SelectionStart = $script:txtLog.Text.Length
        $script:txtLog.ScrollToCaret()
    }
}

function Get-BrowserCachePaths {
    $paths = @()
    foreach ($base in @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
    )) {
        if (-not (Test-Path $base)) { continue }
        $profiles = @('Default', 'Guest Profile') + @(Get-ChildItem -Path $base -Directory -Filter 'Profile *' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        foreach ($profile in $profiles) {
            foreach ($sub in @('Cache', 'Cache\Cache_Data', 'Code Cache', 'GPUCache')) {
                $paths += (Join-Path (Join-Path $base $profile) $sub)
            }
        }
    }
    $opera = Join-Path $env:APPDATA 'Opera Software\Opera Stable\Cache'
    if (Test-Path $opera) { $paths += $opera }
    $ffProfiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $ffProfiles) {
        Get-ChildItem -Path $ffProfiles -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $paths += (Join-Path $_.FullName 'cache2')
        }
    }
    return $paths
}

function Get-BrowserRunning {
    $names = @('chrome', 'msedge', 'firefox', 'opera')
    foreach ($n in $names) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Get-FilesInPaths {
    param([string[]]$Paths, [int]$MinAgeHours)
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $files = @()
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        try {
            $found = Get-ChildItem -LiteralPath $p -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -and
                    ($MinAgeHours -le 0 -or $_.LastWriteTime -lt $cutoff)
                }
            if ($found) { $files += @($found) }
        } catch { }
    }
    return $files
}

function Get-RecycleBinInfo {
    try {
        $shell = New-Object -ComObject Shell.Application
        $items = $shell.NameSpace(0xA).Items()
        $count = 0; $size = 0
        foreach ($item in $items) { $count++; $size += [long]$item.Size }
        return @{ Count = $count; SizeBytes = $size }
    } catch {
        return @{ Count = 0; SizeBytes = 0 }
    }
}

function New-ProFixRestorePoint {
    if (-not $script:IsAdmin) { Write-ProFixLog 'Restore point skipped: not running as admin.'; return $false }
    try {
        Write-ProFixLog 'Creating a System Restore Point (can take ~30 seconds)...'
        Checkpoint-Computer -Description 'ProFix before fixing' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-ProFixLog 'Restore Point created.'
        return $true
    } catch {
        Write-ProFixLog ('Restore Point could not be created (Windows allows one per day, or restore is off): ' + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------------------
# Restore JSON + Undo + Before/After report (Safe by Design)
#   ProFix_Restore.json lives in %LOCALAPPDATA%\ProFix\.
#   In v1.0 the ONLY restorable changes are HKCU Run startup disables.
#   Junk deleted / Recycle Bin emptied / DNS flushed are recorded as
#   NOT restorable - the JSON says so, and Undo says so on screen.
# ---------------------------------------------------------------------------
function Write-ProFixRestoreJson {
    param([int]$ScoreBefore, [string]$GradeBefore, [hashtable]$FixResult, [int]$SoftwareBefore = 0, [int]$HardwareBefore = 0)
    try {
        if (-not (Test-Path $script:RestoreJsonDir)) { New-Item -Path $script:RestoreJsonDir -ItemType Directory -Force | Out-Null }
        $disabledEntries = @()
        foreach ($e in @($FixResult.DisabledApps)) {
            $disabledEntries += [pscustomobject]@{
                Name = [string]$e.Name
                OriginalLocation = 'HKCU Run'
                Value = [string]$e.Value
                BackupRegistryPath = ('HKCU\Software\ProFix\DisabledStartup\' + $e.Name)
                Restorable = $true
            }
        }
        $obj = [pscustomobject]@{
            App = 'ProFix'
            Version = $script:AppVersion
            Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            HealthScoreBefore = $ScoreBefore
            HealthGradeBefore = $GradeBefore
            SoftwareScoreBefore = $SoftwareBefore
            HardwareScoreBefore = $HardwareBefore
            RestorePointCreated = [bool]$FixResult.RestorePointCreated
            JunkDeletedCount = [long]$FixResult.Deleted
            JunkFreedBytes = [long]$FixResult.Freed
            JunkRestorable = $false
            RecycleBinEmptied = [bool]$FixResult.RecycleEmptied
            RecycleBinItems = [long]$FixResult.RecycleItems
            DnsFlushed = [bool]$FixResult.DnsFlushed
            StartupDisabled = $disabledEntries
            NonRestorableNote = 'Deleted junk files cannot be restored - use the System Restore Point created before fixing if needed.'
        }
        $json = $obj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($script:RestoreJsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-ProFixLog ("Restore backup written: {0}" -f $script:RestoreJsonPath)
        return $script:RestoreJsonPath
    } catch {
        Write-ProFixLog ('Restore backup could not be written: ' + $_.Exception.Message)
        return $null
    }
}

function Get-ProFixRestorableEntries {
    try {
        if (-not (Test-Path -LiteralPath $script:RestoreJsonPath)) { return @() }
        $data = Get-Content -LiteralPath $script:RestoreJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data -or $null -eq $data.StartupDisabled) { return @() }
        $entries = @()
        foreach ($e in @($data.StartupDisabled)) {
            if ($e.Restorable -ne $false) { $entries += $e }
        }
        return $entries
    } catch {
        Write-ProFixLog ('Restore backup could not be read (missing or corrupt): ' + $_.Exception.Message)
        return @()
    }
}

function Test-ProFixUndoAvailable {
    return (@(Get-ProFixRestorableEntries).Count -gt 0)
}

function Invoke-ProFixUndo {
    $entries = @(Get-ProFixRestorableEntries)
    if ($entries.Count -eq 0) {
        return @{ Restored = 0; Failed = 0; Names = @(); Reason = 'No restorable startup apps found in the last fix backup.' }
    }
    $restored = 0; $failed = 0; $names = @()
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $backupRoot = 'HKCU:\Software\ProFix\DisabledStartup'
    foreach ($e in $entries) {
        try {
            if (-not (Test-Path $runPath)) { New-Item -Path $runPath -Force | Out-Null }
            Set-ItemProperty -Path $runPath -Name $e.Name -Value ([string]$e.Value) -Force -ErrorAction Stop
            try {
                if (Test-Path $backupRoot) { Remove-ItemProperty -Path $backupRoot -Name $e.Name -Force -ErrorAction SilentlyContinue }
            } catch { }
            $restored++; $names += [string]$e.Name
            Write-ProFixLog ("Undo: restored startup app [{0}]" -f $e.Name)
        } catch {
            $failed++
            Write-ProFixLog ("Undo failed: {0} - {1}" -f $e.Name, $_.Exception.Message)
        }
    }
    try {
        if (Test-Path $backupRoot) {
            $left = @( (Get-Item $backupRoot -ErrorAction SilentlyContinue).Property )
            if ($left.Count -eq 0) { Remove-Item -Path $backupRoot -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    $undone = $null
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $undone = Join-Path $script:RestoreJsonDir ("ProFix_Restore-UNDONE-{0}.json" -f $stamp)
        Move-Item -LiteralPath $script:RestoreJsonPath -Destination $undone -Force -ErrorAction Stop
        Write-ProFixLog ("Restore backup moved to: {0}" -f $undone)
    } catch {
        Write-ProFixLog ('Restore backup could not be renamed after undo: ' + $_.Exception.Message)
    }
    return @{ Restored = $restored; Failed = $failed; Names = $names; UndonePath = $undone }
}

function New-ProFixBeforeAfterReport {
    param([int]$ScoreBefore, [string]$GradeBefore, [hashtable]$FixResult, $AfterDiagnosis, [int]$SoftwareBefore = 0, [int]$HardwareBefore = 0)
    $afterScore = $AfterDiagnosis.Score
    $afterGrade = $AfterDiagnosis.Grade
    $reportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("ProFix-Report-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $disabledNames = @($FixResult.DisabledNames)
    $lines = @()
    $lines += 'ProFix v1.0.0 - Before vs After Health Report'
    $lines += ('Date: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines += ''
    $lines += ('Health Score: {0} ({1}) -> {2} ({3})' -f $ScoreBefore, $GradeBefore, $afterScore, $afterGrade)
    $lines += ('System Health: {0}/75 + Hardware Health: {1}/25 = {2}  ->  System Health: {3}/75 + Hardware Health: {4}/25 = {5}' -f $SoftwareBefore, $HardwareBefore, $ScoreBefore, $AfterDiagnosis.SoftwareScore, $AfterDiagnosis.HardwareScore, $afterScore)
    if ($AfterDiagnosis.CapReason) { $lines += ('CAP APPLIED: {0}' -f $AfterDiagnosis.CapReason) }
    $lines += ('Freed: {0} ({1} files deleted)' -f (Format-Size ([long]$FixResult.Freed)), $FixResult.Deleted)
    $lines += ('Startup Apps Disabled: {0}' -f $disabledNames.Count)
    foreach ($n in $disabledNames) { $lines += ('  - {0}' -f $n) }
    if ([bool]$FixResult.RecycleEmptied) {
        $lines += ('Recycle Bin: Emptied ({0} items)' -f $FixResult.RecycleItems)
    } elseif ([long]$FixResult.RecycleItems -eq 0) {
        $lines += 'Recycle Bin: Already empty'
    } else {
        $lines += 'Recycle Bin: Kept (not confirmed)'
    }
    $lines += ('DNS: {0}' -f $(if ($FixResult.DnsFlushed) { 'Flushed' } else { 'Not flushed' }))
    $lines += ('Restore Point: {0}' -f $(if ($FixResult.RestorePointCreated) { 'Created' } else { 'Not created' }))
    $lines += ''
    $lines += 'Recommendations still open:'
    $open = @()
    foreach ($id in @($AfterDiagnosis.Items.Keys)) {
        $it = $AfterDiagnosis.Items[$id]
        if ($it.Status -ne 'Good') { $open += ('- {0} ({1}): {2} | {3}' -f $it.Name, $it.Status, $it.Detail, $it.Fix) }
    }
    if ($open.Count -eq 0) { $lines += '  None - all checks Good.' } else { $lines += $open }
    $lines += ''
    $lines += 'Note: Deleted junk files cannot be restored. Startup apps disabled by this fix can be restored with the Undo Last Fix button (ProFix_Restore.json).'
    try {
        [System.IO.File]::WriteAllLines($reportPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-ProFixLog ("Before/After report written: {0}" -f $reportPath)
    } catch {
        Write-ProFixLog ('Before/After report could not be written: ' + $_.Exception.Message)
        return $null
    }
    return $reportPath
}

# ---------------------------------------------------------------------------
# System info getters - each returns a hashtable, never throws
# ---------------------------------------------------------------------------
function Get-JunkInfo {
    $sources = @(
        @{ Paths = @($env:TEMP, "$env:SystemRoot\Temp"); MinAgeHours = 24 }
        @{ Paths = @(Get-BrowserCachePaths); MinAgeHours = 0 }
        @{ Paths = @("$env:SystemRoot\Logs", "$env:SystemRoot\Panther"); MinAgeHours = 168 }
        @{ Paths = @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\AMD\DxCache"); MinAgeHours = 168 }
        @{ Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"); MinAgeHours = 168 }
    )
    $files = @()
    foreach ($s in $sources) { $files += @(Get-FilesInPaths -Paths $s.Paths -MinAgeHours $s.MinAgeHours) }
    $size = 0; foreach ($f in $files) { $size += $f.Length }
    return @{ Files = $files; Count = $files.Count; SizeBytes = $size; BrowserRunning = (Get-BrowserRunning) }
}

function Get-DriveCInfo {
    try {
        $d = Get-PSDrive -Name 'C' -ErrorAction Stop
        $free = [long]$d.Free; $total = [long]($d.Used + $d.Free)
        if ($total -le 0) { $total = 1 }
        $pctFree = [Math]::Round(($free / $total) * 100, 1)
        return @{ FreeBytes = $free; TotalBytes = $total; PctFree = $pctFree }
    } catch {
        return @{ FreeBytes = 0; TotalBytes = 1; PctFree = 0 }
    }
}

function Get-StartupAppsInfo {
    # NOTE: $apps is a List, not an array, on purpose. The $add scriptblock
    # below runs in a child scope, so "$apps += ..." would create a local
    # copy and the caller would see an empty list. List.Add() mutates the
    # same object across scopes, so it works. Same reason $seen is a
    # hashtable (mutated, never reassigned).
    $apps = New-Object System.Collections.Generic.List[pscustomobject]
    $seen = @{}
    $add = {
        param([string]$Name, [string]$Command, [string]$Location)
        if (-not $Name) { $Name = '(unnamed)' }
        if (-not $Command) { $Command = '' }
        $key = ($Name + '|' + $Command).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        [void]$apps.Add([pscustomobject]@{ Name = $Name; Command = $Command; Location = $Location })
    }
    # 1. WMI Win32_StartupCommand (covers Run keys + Startup folder, as Windows sees them)
    try {
        Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object {
            & $add $_.Name $_.Command $_.Location
        }
    } catch { }
    # 2. HKCU Run (the only source v1 can disable) + HKLM Run (info only)
    foreach ($pair in @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKCU Run' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKLM Run' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Location = 'HKLM Run (32-bit)' }
    )) {
        try {
            if (Test-Path $pair.Path) {
                $props = Get-ItemProperty -Path $pair.Path -ErrorAction SilentlyContinue
                if ($null -ne $props) {
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                        & $add $prop.Name ([string]$prop.Value) $pair.Location
                    }
                }
            }
        } catch { }
    }
    # 3. Startup folders (info only in v1)
    foreach ($pair in @(
        @{ Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); Location = 'Startup Folder (user)' },
        @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Location = 'Startup Folder (all users)' }
    )) {
        try {
            if (Test-Path $pair.Path) {
                Get-ChildItem -Path $pair.Path -File -ErrorAction SilentlyContinue | ForEach-Object {
                    & $add $_.BaseName $_.FullName $pair.Location
                }
            }
        } catch { }
    }
    return $apps
}

function Get-AveragedCpuRamInfo {
    # NO 1-sec snapshot: ProFix itself spikes CPU on launch. Wait 1 sec,
    # then sample CPU % + RAM % 4 times, 1 sec apart, and average them.
    # Takes ~4 sec; GUI status/progress are updated while sampling.
    if ($script:lblStatus) { $script:lblStatus.Text = 'Measuring CPU/RAM (3-5 sec average)...' }
    if ($script:progressBar) { $script:progressBar.Value = 10 }
    if ($script:progressBar) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
    Start-Sleep -Seconds 1
    $cpuSamples = @(); $ramSamples = @(); $freeSamples = @(); $totalBytes = 0
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $procs = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue
            $vals = @($procs | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [int]$_.LoadPercentage })
            if ($vals.Count -gt 0) { $cpuSamples += [double](($vals | Measure-Object -Average).Average) }
        } catch { }
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $totalKB = [long]$os.TotalVisibleMemorySize
            $freeKB = [long]$os.FreePhysicalMemory
            if ($totalKB -gt 0) {
                $ramSamples += [double]((($totalKB - $freeKB) / $totalKB) * 100)
                $freeSamples += [long]($freeKB * 1024)
                $totalBytes = [long]($totalKB * 1024)
            }
        } catch { }
        if ($script:progressBar) { $script:progressBar.Value = 10 + (($i + 1) * 10) }
        if ($script:progressBar) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
        if ($i -lt 3) { Start-Sleep -Seconds 1 }
    }
    $cpuAvg = 0; if ($cpuSamples.Count -gt 0) { $cpuAvg = [Math]::Round(($cpuSamples | Measure-Object -Average).Average, 0) }
    $ramAvg = 0; if ($ramSamples.Count -gt 0) { $ramAvg = [Math]::Round(($ramSamples | Measure-Object -Average).Average, 1) }
    $freeAvg = 0; if ($freeSamples.Count -gt 0) { $freeAvg = [long](($freeSamples | Measure-Object -Average).Average) }
    return @{ CpuPct = $cpuAvg; RamUsedPct = $ramAvg; TotalBytes = $totalBytes; FreeBytes = $freeAvg }
}

function Get-HardwareInfo {
    # All read-only WMI/CIM. Never throws. Non-admin fallback: drive
    # Unknown (7 pts) and SMART Unchecked (5 pts) - never a crash or 0.
    $driveType = 'Unknown'; $totalRamGB = 0.0; $smartOk = $true; $smartChecked = $false
    $cpuThreads = 0; $batteryPct = $null; $note = ''
    try {
        $sum = 0
        Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object { $sum += [long]$_.Capacity }
        if ($sum -gt 0) { $totalRamGB = [Math]::Round($sum / 1GB, 1) }
    } catch {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.TotalPhysicalMemory -gt 0) { $totalRamGB = [Math]::Round([long]$cs.TotalPhysicalMemory / 1GB, 1) }
        } catch { }
    }
    try {
        $t = 0
        Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | ForEach-Object { $t += [int]$_.NumberOfLogicalProcessors }
        if ($t -gt 0) { $cpuThreads = $t }
    } catch { }
    if ($cpuThreads -le 0) { $cpuThreads = [Environment]::ProcessorCount }
    # OS drive type: Get-PhysicalDisk first (string MediaType), then
    # MSFT_PhysicalDisk CIM (MediaType 4/5 = SSD, 3 = HDD, BusType 17 = NVMe).
    $driveFound = $false
    try {
        $part = Get-Partition -DriveLetter C -ErrorAction Stop
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.FriendlyName -eq $disk.FriendlyName } | Select-Object -First 1
        if ($null -ne $pd) {
            $driveFound = $true
            if ($pd.MediaType -eq 'SSD') { $driveType = 'SSD' }
            elseif ($pd.MediaType -eq 'HDD') { $driveType = 'HDD' }
        }
    } catch { }
    if (-not $driveFound) {
        try {
            $disks = @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop)
            if ($disks.Count -eq 1) {
                $mt = [int]$disks[0].MediaType; $bt = [int]$disks[0].BusType
                if ($bt -eq 17 -or $mt -eq 4 -or $mt -eq 5) { $driveType = 'SSD' }
                elseif ($mt -eq 3) { $driveType = 'HDD' }
            }
        } catch { }
    }
    # SMART: root\wmi MSStorageDriver_FailurePredictStatus (needs admin
    # on some PCs - a failed query means Unchecked, never Failing).
    try {
        $smart = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
        if ($smart.Count -gt 0) {
            $smartChecked = $true
            foreach ($row in $smart) { if ($row.PredictFailure) { $smartOk = $false } }
        }
    } catch { $smartChecked = $false }
    # Battery health (laptops): worst battery; desktops have none = OK.
    try {
        $bats = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($bats.Count -gt 0) {
            $worst = 100
            foreach ($b in $bats) {
                if ($b.DesignCapacity -gt 0 -and $b.FullChargeCapacity -gt 0) {
                    $h = [Math]::Round($b.FullChargeCapacity / $b.DesignCapacity * 100, 0)
                    if ($h -lt $worst) { $worst = $h }
                }
            }
            $batteryPct = $worst
        }
    } catch { }
    if ($driveType -eq 'Unknown' -or -not $smartChecked) {
        $note = 'Run as Administrator for full hardware diagnostics.'
    }
    $drivePts = if ($driveType -eq 'SSD') { 12 } elseif ($driveType -eq 'HDD') { 0 } else { 7 }
    $ramPts = if ($totalRamGB -ge 16) { 8 } elseif ($totalRamGB -ge 8) { 5 } else { 0 }
    if (-not $smartChecked) { $healthPts = 5 }
    elseif (-not $smartOk) { $healthPts = 0 }
    elseif ($cpuThreads -lt 4 -or ($null -ne $batteryPct -and $batteryPct -lt 60)) { $healthPts = 2 }
    else { $healthPts = 5 }
    return @{ DriveType = $driveType; DrivePoints = $drivePts; TotalRamGB = $totalRamGB; RamPoints = $ramPts;
        SmartOk = $smartOk; SmartChecked = $smartChecked; CpuThreads = $cpuThreads; BatteryPct = $batteryPct;
        HealthPoints = $healthPts; Note = $note }
}

function Get-DnsLatencyMs {
    # Time one real DNS lookup. Timeout / failure = -1 (0 points).
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Resolve-DnsName -Name 'www.google.com' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        return [int]$sw.ElapsedMilliseconds
    } catch { return -1 }
}

function Get-UpdatesAvailableInfo {
    param([bool]$PendingReboot)
    # Pending reboot already scores 0 for this check - no need to search.
    if ($PendingReboot) { return @{ Available = $false; Count = 0; Checked = $false } }
    try {
        Write-ProFixLog 'Checking Windows Update for pending updates (may take a few seconds)...'
        $session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0")
        $count = [int]$result.Updates.Count
        return @{ Available = ($count -gt 0); Count = $count; Checked = $true }
    } catch {
        # Never guess: if the check cannot be completed, treat as no
        # updates pending and say so in the log.
        Write-ProFixLog ('Windows Update check could not be completed - treating as no updates pending: ' + $_.Exception.Message)
        return @{ Available = $false; Count = 0; Checked = $false }
    }
}

function Get-NonMicrosoftStartupCount {
    param($Apps)
    # Scoring counts ENABLED non-Microsoft apps only. Run keys and the
    # Startup folder are enabled by definition; WMI rows are deduped
    # already. Microsoft's own apps (OneDrive, Teams, Windows Security)
    # are excluded by name/command containing "Microsoft".
    $count = 0
    foreach ($a in $Apps) {
        $text = ($a.Name + ' ' + $a.Command)
        if ($text -match 'Microsoft' -or $a.Name -match '^Windows ') { continue }
        $count++
    }
    return $count
}

function Get-HealthScore {
    param([hashtable]$M)
    # Exact port of Syed's calculate_health_score (SCORE_SPEC_75_25.md).
    # $M keys: CFreeGB, CFreePct, RamUsedPct, StartupNonMs, CpuPct,
    # UptimeDays, JunkGB, PendingRestart, UpdatesAvailable, RecycleGB,
    # DnsMs, OsDriveType, TotalRamGB, SmartOk, SmartChecked, CpuThreads,
    # BatteryPct (or $null).
    $b = @{}
    if ($M.CFreeGB -ge 40 -or $M.CFreePct -ge 20) { $b['c_drive'] = 20 }
    elseif ($M.CFreeGB -ge 25 -or $M.CFreePct -ge 15) { $b['c_drive'] = 15 }
    elseif ($M.CFreeGB -ge 15 -or $M.CFreePct -ge 10) { $b['c_drive'] = 10 }
    elseif ($M.CFreeGB -ge 5 -or $M.CFreePct -ge 5) { $b['c_drive'] = 5 }
    else { $b['c_drive'] = 0 }
    if ($M.RamUsedPct -lt 65) { $b['ram_pressure'] = 15 }
    elseif ($M.RamUsedPct -lt 80) { $b['ram_pressure'] = 10 }
    elseif ($M.RamUsedPct -lt 90) { $b['ram_pressure'] = 5 }
    else { $b['ram_pressure'] = 0 }
    if ($M.StartupNonMs -le 3) { $b['startup'] = 12 }
    elseif ($M.StartupNonMs -le 6) { $b['startup'] = 8 }
    elseif ($M.StartupNonMs -le 10) { $b['startup'] = 4 }
    else { $b['startup'] = 0 }
    $cpuPts = if ($M.CpuPct -lt 40) { 5 } elseif ($M.CpuPct -lt 70) { 3 } elseif ($M.CpuPct -lt 85) { 1 } else { 0 }
    $upPts = if ($M.UptimeDays -lt 3) { 5 } elseif ($M.UptimeDays -lt 7) { 3 } elseif ($M.UptimeDays -lt 14) { 1 } else { 0 }
    $b['cpu_uptime'] = $cpuPts + $upPts
    $b['cpu_points'] = $cpuPts; $b['uptime_points'] = $upPts
    if ($M.JunkGB -lt 0.5) { $b['junk'] = 8 }
    elseif ($M.JunkGB -lt 2.0) { $b['junk'] = 6 }
    elseif ($M.JunkGB -lt 5.0) { $b['junk'] = 3 }
    else { $b['junk'] = 0 }
    if ($M.PendingRestart) { $b['updates'] = 0 }
    elseif ($M.UpdatesAvailable) { $b['updates'] = 4 }
    else { $b['updates'] = 6 }
    $rbPts = if ($M.RecycleGB -lt 0.5) { 2 } elseif ($M.RecycleGB -le 2.0) { 1 } else { 0 }
    $dnsMs = $M.DnsMs
    $dnsPts = if ($null -eq $dnsMs -or $dnsMs -lt 0) { 0 } elseif ($dnsMs -lt 50) { 2 } elseif ($dnsMs -le 150) { 1 } else { 0 }
    $b['recycle_dns'] = $rbPts + $dnsPts
    $b['recycle_points'] = $rbPts; $b['dns_points'] = $dnsPts
    $b['hw_drive'] = if ($M.OsDriveType -eq 'SSD') { 12 } elseif ($M.OsDriveType -eq 'HDD') { 0 } else { 7 }
    if ($M.TotalRamGB -ge 16) { $b['hw_ram'] = 8 }
    elseif ($M.TotalRamGB -ge 8) { $b['hw_ram'] = 5 }
    else { $b['hw_ram'] = 0 }
    if (-not $M.SmartChecked) { $b['hw_health'] = 5 }
    elseif (-not $M.SmartOk) { $b['hw_health'] = 0 }
    elseif ($M.CpuThreads -lt 4 -or ($null -ne $M.BatteryPct -and $M.BatteryPct -lt 60)) { $b['hw_health'] = 2 }
    else { $b['hw_health'] = 5 }
    $software = $b['c_drive'] + $b['ram_pressure'] + $b['startup'] + $b['cpu_uptime'] + $b['junk'] + $b['updates'] + $b['recycle_dns']
    $hardware = $b['hw_drive'] + $b['hw_ram'] + $b['hw_health']
    $total = $software + $hardware
    $capReason = $null
    if ($M.SmartChecked -and -not $M.SmartOk -and $total -gt 39) {
        $total = 39
        $capReason = 'Hard drive failure risk detected — backup data first!'
    } elseif ($M.CFreeGB -lt 2.0 -and $total -gt 44) {
        $total = 44
        $capReason = 'C: drive has under 2 GB free — critical risk of Windows slowdown/errors.'
    }
    $grade = Get-Grade -Score $total
    $instant = (8 - $b['junk']) + (2 - $rbPts) + (2 - $dnsPts) + (12 - $b['startup'])
    return @{ Total = $total; Grade = $grade; Software = $software; Hardware = $hardware;
        CapReason = $capReason; InstantFixable = $instant; Breakdown = $b; Verdict = (Get-Verdict -Score $total) }
}

function Get-PendingRebootInfo {
    $reasons = @()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $paths) {
        try { if (Test-Path $p) { $reasons += $p } } catch { }
    }
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($null -ne $v -and $null -ne $v.PendingFileRenameOperations) { $reasons += 'PendingFileRenameOperations' }
    } catch { }
    $svcStatus = 'Unknown'
    try {
        $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        if ($svc) { $svcStatus = $svc.Status.ToString() }
    } catch { }
    return @{ Pending = ($reasons.Count -gt 0); Reasons = $reasons; Wuauserv = $svcStatus }
}

# ---------------------------------------------------------------------------
# Diagnose engine - preview only, deletes / changes nothing
# ---------------------------------------------------------------------------
function Get-Grade {
    param([int]$Score)
    if ($Score -ge 85) { return 'Excellent' }
    if ($Score -ge 65) { return 'Good' }
    if ($Score -ge 45) { return 'Fair' }
    return 'Poor'
}

function Get-Verdict {
    param([int]$Score)
    if ($Score -ge 85) { return 'PC healthy hai - koi major bottleneck nahi.' }
    if ($Score -ge 65) { return 'Smooth chal raha hai, minor cleanup se aur tez hoga.' }
    if ($Score -ge 45) { return 'Noticeable slowdown hai - 1-Click Fix recommend hai.' }
    return 'Heavy bottleneck ya critical issue - immediate action chahiye.'
}

function Get-ScoreColor {
    param([int]$Score)
    if ($Score -ge 85) { return [System.Drawing.Color]::DarkGreen }
    if ($Score -ge 65) { return [System.Drawing.Color]::Teal }
    if ($Score -ge 45) { return [System.Drawing.Color]::DarkOrange }
    return [System.Drawing.Color]::DarkRed
}

function Update-ScoreDisplay {
    param($Diag)
    if (-not $script:lblScore) { return }
    $script:lblScore.Text = ('Health Score: {0} - {1}' -f $Diag.Score, $Diag.Grade)
    $script:lblScore.ForeColor = Get-ScoreColor -Score $Diag.Score
    if ($script:lblSystemHealth) {
        $script:lblSystemHealth.Text = ('System Health: {0} / 75' -f $Diag.SoftwareScore)
        $script:lblHardwareHealth.Text = ('Hardware Health: {0} / 25' -f $Diag.HardwareScore)
    }
    if ($script:barSystem) {
        $script:barSystem.Value = [Math]::Min(75, [Math]::Max(0, $Diag.SoftwareScore))
        $script:barHardware.Value = [Math]::Min(25, [Math]::Max(0, $Diag.HardwareScore))
    }
}

function Invoke-ProFixDiagnose {
    $script:JunkFiles = @()
    $script:StartupApps = @()
    $script:StartupDisable = @{}
    $items = @{}

    # CPU + RAM first: averaged over 3-5 sec (never a 1-sec snapshot).
    $avg = Get-AveragedCpuRamInfo
    $cpuPct = $avg.CpuPct; $ramUsedPct = $avg.RamUsedPct
    $memTotal = $avg.TotalBytes; $memFree = $avg.FreeBytes
    $uptimeDays = 0.0
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $boot = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
        $uptimeDays = [Math]::Round(((Get-Date) - $boot).TotalDays, 1)
    } catch {
        try { $uptimeDays = [Math]::Round([Environment]::TickCount / 86400000.0, 1) } catch { }
    }

    # 1. Junk files
    $junk = Get-JunkInfo
    $script:JunkFiles = $junk.Files
    $junkGB = [Math]::Round($junk.SizeBytes / 1GB, 2)
    $junkPts = if ($junkGB -lt 0.5) { 8 } elseif ($junkGB -lt 2.0) { 6 } elseif ($junkGB -lt 5.0) { 3 } else { 0 }
    $detail = '{0} files, {1} reclaimable' -f $junk.Count, (Format-Size $junk.SizeBytes)
    if ($junk.BrowserRunning) { $detail += ' - browser is running, close it for a full clean' }
    $items['Junk'] = @{ Name = 'Junk Files'; Status = $(if ($junkPts -eq 8) { 'Good' } elseif ($junkPts -eq 0) { 'Bad' } else { 'Warning' });
        Detail = $detail; Fix = 'Clean junk files'; Points = $junkPts; MaxPoints = 8; Delta = ($junkPts - 8) }

    # 2. C: drive free space (dual GB OR % rule)
    $drive = Get-DriveCInfo
    $cFreeGB = [Math]::Round($drive.FreeBytes / 1GB, 1)
    $cPts = if ($cFreeGB -ge 40 -or $drive.PctFree -ge 20) { 20 } elseif ($cFreeGB -ge 25 -or $drive.PctFree -ge 15) { 15 } elseif ($cFreeGB -ge 15 -or $drive.PctFree -ge 10) { 10 } elseif ($cFreeGB -ge 5 -or $drive.PctFree -ge 5) { 5 } else { 0 }
    $items['DriveC'] = @{ Name = 'C: Drive Free Space'; Status = $(if ($cPts -eq 20) { 'Good' } elseif ($cPts -ge 10) { 'Warning' } else { 'Bad' });
        Detail = ('{0} free of {1} ({2}% free)' -f (Format-Size $drive.FreeBytes), (Format-Size $drive.TotalBytes), $drive.PctFree);
        Fix = 'No automatic fix - free space or move files off C:'; Points = $cPts; MaxPoints = 20; Delta = ($cPts - 20) }

    # 3. Startup apps - scoring counts non-Microsoft only, UI lists all
    $apps = @(Get-StartupAppsInfo)
    $script:StartupApps = $apps
    foreach ($a in $apps) {
        if ($a.Location -eq 'HKCU Run') { $script:StartupDisable[$a.Name] = $true }
    }
    $nonMsCount = Get-NonMicrosoftStartupCount -Apps $apps
    $stPts = if ($nonMsCount -le 3) { 12 } elseif ($nonMsCount -le 6) { 8 } elseif ($nonMsCount -le 10) { 4 } else { 0 }
    $hkcuCount = @($apps | Where-Object { $_.Location -eq 'HKCU Run' }).Count
    $items['Startup'] = @{ Name = 'Startup Apps'; Status = $(if ($stPts -eq 12) { 'Good' } elseif ($stPts -eq 0) { 'Bad' } else { 'Warning' });
        Detail = ('{0} startup apps ({1} non-Microsoft counted, {2} in HKCU Run - can be disabled in v1)' -f $apps.Count, $nonMsCount, $hkcuCount);
        Fix = 'Disable selected HKCU Run apps (reversible, backed up to log)'; Points = $stPts; MaxPoints = 12; Delta = ($stPts - 12) }

    # 4. Memory pressure (averaged RAM %)
    $ramPts = if ($ramUsedPct -lt 65) { 15 } elseif ($ramUsedPct -lt 80) { 10 } elseif ($ramUsedPct -lt 90) { 5 } else { 0 }
    $items['Memory'] = @{ Name = 'Memory (RAM) Pressure'; Status = $(if ($ramPts -eq 15) { 'Good' } elseif ($ramPts -eq 0) { 'Bad' } else { 'Warning' });
        Detail = ('{0}% used (3-sec avg) - {1} free of {2}' -f $ramUsedPct, (Format-Size $memFree), (Format-Size $memTotal));
        Fix = 'No automatic fix - close heavy apps / add RAM'; Points = $ramPts; MaxPoints = 15; Delta = ($ramPts - 15) }

    # 5. CPU load (5-sec avg) + Uptime
    $cpuPts = if ($cpuPct -lt 40) { 5 } elseif ($cpuPct -lt 70) { 3 } elseif ($cpuPct -lt 85) { 1 } else { 0 }
    $upPts = if ($uptimeDays -lt 3) { 5 } elseif ($uptimeDays -lt 7) { 3 } elseif ($uptimeDays -lt 14) { 1 } else { 0 }
    $cpuUpPts = $cpuPts + $upPts
    $items['CpuUptime'] = @{ Name = 'CPU Load + Uptime'; Status = $(if ($cpuUpPts -ge 8) { 'Good' } elseif ($cpuUpPts -ge 4) { 'Warning' } else { 'Bad' });
        Detail = ('CPU {0}% (5-sec avg) - uptime {1} days' -f $cpuPct, $uptimeDays);
        Fix = 'No automatic fix - restart your PC'; Points = $cpuUpPts; MaxPoints = 10; Delta = ($cpuUpPts - 10) }

    # 6. Windows Update / Pending reboot
    $reb = Get-PendingRebootInfo
    $upd = Get-UpdatesAvailableInfo -PendingReboot ([bool]$reb.Pending)
    $updPts = if ($reb.Pending) { 0 } elseif ($upd.Available) { 4 } else { 6 }
    $detail = if ($reb.Pending) { 'Restart pending (Windows Update) - wuauserv: ' + $reb.Wuauserv }
        elseif ($upd.Available) { 'Updates available ({0}) - no restart needed yet - wuauserv: {1}' -f $upd.Count, $reb.Wuauserv }
        elseif ($upd.Checked) { 'No restart pending, no updates available - wuauserv: ' + $reb.Wuauserv }
        else { 'No restart pending - Windows Update check could not be completed - wuauserv: ' + $reb.Wuauserv }
    $items['UpdateReboot'] = @{ Name = 'Windows Update / Reboot'; Status = $(if ($updPts -eq 6) { 'Good' } else { 'Warning' });
        Detail = $detail; Fix = 'No automatic fix - restart your PC when ready'; Points = $updPts; MaxPoints = 6; Delta = ($updPts - 6) }

    # 7. Recycle Bin + DNS latency
    $rb = Get-RecycleBinInfo
    $rbGB = [Math]::Round($rb.SizeBytes / 1GB, 2)
    $rbPts = if ($rbGB -lt 0.5) { 2 } elseif ($rbGB -le 2.0) { 1 } else { 0 }
    $dnsMs = Get-DnsLatencyMs
    $dnsPts = if ($dnsMs -lt 0) { 0 } elseif ($dnsMs -lt 50) { 2 } elseif ($dnsMs -le 150) { 1 } else { 0 }
    $rdPts = $rbPts + $dnsPts
    $dnsText = if ($dnsMs -lt 0) { 'DNS lookup failed' } else { ('DNS {0} ms' -f $dnsMs) }
    $items['RecycleDns'] = @{ Name = 'Recycle Bin + DNS'; Status = $(if ($rdPts -ge 3) { 'Good' } elseif ($rdPts -eq 0) { 'Bad' } else { 'Warning' });
        Detail = ('Recycle Bin: {0} items, {1} - {2}' -f $rb.Count, (Format-Size $rb.SizeBytes), $dnsText);
        Fix = 'Empty Recycle Bin + flush DNS'; Points = $rdPts; MaxPoints = 4; Delta = ($rdPts - 4) }

    # Hardware (read-only WMI/CIM) - 3 rows, same numbers as the score
    $hw = Get-HardwareInfo
    $items['HwDrive'] = @{ Name = 'Hardware: OS Drive'; Status = $(if ($hw.DrivePoints -eq 12) { 'Good' } elseif ($hw.DrivePoints -eq 0) { 'Bad' } else { 'Warning' });
        Detail = ('OS drive type: {0}{1}' -f $hw.DriveType, $(if ($hw.Note) { ' - ' + $hw.Note } else { '' }));
        Fix = $(if ($hw.DriveType -eq 'HDD') { 'No automatic fix - SSD upgrade would speed boot 4x-5x' } elseif ($hw.DriveType -eq 'SSD') { 'No fix needed - SSD already installed' } else { 'No automatic fix - run as Administrator for full hardware diagnostics' });
        Points = $hw.DrivePoints; MaxPoints = 12; Delta = ($hw.DrivePoints - 12) }
    $items['HwRam'] = @{ Name = 'Hardware: Total RAM'; Status = $(if ($hw.RamPoints -eq 8) { 'Good' } elseif ($hw.RamPoints -eq 0) { 'Bad' } else { 'Warning' });
        Detail = ('Total RAM installed: {0} GB' -f $hw.TotalRamGB);
        Fix = $(if ($hw.RamPoints -eq 8) { 'No fix needed - 16 GB or more' } elseif ($hw.RamPoints -eq 5) { 'No automatic fix - 16 GB would help heavy multitasking' } else { 'No automatic fix - RAM upgrade recommended (under 8 GB)' });
        Points = $hw.RamPoints; MaxPoints = 8; Delta = ($hw.RamPoints - 8) }
    $hwHealthDetail = if (-not $hw.SmartChecked) { 'SMART status could not be checked (run as Administrator) - CPU threads: ' + $hw.CpuThreads }
        elseif (-not $hw.SmartOk) { 'SMART WARNING - disk may be failing - back up your data first! CPU threads: ' + $hw.CpuThreads }
        else { 'SMART OK - CPU threads: ' + $hw.CpuThreads + $(if ($null -ne $hw.BatteryPct) { ' - Battery health: ' + $hw.BatteryPct + '%' } else { '' }) }
    $items['HwHealth'] = @{ Name = 'Hardware: Disk + CPU'; Status = $(if ($hw.HealthPoints -eq 5) { 'Good' } elseif ($hw.HealthPoints -eq 0) { 'Bad' } else { 'Warning' });
        Detail = $hwHealthDetail;
        Fix = $(if (-not $hw.SmartOk -and $hw.SmartChecked) { 'No automatic fix - back up your data immediately' } else { 'No automatic fix - hardware is read-only in ProFix' });
        Points = $hw.HealthPoints; MaxPoints = 5; Delta = ($hw.HealthPoints - 5) }

    # 75/25 score - exact port of calculate_health_score
    $scoreResult = Get-HealthScore -M @{
        CFreeGB = $cFreeGB; CFreePct = $drive.PctFree; RamUsedPct = $ramUsedPct; StartupNonMs = $nonMsCount;
        CpuPct = $cpuPct; UptimeDays = $uptimeDays; JunkGB = $junkGB; PendingRestart = [bool]$reb.Pending;
        UpdatesAvailable = [bool]$upd.Available; RecycleGB = $rbGB; DnsMs = $dnsMs;
        OsDriveType = $hw.DriveType; TotalRamGB = $hw.TotalRamGB; SmartOk = [bool]$hw.SmartOk;
        SmartChecked = [bool]$hw.SmartChecked; CpuThreads = $hw.CpuThreads; BatteryPct = $hw.BatteryPct }
    $script:Diagnosis = @{ Score = $scoreResult.Total; Grade = $scoreResult.Grade; Verdict = $scoreResult.Verdict;
        SoftwareScore = $scoreResult.Software; HardwareScore = $scoreResult.Hardware;
        CapReason = $scoreResult.CapReason; InstantFixable = $scoreResult.InstantFixable;
        Breakdown = $scoreResult.Breakdown; Items = $items;
        RecycleCount = $rb.Count; RecycleSize = $rb.SizeBytes }
    foreach ($id in $items.Keys) {
        Write-ProFixLog ("Diagnose: {0} - {1} | {2} ({3}) [{4}/{5} pts]" -f $items[$id].Name, $items[$id].Status, $items[$id].Detail, $items[$id].Fix, $items[$id].Points, $items[$id].MaxPoints)
    }
    Write-ProFixLog ("Health Score: {0} - {1} (System {2}/75 + Hardware {3}/25). {4}" -f $scoreResult.Total, $scoreResult.Grade, $scoreResult.Software, $scoreResult.Hardware, $scoreResult.Verdict)
    if ($scoreResult.CapReason) { Write-ProFixLog ('CAP APPLIED: ' + $scoreResult.CapReason) }
    Write-ProFixLog ("1-Click Fix se +{0} points turant badhenge." -f $scoreResult.InstantFixable)
    return $script:Diagnosis
}

# ---------------------------------------------------------------------------
# Fix engine - only what was diagnosed and ticked, counts every outcome
# ---------------------------------------------------------------------------
function Remove-JunkFiles {
    $deleted = 0; $skipped = 0; $freed = 0
    $total = $script:JunkFiles.Count; $i = 0
    foreach ($f in $script:JunkFiles) {
        $i++
        if (($i % 100) -eq 0 -and $script:progressBar) {
            $script:progressBar.Value = [Math]::Min(100, [int](($i / [Math]::Max(1, $total)) * 100))
            [System.Windows.Forms.Application]::DoEvents()
        }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deleted++; $freed += $f.Length
        } catch {
            $skipped++
        }
    }
    Write-ProFixLog ("Junk: {0} deleted, {1} skipped (in use or locked)." -f $deleted, $skipped)
    return @{ Deleted = $deleted; Skipped = $skipped; Freed = $freed }
}

function Disable-SelectedStartupApps {
    $disabled = 0; $skipped = 0
    $disabledApps = @()
    $backupRoot = 'HKCU:\Software\ProFix\DisabledStartup'
    foreach ($a in $script:StartupApps) {
        if ($a.Location -ne 'HKCU Run') { continue }
        if (-not $script:StartupDisable.ContainsKey($a.Name)) { continue }
        if (-not $script:StartupDisable[$a.Name]) { continue }
        try {
            $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $runProps = Get-ItemProperty -Path $runPath -ErrorAction Stop
            $value = $runProps.PSObject.Properties[$a.Name].Value
            if (-not (Test-Path $backupRoot)) { New-Item -Path $backupRoot -Force | Out-Null }
            Set-ItemProperty -Path $backupRoot -Name $a.Name -Value $value -Force
            Write-ProFixLog ("Startup backup: [{0}] = {1} (saved under HKCU\Software\ProFix\DisabledStartup)" -f $a.Name, $value)
            Remove-ItemProperty -Path $runPath -Name $a.Name -Force -ErrorAction Stop
            $disabled++
            $disabledApps += @{ Name = $a.Name; Value = [string]$value }
            Write-ProFixLog ("Startup disabled: {0}" -f $a.Name)
        } catch {
            $skipped++
            Write-ProFixLog ("Startup could not be disabled: {0} - {1}" -f $a.Name, $_.Exception.Message)
        }
    }
    return @{ Disabled = $disabled; Skipped = $skipped; DisabledApps = $disabledApps }
}

function Invoke-ProFixFix {
    param([string[]]$SelectedIds, [bool]$MakeRestorePoint, [bool]$ConfirmRecycleBin)
    $deleted = 0; $skipped = 0; $freed = 0; $disabled = 0
    $allDisabledApps = @()
    $restorePointCreated = $false
    $recycleEmptied = $false
    $recycleItems = 0
    $dnsFlushed = $false

    if ($MakeRestorePoint) { $restorePointCreated = [bool](New-ProFixRestorePoint) }
    if ($null -eq $script:Diagnosis) { Write-ProFixLog 'Fix called without a Diagnose - nothing done.'; return @{ Deleted = 0; Skipped = 0; Freed = 0; Disabled = 0; DisabledApps = @(); DisabledNames = @(); RestorePointCreated = $false; RecycleEmptied = $false; RecycleItems = 0; DnsFlushed = $false; ScoreBefore = 0 } }
    $scoreBefore = $script:Diagnosis.Score

    foreach ($id in $SelectedIds) {
        if (-not $script:Diagnosis.Items.ContainsKey($id)) { continue }
        $item = $script:Diagnosis.Items[$id]
        Write-ProFixLog ("Fixing: {0} ..." -f $item.Name)

        switch ($id) {
            'Junk' {
                $res = Remove-JunkFiles
                $deleted += $res.Deleted; $skipped += $res.Skipped; $freed += $res.Freed
            }
            'Startup' {
                $res = Disable-SelectedStartupApps
                $disabled += $res.Disabled; $skipped += $res.Skipped
                $allDisabledApps += @($res.DisabledApps)
                if ($res.Disabled -eq 0) { Write-ProFixLog 'Startup: no HKCU Run apps were selected to disable (open the Startup row to pick them, or none are in HKCU Run).' }
            }
            'RecycleDns' {
                if ($ConfirmRecycleBin -and $script:Diagnosis.RecycleCount -gt 0) {
                    try {
                        Clear-RecycleBin -Force -ErrorAction Stop
                        $deleted += $script:Diagnosis.RecycleCount; $freed += $script:Diagnosis.RecycleSize
                        $recycleEmptied = $true; $recycleItems = $script:Diagnosis.RecycleCount
                        Write-ProFixLog ("Recycle Bin emptied: {0} items." -f $script:Diagnosis.RecycleCount)
                    } catch {
                        Write-ProFixLog ('Recycle Bin could not be emptied: ' + $_.Exception.Message)
                    }
                } elseif ($script:Diagnosis.RecycleCount -eq 0) {
                    Write-ProFixLog 'Recycle Bin already empty - nothing to empty.'
                } else {
                    Write-ProFixLog 'Recycle Bin kept - user did not confirm emptying it (DNS still flushed below).'
                }
                try {
                    $out = & ipconfig /flushdns 2>&1 | Out-String
                    $dnsFlushed = $true
                    Write-ProFixLog ('DNS cache flushed. ' + ($out.Trim() -replace '\s+', ' '))
                } catch {
                    Write-ProFixLog ('DNS flush failed: ' + $_.Exception.Message)
                }
            }
            default {
                Write-ProFixLog ("No automatic fix for: {0} - {1}" -f $item.Name, $item.Fix)
            }
        }
    }

    Write-ProFixLog ("Fix done: {0} files deleted ({1} freed), {2} skipped, {3} startup apps disabled." -f $deleted, (Format-Size $freed), $skipped, $disabled)
    $disabledNames = @($allDisabledApps | ForEach-Object { $_.Name })
    return @{ Deleted = $deleted; Skipped = $skipped; Freed = $freed; Disabled = $disabled;
        DisabledApps = $allDisabledApps; DisabledNames = $disabledNames;
        RestorePointCreated = $restorePointCreated; RecycleEmptied = $recycleEmptied;
        RecycleItems = $recycleItems; DnsFlushed = $dnsFlushed; ScoreBefore = $scoreBefore }
}

# ---------------------------------------------------------------------------
# Console mode
#   ProFix.ps1 -DiagnoseOnly   (scan only, deletes nothing)
#   ProFix.ps1 -AutoFix        (silent, Junk + DNS only - no Recycle Bin,
#                                no startup changes, restore point if admin)
# ---------------------------------------------------------------------------
if ($DiagnoseOnly) {
    Write-Host ("ProFix v{0} - console diagnose (nothing will be changed)" -f $script:AppVersion) -ForegroundColor Cyan
    Write-Host ("Admin: {0}" -f $script:IsAdmin)
    $diag = Invoke-ProFixDiagnose
    Write-Host ("`nHealth Score: {0} - {1}" -f $diag.Score, $diag.Grade) -ForegroundColor Green
    Write-Host ("System Health: {0} / 75  |  Hardware Health: {1} / 25" -f $diag.SoftwareScore, $diag.HardwareScore)
    if ($diag.CapReason) { Write-Host ("CAP: {0}" -f $diag.CapReason) -ForegroundColor Red }
    Write-Host ("1-Click Fix se +{0} points turant badhenge." -f $diag.InstantFixable)
    Write-Host $diag.Verdict
    foreach ($d in $script:Diagnostics) {
        $it = $diag.Items[$d.Id]
        Write-Host ("- {0}: {1} | {2} | Fix: {3}" -f $it.Name, $it.Status, $it.Detail, $it.Fix)
    }
    Write-Host ("Log: {0}" -f $script:LogPath)
    exit 0
}

if ($AutoFix) {
    Write-Host ("ProFix v{0} - AutoFix mode (silent, Junk + DNS only)" -f $script:AppVersion) -ForegroundColor Cyan
    Write-Host ("Admin: {0}" -f $script:IsAdmin)
    Write-ProFixLog ("ProFix v{0} - AutoFix started." -f $script:AppVersion)
    $diagBefore = Invoke-ProFixDiagnose
    $scoreBeforeAuto = $diagBefore.Score
    $gradeBeforeAuto = $diagBefore.Grade
    $softwareBeforeAuto = $diagBefore.SoftwareScore
    $hardwareBeforeAuto = $diagBefore.HardwareScore
    # AutoFix fixes Junk + DNS only. Recycle Bin is NOT emptied silently and
    # no startup app is disabled silently.
    $res = Invoke-ProFixFix -SelectedIds @('Junk') -MakeRestorePoint $script:IsAdmin -ConfirmRecycleBin $false
    try {
        $out = & ipconfig /flushdns 2>&1 | Out-String
        $res.DnsFlushed = $true
        Write-ProFixLog ('DNS cache flushed. ' + ($out.Trim() -replace '\s+', ' '))
    } catch {
        Write-ProFixLog ('DNS flush failed: ' + $_.Exception.Message)
    }
    [void](Write-ProFixRestoreJson -ScoreBefore $scoreBeforeAuto -GradeBefore $gradeBeforeAuto -FixResult $res -SoftwareBefore $softwareBeforeAuto -HardwareBefore $hardwareBeforeAuto)
    $afterDiag = Invoke-ProFixDiagnose
    $reportPath = New-ProFixBeforeAfterReport -ScoreBefore $scoreBeforeAuto -GradeBefore $gradeBeforeAuto -FixResult $res -AfterDiagnosis $afterDiag -SoftwareBefore $softwareBeforeAuto -HardwareBefore $hardwareBeforeAuto
    Write-Host ("Fix done: {0} files deleted ({1} freed), {2} skipped." -f $res.Deleted, (Format-Size $res.Freed), $res.Skipped) -ForegroundColor Green
    Write-Host ("Health Score: {0} -> {1}  (System {2}/75 + Hardware {3}/25 -> System {4}/75 + Hardware {5}/25)" -f $scoreBeforeAuto, $afterDiag.Score, $softwareBeforeAuto, $hardwareBeforeAuto, $afterDiag.SoftwareScore, $afterDiag.HardwareScore)
    Write-Host ("Report: {0}" -f $reportPath)
    Write-Host ("Log: {0}" -f $script:LogPath)
    exit 0
}

# ---------------------------------------------------------------------------
# GUI - Windows Forms (works on Windows PowerShell 5.1, no install needed)
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not $script:IsAdmin) {
    if (-not $PSCommandPath) {
        [System.Windows.Forms.MessageBox]::Show(
            "ProFix was pasted into PowerShell, so it cannot restart as admin.`n`nClose this window and double-click Run-ProFix.bat instead (or right-click ProFix.ps1 - Run with PowerShell).",
            'ProFix', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        exit 0
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "ProFix works best as Administrator (System Restore Point needs it).`n`nRestart as administrator now?",
        'ProFix', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath)
        exit 0
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "ProFix v$script:AppVersion - Slow PC Doctor"
$form.ClientSize = New-Object System.Drawing.Size(680, 702)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$icoPath = Join-Path $PSScriptRoot 'ProFix.ico'
if ($icoPath -and (Test-Path -LiteralPath $icoPath)) {
    try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch { }
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "ProFix v$script:AppVersion - Slow PC Doctor"
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(12, 10)
$lblTitle.Size = New-Object System.Drawing.Size(656, 26)
$form.Controls.Add($lblTitle)

$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.Text = if ($script:IsAdmin) { 'Running as Administrator - all features available.' } else { 'Not running as Administrator - System Restore Point is disabled.' }
$lblAdmin.ForeColor = if ($script:IsAdmin) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
$lblAdmin.Location = New-Object System.Drawing.Point(12, 38)
$lblAdmin.Size = New-Object System.Drawing.Size(656, 18)
$form.Controls.Add($lblAdmin)

$script:lblScore = New-Object System.Windows.Forms.Label
$script:lblScore.Text = 'Health Score: --  Press Diagnose to check your PC.'
$script:lblScore.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$script:lblScore.Location = New-Object System.Drawing.Point(12, 62)
$script:lblScore.Size = New-Object System.Drawing.Size(656, 28)
$form.Controls.Add($script:lblScore)

$script:lblSystemHealth = New-Object System.Windows.Forms.Label
$script:lblSystemHealth.Text = 'System Health: -- / 75'
$script:lblSystemHealth.Location = New-Object System.Drawing.Point(12, 92)
$script:lblSystemHealth.Size = New-Object System.Drawing.Size(200, 16)
$form.Controls.Add($script:lblSystemHealth)

$script:barSystem = New-Object System.Windows.Forms.ProgressBar
$script:barSystem.Location = New-Object System.Drawing.Point(212, 92)
$script:barSystem.Size = New-Object System.Drawing.Size(180, 16)
$script:barSystem.Minimum = 0; $script:barSystem.Maximum = 75; $script:barSystem.Value = 0
$form.Controls.Add($script:barSystem)

$script:lblHardwareHealth = New-Object System.Windows.Forms.Label
$script:lblHardwareHealth.Text = 'Hardware Health: -- / 25'
$script:lblHardwareHealth.Location = New-Object System.Drawing.Point(402, 92)
$script:lblHardwareHealth.Size = New-Object System.Drawing.Size(200, 16)
$form.Controls.Add($script:lblHardwareHealth)

$script:barHardware = New-Object System.Windows.Forms.ProgressBar
$script:barHardware.Location = New-Object System.Drawing.Point(602, 92)
$script:barHardware.Size = New-Object System.Drawing.Size(66, 16)
$script:barHardware.Minimum = 0; $script:barHardware.Maximum = 25; $script:barHardware.Value = 0
$form.Controls.Add($script:barHardware)

$script:listView = New-Object System.Windows.Forms.ListView
$script:listView.View = 'Details'
$script:listView.FullRowSelect = $true
$script:listView.GridLines = $true
$script:listView.CheckBoxes = $true
$script:listView.Location = New-Object System.Drawing.Point(12, 114)
$script:listView.Size = New-Object System.Drawing.Size(656, 192)
[void]$script:listView.Columns.Add('Issue', 150)
[void]$script:listView.Columns.Add('Status', 80)
[void]$script:listView.Columns.Add('Detail', 220)
[void]$script:listView.Columns.Add('Recommended Fix', 190)
$form.Controls.Add($script:listView)

$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = 'Create a System Restore Point before fixing (recommended)'
$chkRestore.Checked = $script:IsAdmin
$chkRestore.Enabled = $script:IsAdmin
$chkRestore.Location = New-Object System.Drawing.Point(12, 316)
$chkRestore.Size = New-Object System.Drawing.Size(656, 22)
$form.Controls.Add($chkRestore)

$btnDiagnose = New-Object System.Windows.Forms.Button
$btnDiagnose.Text = 'Diagnose'
$btnDiagnose.Location = New-Object System.Drawing.Point(12, 344)
$btnDiagnose.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnDiagnose)

$btnFix = New-Object System.Windows.Forms.Button
$btnFix.Text = 'Fix Selected'
$btnFix.Enabled = $false
$btnFix.Location = New-Object System.Drawing.Point(122, 344)
$btnFix.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnFix)

$script:btnUndo = New-Object System.Windows.Forms.Button
$script:btnUndo.Text = 'Undo Last Fix'
$script:btnUndo.Enabled = $false
$script:btnUndo.Location = New-Object System.Drawing.Point(452, 344)
$script:btnUndo.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($script:btnUndo)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = 'Select All'
$btnSelectAll.Location = New-Object System.Drawing.Point(232, 344)
$btnSelectAll.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnSelectAll)

$btnClearAll = New-Object System.Windows.Forms.Button
$btnClearAll.Text = 'Clear All'
$btnClearAll.Location = New-Object System.Drawing.Point(342, 344)
$btnClearAll.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnClearAll)

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point(12, 384)
$script:progressBar.Size = New-Object System.Drawing.Size(656, 20)
$script:progressBar.Minimum = 0; $script:progressBar.Maximum = 100; $script:progressBar.Value = 0
$form.Controls.Add($script:progressBar)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Location = New-Object System.Drawing.Point(12, 414)
$script:txtLog.Size = New-Object System.Drawing.Size(656, 240)
$form.Controls.Add($script:txtLog)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready. Press Diagnose to check your PC.'
$lblStatus.Location = New-Object System.Drawing.Point(12, 664)
$lblStatus.Size = New-Object System.Drawing.Size(656, 18)
$form.Controls.Add($lblStatus)
$script:lblStatus = $lblStatus

function Update-UndoButton {
    try { $script:btnUndo.Enabled = (Test-ProFixUndoAvailable) } catch { $script:btnUndo.Enabled = $false }
}

function Get-SelectedIds {
    $ids = @()
    foreach ($item in $script:listView.Items) {
        if ($item.Checked) { $ids += $item.Tag }
    }
    return $ids
}

function Update-ResultsList {
    $script:Populating = $true
    $script:listView.Items.Clear()
    foreach ($d in $script:Diagnostics) {
        if (-not $script:Diagnosis.Items.ContainsKey($d.Id)) { continue }
        $it = $script:Diagnosis.Items[$d.Id]
        $row = New-Object System.Windows.Forms.ListViewItem($it.Name)
        $row.Tag = $d.Id
        $row.Checked = $d.DefaultFix
        [void]$row.SubItems.Add($it.Status)
        [void]$row.SubItems.Add($it.Detail)
        [void]$row.SubItems.Add($it.Fix)
        [void]$script:listView.Items.Add($row)
    }
    $script:Populating = $false
}

function Show-DetailDialog {
    param([string]$DiagId)
    if ($null -eq $script:Diagnosis) { return }
    $item = $script:Diagnosis.Items[$DiagId]
    if (-not $item) { return }

    if ($DiagId -eq 'Junk') {
        $files = @($script:JunkFiles | Sort-Object Length -Descending | Select-Object -First 250)
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'ProFix - Junk Files (largest files)'
        $dlg.ClientSize = New-Object System.Drawing.Size(760, 480)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $lv = New-Object System.Windows.Forms.ListView
        $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
        $lv.Location = New-Object System.Drawing.Point(12, 12); $lv.Size = New-Object System.Drawing.Size(736, 400)
        [void]$lv.Columns.Add('File Path', 430); [void]$lv.Columns.Add('Size', 110); [void]$lv.Columns.Add('Last Modified', 170)
        foreach ($f in $files) {
            $row = New-Object System.Windows.Forms.ListViewItem($f.FullName)
            [void]$row.SubItems.Add((Format-Size $f.Length))
            [void]$row.SubItems.Add($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
            [void]$lv.Items.Add($row)
        }
        $dlg.Controls.Add($lv)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = if ($files.Count -eq 0) { 'No junk files found.' } else { "Top {0} largest files - read only, nothing is deleted here." -f $files.Count }
        $lbl.Location = New-Object System.Drawing.Point(12, 424); $lbl.Size = New-Object System.Drawing.Size(736, 18)
        $dlg.Controls.Add($lbl)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = 'Close'; $btnClose.Location = New-Object System.Drawing.Point(648, 444); $btnClose.Size = New-Object System.Drawing.Size(100, 28)
        $btnClose.Add_Click({ $dlg.Close() }); $dlg.Controls.Add($btnClose); $dlg.AcceptButton = $btnClose
        [void]$dlg.ShowDialog($form)
        return
    }

    if ($DiagId -eq 'Startup') {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'ProFix - Startup Apps (pick HKCU Run apps to disable)'
        $dlg.ClientSize = New-Object System.Drawing.Size(760, 480)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $lblInfo = New-Object System.Windows.Forms.Label
        $lblInfo.Text = 'Tick the apps to disable. Only HKCU Run apps can be disabled in v1 (reversible - backed up to HKCU\Software\ProFix\DisabledStartup). HKLM Run and Startup Folder apps are shown for info only and cannot be ticked here.'
        $lblInfo.Location = New-Object System.Drawing.Point(12, 12); $lblInfo.Size = New-Object System.Drawing.Size(736, 36)
        $dlg.Controls.Add($lblInfo)
        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.CheckOnClick = $true
        $clb.Location = New-Object System.Drawing.Point(12, 54); $clb.Size = New-Object System.Drawing.Size(736, 360)
        foreach ($a in $script:StartupApps) {
            $idx = $clb.Items.Add(('{0}  [{1}]  {2}' -f $a.Name, $a.Location, $a.Command))
            if ($a.Location -eq 'HKCU Run') {
                $clb.SetItemChecked($idx, $script:StartupDisable.ContainsKey($a.Name) -and $script:StartupDisable[$a.Name])
            } else {
                # Info-only rows cannot be ticked in v1 - CheckedListBox has no
                # per-item disable, so they start unchecked and are reverted
                # on OK if the user ticks one by mistake.
            }
        }
        $dlg.Controls.Add($clb)
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'OK - Save Selection'; $btnOk.Location = New-Object System.Drawing.Point(548, 428); $btnOk.Size = New-Object System.Drawing.Size(200, 28)
        $btnOk.Add_Click({
            for ($i = 0; $i -lt $clb.Items.Count; $i++) {
                $a = $script:StartupApps[$i]
                if ($a.Location -eq 'HKCU Run') { $script:StartupDisable[$a.Name] = $clb.GetItemChecked($i) }
            }
            $dlg.Close()
        })
        $dlg.Controls.Add($btnOk); $dlg.AcceptButton = $btnOk
        [void]$dlg.ShowDialog($form)
        return
    }

    # All other diagnostics: plain explanation dialog
    $text = @"
{0}
Status: {1}
Detail: {2}
Recommended fix: {3}
Score: {4} / {5} points
1-Click Fix se +{6} points turant badhenge.

{7}
"@ -f $item.Name, $item.Status, $item.Detail, $item.Fix, $item.Points, $item.MaxPoints, $script:Diagnosis.InstantFixable, $script:Diagnosis.Verdict
    [System.Windows.Forms.MessageBox]::Show($text, "ProFix - $($item.Name)", 'OK', 'Information') | Out-Null
}

$script:listView.Add_DoubleClick({
    if ($script:listView.SelectedItems.Count -eq 0) { return }
    Show-DetailDialog -DiagId $script:listView.SelectedItems[0].Tag
})

# Any tick change after a Diagnose makes the preview stale - force re-Diagnose.
$script:listView.Add_ItemChecked({
    if ($script:Populating) { return }
    $btnFix.Enabled = $false
    if ($script:lblStatus) { $script:lblStatus.Text = 'Selection changed - press Diagnose to refresh preview.' }
})

$btnSelectAll.Add_Click({
    $script:Populating = $true
    foreach ($item in $script:listView.Items) { $item.Checked = $true }
    $script:Populating = $false
    $btnFix.Enabled = $false
    $script:lblStatus.Text = 'Selection changed - press Diagnose to refresh preview.'
})
$btnClearAll.Add_Click({
    $script:Populating = $true
    foreach ($item in $script:listView.Items) { $item.Checked = $false }
    $script:Populating = $false
    $btnFix.Enabled = $false
    $script:lblStatus.Text = 'Selection changed - press Diagnose to refresh preview.'
})

$script:btnUndo.Add_Click({
    $entries = @(Get-ProFixRestorableEntries)
    if ($entries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No undo available - no startup apps were disabled by the last fix, or the restore backup is missing or corrupt.', 'ProFix - Undo Last Fix', 'OK', 'Information') | Out-Null
        Update-UndoButton
        return
    }
    $names = (($entries | ForEach-Object { $_.Name }) -join ', ')
    $ok = [System.Windows.Forms.MessageBox]::Show(
        ("Restore these startup apps disabled by the last fix?`n`n{0}`n`nDeleted junk files cannot be restored - use the System Restore Point created before fixing if needed." -f $names),
        'ProFix - Undo Last Fix', 'YesNo', 'Question')
    if ($ok -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $result = Invoke-ProFixUndo
    Update-UndoButton
    if ($result.Restored -gt 0) {
        try {
            $diag = Invoke-ProFixDiagnose
            Update-ResultsList
            Update-ScoreDisplay -Diag $diag
            $script:lblStatus.Text = ('Undo done - re-diagnosed: {0} - {1}.' -f $diag.Score, $diag.Grade)
            $btnFix.Enabled = $true
        } catch {
            Write-ProFixLog ('Re-diagnose after undo failed: ' + $_.Exception.Message)
        }
    }
    [System.Windows.Forms.MessageBox]::Show(
        ("Restored {0} startup apps. Deleted junk files cannot be restored - use the System Restore Point created before fixing if needed.`n`nFailed: {1}" -f $result.Restored, $result.Failed),
        'ProFix - Undo', 'OK', 'Information') | Out-Null
})

$btnDiagnose.Add_Click({
    $btnDiagnose.Enabled = $false; $btnFix.Enabled = $false
    $script:progressBar.Value = 0
    $script:lblStatus.Text = 'Diagnosing... measuring CPU/RAM (3-5 sec average)'
    [System.Windows.Forms.Application]::DoEvents()
    $script:txtLog.Clear()
    Write-ProFixLog ("ProFix v{0} - diagnose started." -f $script:AppVersion)
    try {
        $diag = Invoke-ProFixDiagnose
        Update-ResultsList
        Update-ScoreDisplay -Diag $diag
        $script:lblStatus.Text = ('Diagnosed: {0} - {1} (System {2}/75 + Hardware {3}/25). 1-Click Fix se +{4} points turant badhenge. Tick issues, then press Fix Selected.' -f $diag.Score, $diag.Grade, $diag.SoftwareScore, $diag.HardwareScore, $diag.InstantFixable)
        $btnFix.Enabled = $true
        Update-UndoButton
    } catch {
        $script:lblStatus.Text = ('Diagnose failed: ' + $_.Exception.Message)
        Write-ProFixLog ('Diagnose failed: ' + $_.Exception.Message)
    } finally {
        $btnDiagnose.Enabled = $true
        $script:progressBar.Value = 0
    }
})

$btnFix.Add_Click({
    if ($null -eq $script:Diagnosis) {
        [System.Windows.Forms.MessageBox]::Show('Press Diagnose first.', 'ProFix', 'OK', 'Information') | Out-Null
        return
    }
    $scoreBefore = $script:Diagnosis.Score
    $gradeBefore = $script:Diagnosis.Grade
    $softwareBefore = $script:Diagnosis.SoftwareScore
    $hardwareBefore = $script:Diagnosis.HardwareScore
    $ids = Get-SelectedIds
    if ($ids.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Tick at least one issue first.', 'ProFix', 'OK', 'Information') | Out-Null
        return
    }
    $msg = "Fix the ticked issues?`n`nJunk files are deleted PERMANENTLY - they do not go to the Recycle Bin.`nStartup apps are disabled (reversible - backed up).`nReview the list above first."
    $ok = [System.Windows.Forms.MessageBox]::Show($msg, 'ProFix - confirm fix', 'YesNo', 'Warning')
    if ($ok -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $confirmBin = $false
    if ($ids -contains 'RecycleDns' -and $script:Diagnosis.RecycleCount -gt 0) {
        $ok2 = [System.Windows.Forms.MessageBox]::Show('Empty the Recycle Bin too? This cannot be undone. (DNS will still be flushed.)', 'ProFix - Recycle Bin', 'YesNo', 'Warning')
        if ($ok2 -eq [System.Windows.Forms.DialogResult]::Yes) { $confirmBin = $true }
    }

    $btnDiagnose.Enabled = $false; $btnFix.Enabled = $false
    $script:lblStatus.Text = 'Fixing...'
    try {
        $res = Invoke-ProFixFix -SelectedIds $ids -MakeRestorePoint $chkRestore.Checked -ConfirmRecycleBin $confirmBin
        [void](Write-ProFixRestoreJson -ScoreBefore $scoreBefore -GradeBefore $gradeBefore -FixResult $res -SoftwareBefore $softwareBefore -HardwareBefore $hardwareBefore)
        $afterDiag = Invoke-ProFixDiagnose
        Update-ResultsList
        Update-ScoreDisplay -Diag $afterDiag
        $reportPath = New-ProFixBeforeAfterReport -ScoreBefore $scoreBefore -GradeBefore $gradeBefore -FixResult $res -AfterDiagnosis $afterDiag -SoftwareBefore $softwareBefore -HardwareBefore $hardwareBefore
        Update-UndoButton
        $btnFix.Enabled = $true
        $script:lblStatus.Text = ('Done: Health Score {0} -> {1}, {2} files deleted ({3} freed), {4} startup apps disabled. Report: {5}' -f $scoreBefore, $afterDiag.Score, $res.Deleted, (Format-Size $res.Freed), $res.Disabled, $reportPath)
        [System.Windows.Forms.MessageBox]::Show(
            ("Fix complete.`n`nHealth Score: {0} -> {1}`nDeleted: {2} files ({3})`nSkipped (in use): {4}`nStartup apps disabled: {5}`n`nReport saved to:`n{6}`n`nLog saved to:`n{7}" -f $scoreBefore, $afterDiag.Score, $res.Deleted, (Format-Size $res.Freed), $res.Skipped, $res.Disabled, $reportPath, $script:LogPath),
            'ProFix', 'OK', 'Information') | Out-Null
    } catch {
        $script:lblStatus.Text = ('Fix failed: ' + $_.Exception.Message)
        Write-ProFixLog ('Fix failed: ' + $_.Exception.Message)
    } finally {
        $btnDiagnose.Enabled = $true
        $script:progressBar.Value = 0
    }
})

Write-ProFixLog ("ProFix v{0} started." -f $script:AppVersion)
Update-UndoButton
[void]$form.ShowDialog()
