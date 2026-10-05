<#
.SYNOPSIS
  卸载 BootAnim，把 ESP 恢复成原样。

.DESCRIPTION
  1. 定位 ESP
  2. 如果 \EFI\Microsoft\Boot\bootmgfw.efi 是我们的 shim，就用
     bootmgfw-orig.efi 还原它
  3. 如果曾经替换过 \EFI\Boot\bootx64.efi，同样还原
  4. 删除 \EFI\BootAnim\ 目录

  安全设计：如果发现 bootmgfw.efi 是我们的程序、但找不到可用的
  bootmgfw-orig.efi，脚本会拒绝删除 shim（否则机器将无法启动），
  只清理素材目录并给出修复方法。

.PARAMETER EspDrive
  已经挂载好的 ESP 盘符，例如 S 。不指定则自动探测。

.PARAMETER KeepAssets
  只还原引导程序，保留 \EFI\BootAnim\ 里的素材（方便下次再装）。

.PARAMETER DryRun
  只打印将要执行的操作。

.EXAMPLE
  cd <项目目录>\install
  .\Uninstall-BootAnim.ps1 -DryRun
  .\Uninstall-BootAnim.ps1

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [string]$EspDrive = '',
    [switch]$KeepAssets,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'EspTools.ps1')

Write-Head 'BootAnim 卸载程序'
Assert-Admin

$esp = $null
try {
    $esp = Get-EspRoot -DriveLetter $EspDrive
} catch {
    Write-Err $_.Exception.Message
    exit 3
}
$root = $esp.Path
Write-Ok "ESP = $root"

$mainDir     = Join-Path $root 'EFI\BootAnim'
$winBootDir  = Join-Path $root 'EFI\Microsoft\Boot'
$shimPath    = Join-Path $winBootDir 'bootmgfw.efi'
$origPath    = Join-Path $winBootDir 'bootmgfw-orig.efi'
$fbPath      = Join-Path $root 'EFI\Boot\bootx64.efi'
$fbOrig      = Join-Path $root 'EFI\Boot\bootx64-orig.efi'

$exitCode = 0

try {
    # ---------------------------------------------------------- bootmgfw
    Write-Head '还原 Windows 引导程序'

    $shimIsOurs = Test-IsBootAnimLoader -Path $shimPath
    $origExists = Test-Path -LiteralPath $origPath

    if (-not (Test-Path -LiteralPath $shimPath)) {
        Write-Warn2 "没有找到 $shimPath，跳过"
    } elseif (-not $shimIsOurs) {
        Write-Ok 'bootmgfw.efi 不是 BootAnim，无需还原'
    } elseif (-not $origExists) {
        Write-Err 'bootmgfw.efi 是 BootAnim，但找不到 bootmgfw-orig.efi。'
        Write-Host '        为避免机器无法启动，不会删除这个 shim。'
        Write-Host ''
        Write-Host '        修复办法（任选其一）：'
        Write-Host '          a) 用 Windows 安装 U 盘启动 -> 修复计算机 -> 命令提示符：'
        Write-Host '             bcdboot C:\Windows /s S: /f UEFI'
        Write-Host '          b) 从另一台电脑复制一份 bootmgfw.efi 到 ESP 的'
        Write-Host '             \EFI\Microsoft\Boot\ 下覆盖'
        $exitCode = 6
    } elseif (Test-IsBootAnimLoader -Path $origPath) {
        Write-Err 'bootmgfw-orig.efi 也是 BootAnim（备份被覆盖了），拒绝还原。'
        $exitCode = 6
    } else {
        if ($DryRun) {
            Write-Host "  - 复制 $origPath -> $shimPath"
        } else {
            Copy-FileSafe -Source $origPath -Dest $shimPath
            if ((Test-IsBootAnimLoader -Path $shimPath) -or
                (-not (Test-Path -LiteralPath $shimPath))) {
                Write-Err '还原后校验失败，请用 Windows 恢复环境执行 bcdboot。'
                $exitCode = 7
            } else {
                Write-Ok 'bootmgfw.efi 已还原为原始引导程序'
                Remove-Item -LiteralPath $origPath -Force
                Write-Ok '已删除 bootmgfw-orig.efi'
            }
        }
    }

    # ---------------------------------------------------------- bootx64
    if (Test-Path -LiteralPath $fbPath) {
        Write-Head '可移动设备默认路径'
        if (Test-IsBootAnimLoader -Path $fbPath) {
            if (Test-Path -LiteralPath $fbOrig) {
                if ($DryRun) {
                    Write-Host "  - 复制 $fbOrig -> $fbPath"
                } else {
                    Copy-FileSafe -Source $fbOrig -Dest $fbPath
                    Remove-Item -LiteralPath $fbOrig -Force
                    Write-Ok 'bootx64.efi 已还原'
                }
            } else {
                Write-Warn2 "$fbPath 是 BootAnim 但没有备份，跳过（不影响 Windows 启动）"
            }
        } else {
            Write-Ok 'bootx64.efi 不是 BootAnim，无需处理'
        }
    }

    # ---------------------------------------------------------- 素材目录
    if ($KeepAssets) {
        Write-Head '保留素材目录'
        Write-Host "  - 按要求保留 $mainDir"
    } elseif (Test-Path -LiteralPath $mainDir) {
        Write-Head '删除素材目录'
        if ($DryRun) {
            Write-Host "  - 删除 $mainDir"
        } else {
            Remove-Item -LiteralPath $mainDir -Recurse -Force
            Write-Ok "已删除 $mainDir"
        }
    } else {
        Write-Head '素材目录'
        Write-Host "  - $mainDir 不存在，无需处理"
    }

    Write-Head '卸载完成'
    if ($exitCode -eq 0) {
        Write-Ok '下次开机会直接进入 Windows，不再播放动画。'
    } else {
        Write-Warn2 '有一部分内容没有清理干净，请看上面的提示。'
    }
} finally {
    Remove-EspAccess -Esp $esp
}

exit $exitCode
