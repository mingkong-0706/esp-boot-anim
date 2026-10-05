<#
.SYNOPSIS
  BootAnim 安装/卸载脚本的公共函数。

.DESCRIPTION
  被 Install-BootAnim.ps1 / Uninstall-BootAnim.ps1 点源（dot-source）加载。
  提供：提权检查、ESP 定位与临时挂载、shim 标记识别、安全复制。

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 我们编译出来的 bootanim.efi 里固定含有这个 ASCII 字符串
# （见 src/BootAnim.c 的 gBaMarkerA），用来判断 ESP 上的
# bootmgfw.efi 到底是"微软原版"还是"已经被替换成了我们的 shim"。
$script:BootAnimMarker = 'BOOTANIM-EFI-LOADER-MARKER'

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "  [错误] $Text" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err '必须用【管理员】身份运行 PowerShell。'
        Write-Host '        右键开始菜单 -> 终端(管理员) / Windows PowerShell(管理员)'
        exit 1
    }
}

# ESP 的 GPT 分区类型 GUID（在 Where-Object 里直接写字面量，
# 不要包成函数，否则 $_ 的作用域会出问题）
$script:EspGptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

<#
.SYNOPSIS
  找到一个可以正常访问的目录路径。

.DESCRIPTION
  不能用 Test-Path：
    * PowerShell 5.1 的 FileSystem provider 不接受 \\?\Volume{...}\ 这种路径，
      会直接报「无法处理参数，因为参数"path"的值无效」；
    * Test-Path "Q:\"（盘符不存在）会向错误流写一条错误，而本脚本全局设了
      $ErrorActionPreference='Stop'，于是会变成异常。
  .NET 的 Directory.Exists 两个问题都没有，所以统一走它。
#>
function Test-DirExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

<#
.SYNOPSIS
  找到一个空闲盘符（D..Z 里第一个不能访问的）。

.NOTES
  用 .NET 判断，不用 Test-Path —— 见 Test-DirExists 的说明。
#>
function Get-FreeDriveLetter {
    foreach ($c in 68..90) {                  # D..Z
        $l = [string][char]$c
        if (-not [System.IO.Directory]::Exists("${l}:\")) { return $l }
    }
    return $null
}

<#
.SYNOPSIS
  找到 ESP 并返回一个可直接使用的根路径（形如 'S:\'）。

.OUTPUTS
  PSCustomObject: Path / AssignedLetter / DiskNumber / PartitionNumber
  若临时分配了盘符，收尾时要用 Remove-EspAccess 释放。
#>
function Get-EspRoot {
    param([string]$DriveLetter = '')

    $espGpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

    # 1) 用户手动指定
    if ($DriveLetter) {
        $d = ([string]$DriveLetter).TrimEnd(':', '\', '/')
        $p = "${d}:\"
        if (-not (Test-DirExists $p)) {
            throw "指定的盘符 $p 不存在或不可访问。"
        }
        return [PSCustomObject]@{
            Path = $p; AssignedLetter = $null; DiskNumber = $null; PartitionNumber = $null
        }
    }

    # 2) 自动探测 ESP 分区
    $part = $null
    try {
        foreach ($q in @(Get-Partition -ErrorAction Stop)) {
            if ($q.GptType -eq $espGpt) { $part = $q; break }
        }
    } catch {
        $part = $null
    }
    if (-not $part) {
        throw '没有找到 EFI 系统分区（ESP）。请用 -EspDrive S 手动指定已挂载的 ESP 盘符。'
    }

    $vol = $null
    try { $vol = Get-Volume -Partition $part -ErrorAction Stop } catch { $vol = $null }
    if (-not $vol) {
        try { $vol = $part | Get-Volume -ErrorAction Stop } catch { $vol = $null }
    }

    # 2a) 已经有盘符，直接用
    if ($vol -and $vol.DriveLetter) {
        $p = "$($vol.DriveLetter):\"
        if (Test-DirExists $p) {
            return [PSCustomObject]@{
                Path = $p; AssignedLetter = $null
                DiskNumber = $part.DiskNumber; PartitionNumber = $part.PartitionNumber
            }
        }
    }

    # 2b) 没有盘符：临时分配一个。
    #     刻意不用 \\?\Volume{...}\ —— PowerShell 5.1 的 provider 处理不了它，
    #     连后面的 Copy-Item / New-Item 都会一起失败。分配盘符最稳。
    $letter = Get-FreeDriveLetter
    if (-not $letter) {
        throw '没有空闲盘符可以分配给 ESP。请先在磁盘管理里给 ESP 分配一个盘符，再用 -EspDrive 指定。'
    }
    $ok = $false
    foreach ($ap in @("${letter}:", "${letter}:\")) {
        try {
            Add-PartitionAccessPath -DiskNumber $part.DiskNumber `
                                    -PartitionNumber $part.PartitionNumber `
                                    -AccessPath $ap -ErrorAction Stop
            $ok = $true
            break
        } catch {
            $ok = $false
        }
    }
    if (-not $ok) {
        throw "分配盘符 $letter 失败（Add-PartitionAccessPath 出错）。请手工在磁盘管理里给 ESP 分配盘符，再用 -EspDrive 指定。"
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-DirExists "${letter}:\") { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-DirExists "${letter}:\")) {
        throw "分配盘符 $letter 后仍然访问不到 ESP。"
    }
    Write-Warn2 "临时给 ESP 分配了盘符 $letter（结束时会自动撤销）"
    return [PSCustomObject]@{
        Path = "${letter}:\"; AssignedLetter = $letter
        DiskNumber = $part.DiskNumber; PartitionNumber = $part.PartitionNumber
    }
}

function Remove-EspAccess {
    param($Esp)
    if ($Esp -and $Esp.AssignedLetter) {
        $done = $false
        foreach ($ap in @("$($Esp.AssignedLetter):\", "$($Esp.AssignedLetter):")) {
            try {
                Remove-PartitionAccessPath -DiskNumber $Esp.DiskNumber `
                                           -PartitionNumber $Esp.PartitionNumber `
                                           -AccessPath $ap -ErrorAction Stop
                $done = $true
                break
            } catch {
                $done = $false
            }
        }
        if ($done) {
            Write-Host "  (已撤销临时盘符 $($Esp.AssignedLetter))"
        } else {
            Write-Warn2 "撤销临时盘符失败（重启后会自动消失，也可以到磁盘管理里手工移除）"
        }
    }
}

<#
.SYNOPSIS
  在字节数组里查找一个字节序列，返回下标，找不到返回 -1。
#>
function Find-Bytes {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if (-not $Needle -or $Needle.Length -eq 0) { return -1 }
    if (-not $Haystack -or $Haystack.Length -lt $Needle.Length) { return -1 }
    $limit = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        if ($Haystack[$i] -ne $Needle[0]) { continue }
        $ok = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    return -1
}

<#
.SYNOPSIS
  判断某个 .efi 文件是不是我们编译的 BootAnim（靠内嵌标记）。
#>
function Test-IsBootAnimLoader {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        return $false
    }
    # 先看是不是 PE 文件
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return $false }
    $needle = [Text.Encoding]::ASCII.GetBytes($script:BootAnimMarker)
    return ((Find-Bytes -Haystack $bytes -Needle $needle) -ge 0)
}

<#
.SYNOPSIS
  安全复制文件（先写 .tmp 再改名，避免断电/中断留下半个文件）。
#>
function Copy-FileSafe {
    param([string]$Source, [string]$Dest)
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "源文件不存在: $Source"
    }
    $dir = Split-Path -Parent $Dest
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Dest.tmp"
    Copy-Item -LiteralPath $Source -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $Dest -Force
}

function Get-BitLockerState {
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        return $v.ProtectionStatus
    } catch {
        return 'Unknown'
    }
}

function Show-BitLockerAdvice {
    $st = Get-BitLockerState
    if ($st -eq 'On') {
        Write-Warn2 'BitLocker 处于开启状态。'
        Write-Host '        修改 ESP 上的引导程序通常不会触发恢复密钥，但为了万全，'
        Write-Host '        建议先执行:  Suspend-BitLocker -MountPoint C: -RebootCount 1'
        Write-Host '        重启一次让改动生效后，BitLocker 会自动重新开启保护。'
    }
}
