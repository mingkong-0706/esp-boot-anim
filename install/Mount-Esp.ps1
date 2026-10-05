<#
.SYNOPSIS
  临时挂载 / 卸载 EFI 系统分区（ESP），方便改 bootanim.cfg。

.DESCRIPTION
  ESP 平时是没有盘符的，想改 \EFI\BootAnim\bootanim.cfg 就得先挂载。
  这个脚本就是干这个的，用法：

    # 挂载（默认用 E:）
    .\Mount-Esp.ps1

    # 挂到别的盘符
    .\Mount-Esp.ps1 -Letter S

    # 改完配置后卸载
    .\Mount-Esp.ps1 -Unmount

  需要管理员权限。

.PARAMETER Letter
  要使用的盘符（单个字母，不带冒号）。默认 E。

.PARAMETER Unmount
  反向操作：卸载之前挂上的盘符。

.EXAMPLE
  .\Mount-Esp.ps1
  notepad E:\EFI\BootAnim\bootanim.cfg
  .\Mount-Esp.ps1 -Unmount

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [string]$Letter = 'E',
    [switch]$Unmount
)

. (Join-Path $PSScriptRoot 'EspTools.ps1')

Write-Head 'ESP 挂载工具'
Assert-Admin

$espGpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$letter = ([string]$Letter).TrimEnd(':', '\', '/').ToUpperInvariant()
if ($letter.Length -ne 1 -or $letter -lt 'D' -or $letter -gt 'Z') {
    Write-Err "盘符必须是 D~Z 之间的单个字母，收到的是 [$Letter]"
    exit 2
}

$part = $null
try {
    foreach ($q in @(Get-Partition -ErrorAction Stop)) {
        if ($q.GptType -eq $espGpt) { $part = $q; break }
    }
} catch {
    $part = $null
}
if (-not $part) {
    Write-Err '没有找到 EFI 系统分区（ESP）。'
    exit 3
}

if ($Unmount) {
    $done = $false
    foreach ($ap in @("${letter}:\", "${letter}:")) {
        try {
            Remove-PartitionAccessPath -DiskNumber $part.DiskNumber `
                                       -PartitionNumber $part.PartitionNumber `
                                       -AccessPath $ap -ErrorAction Stop
            $done = $true
            break
        } catch {
            $done = $false
        }
    }
    if ($done) {
        Write-Ok "已卸载 ${letter}:"
    } else {
        Write-Warn2 "${letter}: 本来就没挂载，或卸载失败（重启后会自动消失）"
    }
    exit 0
}

if ([System.IO.Directory]::Exists("${letter}:\")) {
    Write-Warn2 "${letter}: 已经被别的卷占用了，换一个盘符：.\Mount-Esp.ps1 -Letter S"
    exit 4
}

$done = $false
foreach ($ap in @("${letter}:", "${letter}:\")) {
    try {
        Add-PartitionAccessPath -DiskNumber $part.DiskNumber `
                                -PartitionNumber $part.PartitionNumber `
                                -AccessPath $ap -ErrorAction Stop
        $done = $true
        break
    } catch {
        $done = $false
    }
}
if (-not $done) {
    Write-Err "挂载 ${letter}: 失败"
    exit 5
}
for ($i = 0; $i -lt 20; $i++) {
    if ([System.IO.Directory]::Exists("${letter}:\")) { break }
    Start-Sleep -Milliseconds 200
}
if (-not [System.IO.Directory]::Exists("${letter}:\")) {
    Write-Err "挂载后仍然访问不到 ${letter}:"
    exit 5
}

Write-Ok "ESP 已挂载到 ${letter}:"
Write-Host ''
Write-Host "  配置文件 : ${letter}:\EFI\BootAnim\bootanim.cfg"
Write-Host "  程序     : ${letter}:\EFI\BootAnim\bootanim.efi"
Write-Host "  动画数据 : ${letter}:\EFI\BootAnim\anim.baa"
Write-Host "  原版引导 : ${letter}:\EFI\Microsoft\Boot\bootmgfw-orig.efi"
Write-Host ''
if ([System.IO.File]::Exists("${letter}:\EFI\BootAnim\bootanim.cfg")) {
    Write-Host "  当前配置内容："
    Get-Content -LiteralPath "${letter}:\EFI\BootAnim\bootanim.cfg" -Encoding UTF8 |
        Where-Object { $_ -match '^\s*[^#\s]' } |
        ForEach-Object { Write-Host "    $_" }
}
Write-Host ''
Write-Ok "编辑完记得卸载：.\Mount-Esp.ps1 -Letter $letter -Unmount"
