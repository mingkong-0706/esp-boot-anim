<#
.SYNOPSIS
  卸载通过 Install-App.ps1 安装的 BootAnim 应用。

.DESCRIPTION
  做的事：
    * 读取注册表里的安装位置
    * 删除安装目录
    * 删除开始菜单 / 桌面快捷方式
    * 删除「应用和功能」里的注册项

  注意：**这个脚本只卸载"管理工具"本身**，不会碰你 ESP 上的开机动画。
  要先取消引导接管，请用界面里的「卸载（还原原版引导）」，
  或者手动跑 install\Uninstall-BootAnim.ps1。

.PARAMETER InstallDir
  明确指定安装目录（不指定就从注册表读）。

.PARAMETER KeepFiles
  只删快捷方式和注册项，保留程序文件。

.PARAMETER Quiet
  不打印细节（供「应用和功能」里的静默卸载调用）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\Uninstall-App.ps1

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$KeepFiles,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$AppName = 'BootAnim'
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

function Say([string]$Text, [string]$Color = 'Gray') { if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color } }
function Ok([string]$Text)   { Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Warn2([string]$Text){ Write-Host "  [注意] $Text" -ForegroundColor Yellow }

Say ''
Say '=========================================================' Cyan
Say '  卸载 BootAnim 管理工具' Cyan
Say '=========================================================' Cyan
Say ''

# 正在运行就先关掉
$running = @(Get-Process -Name 'BootAnimGUI' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Warn2 "BootAnimGUI 正在运行（$($running.Count) 个进程），先结束它"
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# 1) 确定安装目录
if (-not $InstallDir) {
    if (Test-Path $regPath) {
        $InstallDir = (Get-ItemProperty -Path $regPath -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
    }
}
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\BootAnim' }
Say "[1/4] 安装目录: $InstallDir"

# 2) 删文件
Say ''
Say '[2/4] 删除程序文件'
if ($KeepFiles) {
    Say '   -KeepFiles 已指定，保留文件'
} elseif (Test-Path -LiteralPath $InstallDir) {
    # 安全检查：别把不该删的目录删了
    $resolved = (Resolve-Path -LiteralPath $InstallDir).Path
    $looksRight = (Test-Path -LiteralPath (Join-Path $resolved 'BootAnimGUI.exe')) -or
                  ($resolved -like '*BootAnim*')
    if (-not $looksRight) {
        Warn2 "「$resolved」看起来不像 BootAnim 的安装目录（里面既没有 BootAnimGUI.exe，路径里也没有 BootAnim）"
        Warn2 '为安全起见不删除。要强制删除请手动删。'
    } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $resolved) {
            Warn2 "没能完全删除 $resolved（可能有文件被占用），请手动清理"
        } else {
            Ok "已删除 $resolved"
        }
    }
} else {
    Say '   目录不存在，跳过'
}

# 3) 删快捷方式
Say ''
Say '[3/4] 删除快捷方式'
$lnks = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk")
)
foreach ($l in $lnks) {
    if (Test-Path -LiteralPath $l) {
        Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
        Ok "已删除 $l"
    }
}

# 4) 删注册项
Say ''
Say '[4/4] 移除「应用和功能」里的注册项'
if (Test-Path $regPath) {
    Remove-Item -Path $regPath -Recurse -Force
    Ok "已删除 $regPath"
} else {
    Say '   注册项不存在，跳过'
}

Say ''
Say '=========================================================' Green
Say '  卸载完成' Green
Say '=========================================================' Green
Say ''
Say '  提醒：这次只卸载了「管理工具」本身。' Yellow
Say '  如果你还在 ESP 上开着引导接管，那个仍然生效。' Yellow
Say '  想一并取消：先装回这个工具用界面里的「卸载（还原原版引导）」，' Yellow
Say '  或者手动跑 install\Uninstall-BootAnim.ps1。' Yellow
Say ''
