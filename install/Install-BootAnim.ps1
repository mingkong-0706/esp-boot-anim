<#
.SYNOPSIS
  把 BootAnim（ESP 开机动画）安装到 EFI 系统分区。

.DESCRIPTION
  做四件事：
    1. 定位 ESP（必要时临时分配盘符，结束时撤销）
    2. 把 bootanim.efi / anim.baa / bootanim.cfg 复制到 \EFI\BootAnim\
    3. 备份 \EFI\Microsoft\Boot\bootmgfw.efi 为 bootmgfw-orig.efi，
       然后把我们的程序放成 bootmgfw.efi（shim 方式，开机即播放动画，
       播完由我们的程序加载原来的 bootmgfw-orig.efi 继续开 Windows）
    4. 校验备份与安装结果

  卸载：bootanim 目录下的 Uninstall-BootAnim.ps1

.PARAMETER EspDrive
  已经挂载好的 ESP 盘符，例如 S 。不指定则自动探测。

.PARAMETER Efi
  bootanim.efi 的路径，默认 ..\dist\bootanim.efi

.PARAMETER Anim
  动画数据（anim.baa 或 BMP 序列的第一帧），默认 ..\dist\anim.baa

.PARAMETER Cfg
  配置文件，默认同目录下的 bootanim.cfg

.PARAMETER Frames
  可选：一个装满 BMP 帧的目录（frame0000.bmp ...），会被复制到
  \EFI\BootAnim\frames\

.PARAMETER NoShim
  只复制文件，不接管 bootmgfw.efi。适合你自己用别的方式（UEFI Shell、
  第三方启动管理器、固件启动项）来调用 bootanim.efi。

.PARAMETER AlsoFallbackPath
  同时把 \EFI\Boot\bootx64.efi 也换成我们的程序（先备份成
  bootx64-orig.efi）。只有当你的固件走"可移动设备默认路径"启动时才需要。

.PARAMETER DryRun
  只打印将要执行的操作，不真正修改 ESP。

.EXAMPLE
  # 管理员 PowerShell
  cd <项目目录>\install
  .\Install-BootAnim.ps1

.EXAMPLE
  .\Install-BootAnim.ps1 -EspDrive S -DryRun

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [string]$EspDrive = '',
    [string]$Efi      = '',
    [string]$Anim     = '',
    [string]$Cfg      = '',
    [string]$Frames   = '',
    [switch]$NoShim,
    [switch]$AlsoFallbackPath,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'EspTools.ps1')

$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Head 'BootAnim 安装程序'

Assert-Admin

# ---------------------------------------------------------------- 参数
if (-not $Efi) {
    $Efi = Join-Path $ProjectRoot 'dist\bootanim.efi'
}
if (-not (Test-Path -LiteralPath $Efi)) {
    Write-Err "找不到 bootanim.efi: $Efi"
    Write-Host '        请先构建： build\edk2\build-edk2.bat C:\edk2'
    exit 2
}
if (-not $Cfg) {
    $Cfg = Join-Path $PSScriptRoot 'bootanim.cfg'
}
if (-not $Anim) {
    $candidate = Join-Path $ProjectRoot 'dist\anim.baa'
    if (Test-Path -LiteralPath $candidate) { $Anim = $candidate }
}

if (Test-IsBootAnimLoader -Path $Efi) {
    Write-Ok "bootanim.efi 校验通过（含内嵌标记）"
} else {
    Write-Warn2 "bootanim.efi 里没有找到内嵌标记，可能不是本工程编译出来的文件。"
    Write-Host '        仍然会继续，但卸载脚本可能无法自动识别。'
}

Write-Host "  程序  : $Efi"
Write-Host "  配置  : $Cfg"
if ($Anim)   { Write-Host "  动画  : $Anim" }
if ($Frames) { Write-Host "  帧目录: $Frames" }

Show-BitLockerAdvice

# ---------------------------------------------------------------- ESP
Write-Head '定位 EFI 系统分区'
$esp = $null
try {
    $esp = Get-EspRoot -DriveLetter $EspDrive
} catch {
    Write-Err $_.Exception.Message
    exit 3
}
$root = $esp.Path
Write-Ok "ESP = $root"
if (-not (Test-Path -LiteralPath (Join-Path $root 'EFI'))) {
    Write-Warn2 "ESP 上没有 EFI 目录，看起来不太对劲，请确认选对了分区。"
}

$mainDir     = Join-Path $root 'EFI\BootAnim'
$framesDir   = Join-Path $mainDir 'frames'
$winBootDir  = Join-Path $root 'EFI\Microsoft\Boot'
$shimPath    = Join-Path $winBootDir 'bootmgfw.efi'
$origPath    = Join-Path $winBootDir 'bootmgfw-orig.efi'
$fallbackDir = Join-Path $root 'EFI\Boot'
$fbPath      = Join-Path $fallbackDir 'bootx64.efi'
$fbOrig      = Join-Path $fallbackDir 'bootx64-orig.efi'

try {
    # ------------------------------------------------------------ 预检
    Write-Head '预检'
    if (-not (Test-Path -LiteralPath $winBootDir)) {
        Write-Err "ESP 上没有 $winBootDir，这不是一块正常的 Windows 引导盘。"
        if (-not $NoShim) { exit 4 }
    } else {
        Write-Ok "找到 Windows 引导目录: $winBootDir"
    }

    $shimIsOurs = Test-IsBootAnimLoader -Path $shimPath
    if ($shimIsOurs) {
        Write-Warn2 '当前 bootmgfw.efi 已经是 BootAnim（重复安装，会直接覆盖）'
    } elseif (Test-Path -LiteralPath $shimPath) {
        Write-Ok '当前 bootmgfw.efi 是原始引导程序，将先备份'
    } else {
        Write-Warn2 "没有找到 $shimPath"
    }

    if ($DryRun) {
        Write-Head 'DryRun：以下操作不会真正执行'
    }

    # ------------------------------------------------------------ 复制素材
    Write-Head '复制程序与素材'
    $steps = @()
    $steps += "创建目录 $mainDir"
    $steps += "复制 $Efi -> $mainDir\bootanim.efi"
    if ($Cfg -and (Test-Path -LiteralPath $Cfg)) {
        $steps += "复制 $Cfg -> $mainDir\bootanim.cfg"
    } else {
        Write-Warn2 "配置模板不存在（$Cfg），将使用程序内置默认值"
    }
    if ($Anim) {
        $ext = [IO.Path]::GetExtension($Anim).ToLowerInvariant()
        if ($ext -eq '.baa') {
            $steps += "复制 $Anim -> $mainDir\anim.baa"
        } else {
            # BMP 序列：把第一帧推导出的模板一起复制过去
            $steps += "复制 BMP 帧序列（来自 $Anim 所在目录）-> $framesDir"
        }
    }
    if ($Frames) {
        $steps += "复制 $Frames\*.bmp -> $framesDir"
    }
    if (-not $NoShim) {
        $steps += "备份 $shimPath -> $origPath"
        $steps += "复制 $Efi -> $shimPath   (接管开机流程)"
    }
    if ($AlsoFallbackPath) {
        $steps += "备份 $fbPath -> $fbOrig"
        $steps += "复制 $Efi -> $fbPath"
    }
    foreach ($s in $steps) { Write-Host "  - $s" }

    if ($DryRun) {
        Write-Head 'DryRun 结束，ESP 未被修改'
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Copy-FileSafe -Source $Efi -Dest (Join-Path $mainDir 'bootanim.efi')
    Write-Ok 'bootanim.efi 已复制'

    if ($Cfg -and (Test-Path -LiteralPath $Cfg)) {
        Copy-FileSafe -Source $Cfg -Dest (Join-Path $mainDir 'bootanim.cfg')
        Write-Ok 'bootanim.cfg 已复制'
    }

    if ($Anim) {
        $ext = [IO.Path]::GetExtension($Anim).ToLowerInvariant()
        if ($ext -eq '.baa') {
            Copy-FileSafe -Source $Anim -Dest (Join-Path $mainDir 'anim.baa')
            Write-Ok 'anim.baa 已复制'
        }
    }

    if ($Frames -or ($Anim -and ([IO.Path]::GetExtension($Anim).ToLowerInvariant() -ne '.baa'))) {
        $srcDir = $Frames
        if (-not $srcDir) { $srcDir = Split-Path -Parent $Anim }
        New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
        $bmps = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.bmp' -File -ErrorAction SilentlyContinue)
        if ($bmps.Count -eq 0) {
            Write-Warn2 "$srcDir 里没有 .bmp 文件"
        } else {
            foreach ($f in $bmps) {
                Copy-FileSafe -Source $f.FullName -Dest (Join-Path $framesDir $f.Name)
            }
            Write-Ok "已复制 $($bmps.Count) 个 BMP 帧到 $framesDir"
        }
    }

    # ------------------------------------------------------------ shim
    if (-not $NoShim) {
        Write-Head '接管 Windows 引导程序（shim）'

        if (-not (Test-Path -LiteralPath $shimPath)) {
            Write-Err "找不到 $shimPath，无法安装 shim。"
            Write-Host '        可以改用 -NoShim 只部署文件。'
            exit 5
        }

        if (-not (Test-IsBootAnimLoader -Path $shimPath)) {
            if (-not (Test-Path -LiteralPath $origPath)) {
                Copy-FileSafe -Source $shimPath -Dest $origPath
                Write-Ok "已备份原始引导程序 -> bootmgfw-orig.efi"
            } else {
                $a = (Get-Item -LiteralPath $shimPath).Length
                $b = (Get-Item -LiteralPath $origPath).Length
                if ($a -ne $b) {
                    Copy-FileSafe -Source $origPath -Dest "$origPath.bak"
                    Copy-FileSafe -Source $shimPath -Dest $origPath
                    Write-Warn2 "已有的 bootmgfw-orig.efi 与当前 bootmgfw.efi 大小不同，"
                    Write-Host '        已把旧备份另存为 bootmgfw-orig.efi.bak，并写入新的备份。'
                } else {
                    Write-Ok 'bootmgfw-orig.efi 已存在且与当前引导程序一致，保留'
                }
            }
        } else {
            Write-Ok 'bootmgfw.efi 已经是 BootAnim，跳过备份'
        }

        if (-not (Test-Path -LiteralPath $origPath)) {
            Write-Err '没有可用的 bootmgfw-orig.efi，为了安全中止安装。'
            exit 6
        }
        if (Test-IsBootAnimLoader -Path $origPath) {
            Write-Err 'bootmgfw-orig.efi 竟然也是 BootAnim！为了不陷入死循环，中止安装。'
            exit 6
        }

        Copy-FileSafe -Source $Efi -Dest $shimPath
        if (Test-IsBootAnimLoader -Path $shimPath) {
            Write-Ok 'bootmgfw.efi 已替换为 BootAnim'
        } else {
            Write-Err '替换后校验失败，请立即运行 Uninstall-BootAnim.ps1'
            exit 7
        }
    } else {
        Write-Head '跳过 shim（-NoShim）'
        Write-Host '  请自行用下列任一方式在开机时调用它：'
        Write-Host "    * 固件启动项 / UEFI Shell： $mainDir\bootanim.efi"
        Write-Host '    * 已经装好的第三方启动管理器（rEFInd/GRUB/Clover）里加一个条目'
    }

    if ($AlsoFallbackPath) {
        Write-Head '可移动设备默认路径'
        if (Test-Path -LiteralPath $fbPath) {
            if (-not (Test-IsBootAnimLoader -Path $fbPath)) {
                if (-not (Test-Path -LiteralPath $fbOrig)) {
                    Copy-FileSafe -Source $fbPath -Dest $fbOrig
                    Write-Ok '已备份 bootx64.efi -> bootx64-orig.efi'
                }
            }
            Copy-FileSafe -Source $Efi -Dest $fbPath
            Write-Ok 'bootx64.efi 已替换为 BootAnim'
        } else {
            Write-Warn2 "没有找到 $fbPath，跳过"
        }
    }

    # ------------------------------------------------------------ 结果
    Write-Head '安装完成'
    Get-ChildItem -LiteralPath $mainDir -Recurse -File |
        ForEach-Object { Write-Host ("  {0,10:N0}  {1}" -f $_.Length, $_.FullName.Substring($root.Length)) }
    if (-not $NoShim) {
        Write-Host ("  {0,10:N0}  {1}" -f (Get-Item -LiteralPath $shimPath).Length,
                    $shimPath.Substring($root.Length))
        Write-Host ("  {0,10:N0}  {1}" -f (Get-Item -LiteralPath $origPath).Length,
                    $origPath.Substring($root.Length))
    }
    Write-Host ''
    Write-Ok '下次开机就会先播放动画，然后自动继续启动 Windows。'
    Write-Host '  任何按键都可以跳过动画。'
    Write-Host '  想改时长/分辨率/是否跳过：编辑 ESP 上的 \EFI\BootAnim\bootanim.cfg'
    Write-Host '  想卸载：管理员运行 Uninstall-BootAnim.ps1'
    Write-Host ''
    Write-Warn2 '如果开机出现异常，进 BIOS 选择 Windows 恢复盘，或把'
    Write-Host '        \EFI\Microsoft\Boot\bootmgfw-orig.efi 改名回 bootmgfw.efi 即可。'

} finally {
    Remove-EspAccess -Esp $esp
}
