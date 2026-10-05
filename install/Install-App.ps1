<#
.SYNOPSIS
  把 BootAnim 管理工具安装成一个正经的 Windows 应用。

.DESCRIPTION
  做的事：
    * 复制文件到安装目录（默认 %LOCALAPPDATA%\Programs\BootAnim，当前用户级，
      不需要管理员）
    * 创建开始菜单快捷方式（可选桌面快捷方式）
    * 在「设置 -> 应用 -> 已安装的应用」里注册卸载项（写 HKCU 的 Uninstall 键）
    * 可选把 ffmpeg 一起装上（-WithFFmpeg，会连它的 LICENSE/README.txt 一起装上）

  注意：程序本身运行时需要管理员权限（要读写 EFI 系统分区），
  它是靠自己的 runas 提权弹 UAC，跟安装方式无关。

.PARAMETER InstallDir
  安装到哪。默认 %LOCALAPPDATA%\Programs\BootAnim。
  如果指定到 Program Files 下面，就需要管理员权限来安装。

.PARAMETER WithFFmpeg
  把 ffmpeg.exe 一起装进去。会自动在项目里找（支持官网压缩包解压后的
  ffmpeg-*/bin/ffmpeg.exe 目录结构），也可以用 -FFmpegPath 指定。

.PARAMETER FFmpegPath
  ffmpeg.exe 的完整路径。给了这个就隐含启用 -WithFFmpeg。

.PARAMETER NoDesktopShortcut
  不创建桌面快捷方式（默认会创建）。

.PARAMETER NoStartMenu
  不创建开始菜单快捷方式。

.PARAMETER Quiet
  不打印过程中的细节。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\Install-App.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\Install-App.ps1 -WithFFmpeg

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$FFmpegPath,
    [switch]$WithFFmpeg,
    [switch]$NoDesktopShortcut,
    [switch]$NoStartMenu,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$AppName    = 'BootAnim'
$AppDisplay = 'BootAnim 开机动画管理工具'
$AppVersion = '1.1.0'
$Publisher  = 'BootAnim contributors'

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

function Say([string]$Text, [string]$Color = 'Gray') { if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color } }
function Ok([string]$Text)   { Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Warn2([string]$Text){ Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { Write-Host "  [失败] $Text" -ForegroundColor Red }

Say ''
Say '=========================================================' Cyan
Say "  $AppDisplay  安装程序" Cyan
Say '=========================================================' Cyan
Say ''

# ---------------------------------------------------------------- 1. 检查源文件
Say '[1/6] 检查要安装的文件'

$exe = Join-Path $Root 'gui\BootAnimGUI.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Fail "找不到 $exe"
    Say ''
    Say '  图形界面的 exe 还没打包。先执行：' Yellow
    Say '    powershell -ExecutionPolicy Bypass -File gui\build-gui-exe.ps1' Yellow
    Say ''
    exit 2
}
Ok "主程序: $exe  ($([int]((Get-Item $exe).Length/1KB)) KB)"

# 要一起复制的附带文件（存在才拷）
$extra = @()
foreach ($rel in 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md', '编译说明.md') {
    $p = Join-Path $Root $rel
    if (Test-Path -LiteralPath $p) { $extra += $p }
}
$docsDir = Join-Path $Root 'docs'
if (Test-Path -LiteralPath $docsDir) { $extra += $docsDir }
$cfgTpl = Join-Path $Root 'install\bootanim.cfg'
if (Test-Path -LiteralPath $cfgTpl) { $extra += $cfgTpl }
Ok "附带文件 $($extra.Count) 项（许可证、文档、配置模板）"

# bootanim.efi：安装包里有就带上，方便装完直接能用「安装接管」
$efi = Join-Path $Root 'dist\bootanim.efi'
$haveEfi = Test-Path -LiteralPath $efi
if ($haveEfi) { Ok "引导程序: $efi  ($([int]((Get-Item $efi).Length/1KB)) KB)" }
else { Warn2 '没有 dist\bootanim.efi（装完仍然能换图片/开关动画，但「安装接管」需要它）' }

# ---------------------------------------------------------------- 2. 找 ffmpeg
Say ''
Say '[2/6] 视频拆帧组件（ffmpeg）'

$srcFF = $null
if ($FFmpegPath) {
    if (-not (Test-Path -LiteralPath $FFmpegPath)) { Fail "指定的 ffmpeg 不存在: $FFmpegPath"; exit 3 }
    $srcFF = (Resolve-Path -LiteralPath $FFmpegPath).Path
    $WithFFmpeg = $true
} elseif ($WithFFmpeg) {
    # 和 GUI 里一样的搜索顺序，覆盖"官网压缩包解压后整个丢进来"的情况
    $direct = @(
        (Join-Path $Root 'ffmpeg.exe'),
        (Join-Path $Root 'bin\ffmpeg.exe'),
        (Join-Path $Root 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $Root 'tools\ffmpeg.exe'),
        (Join-Path $Root 'gui\ffmpeg.exe')
    )
    foreach ($c in $direct) { if (Test-Path -LiteralPath $c) { $srcFF = $c; break } }
    if (-not $srcFF) {
        $hit = @(Get-ChildItem -LiteralPath $Root -Recurse -Depth 4 -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\AppData\\' } |
                 Sort-Object { $_.FullName.Length } | Select-Object -First 1)
        if ($hit.Count -gt 0) { $srcFF = $hit[0].FullName }
    }
    if (-not $srcFF) {
        Fail '在项目里没找到 ffmpeg.exe，没法一起安装'
        Say '  可以用 -FFmpegPath <路径> 明确指定，或者不加 -WithFFmpeg（安装后再把 ffmpeg.exe 放到安装目录）' Yellow
        exit 3
    }
}

if ($srcFF) {
    Ok "将一起安装: $srcFF  ($([int]((Get-Item $srcFF).Length/1MB)) MB)"
    Warn2 'ffmpeg 这个构建是 GPL v3，与本项目（GPL-3.0-or-later）同族；会一并装上它的许可证文件'
} else {
    Say '  不一起安装 ffmpeg（跳过了）'
    Say '  安装后如果想用视频拆帧，把 ffmpeg.exe 放到安装目录，' 
    Say '  或者在 WSL 里装一个（wsl -e sudo apt install -y ffmpeg）'
}

# ---------------------------------------------------------------- 3. 决定安装位置
Say ''
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\BootAnim' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
Say "[3/6] 安装位置: $InstallDir"

$pfRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
           Where-Object { $_ -and $_.Trim() }     # 32 位系统上 (x86) 是空的，别让 StartsWith('') 永远为真
$needAdmin = $false
foreach ($pf in $pfRoots) {
    if ($InstallDir.StartsWith($pf, [StringComparison]::OrdinalIgnoreCase)) { $needAdmin = $true; break }
}
if ($needAdmin) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Fail '安装到 Program Files 需要管理员权限，请用管理员身份运行本脚本'
        Say '  （想免管理员就用默认位置：%LOCALAPPDATA%\Programs\BootAnim）' Yellow
        exit 4
    }
    Ok '安装到 Program Files，已具备管理员权限'
} else {
    Ok '安装到当前用户目录，不需要管理员权限'
}

# 程序正在运行就不能覆盖
$running = @(Get-Process -Name 'BootAnimGUI' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Fail 'BootAnimGUI 正在运行，请先关掉它再安装'
    exit 5
}

# ---------------------------------------------------------------- 4. 复制文件
Say ''
Say '[4/6] 复制文件'
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Copy-Item -LiteralPath $exe -Destination (Join-Path $InstallDir 'BootAnimGUI.exe') -Force
$installed = 1
foreach ($p in $extra) {
    $name = Split-Path -Leaf $p
    if ($name -eq 'bootanim.cfg') { $name = 'bootanim.cfg.template' }
    $dest = Join-Path $InstallDir $name
    if ((Get-Item -LiteralPath $p).PSIsContainer) {
        Copy-Item -LiteralPath $p -Destination (Join-Path $InstallDir $name) -Recurse -Force
    } else {
        Copy-Item -LiteralPath $p -Destination $dest -Force
    }
    $installed++
}
if ($haveEfi) {
    $efiDir = Join-Path $InstallDir 'dist'
    New-Item -ItemType Directory -Force -Path $efiDir | Out-Null
    Copy-Item -LiteralPath $efi -Destination (Join-Path $efiDir 'bootanim.efi') -Force
    $installed++
}
if ($srcFF) {
    Copy-Item -LiteralPath $srcFF -Destination (Join-Path $InstallDir 'ffmpeg.exe') -Force
    $installed++
    # 合规：把 ffmpeg 自己的许可证和构建说明一起带上
    $ffDir = Split-Path -Parent $srcFF
    $ffRoot = Split-Path -Parent $ffDir
    foreach ($n in 'LICENSE', 'README.txt') {
        $cand = Join-Path $ffRoot $n
        if (Test-Path -LiteralPath $cand) {
            Copy-Item -LiteralPath $cand -Destination (Join-Path $InstallDir "ffmpeg-$n") -Force
            $installed++
        }
    }
}
Ok "已复制 $installed 个文件/目录"

# 算一下占了多少空间，写进卸载项
$totalBytes = (Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum).Sum
Say "    占用空间: $([Math]::Round($totalBytes/1MB,1)) MB"

# ---------------------------------------------------------------- 5. 快捷方式
Say ''
Say '[5/6] 创建快捷方式'
$exeInstalled = Join-Path $InstallDir 'BootAnimGUI.exe'
$ws = New-Object -ComObject WScript.Shell

function New-Lnk([string]$Path, [string]$Desc) {
    $lnk = $ws.CreateShortcut($Path)
    $lnk.TargetPath       = $exeInstalled
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Description      = $Desc
    $lnk.IconLocation     = "$exeInstalled,0"
    $lnk.Save()
}

# 快捷方式失败不能让整个安装中断 —— 否则会留下"文件拷好了、注册项没写"的
# 半残状态，用户还得手动清。所以这里全部容错，最后统一汇报。
$script:warnCount = 0

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
if (-not $NoStartMenu) {
    $lnkPath = Join-Path $startMenu "$AppName.lnk"
    try {
        New-Lnk $lnkPath $AppDisplay
        Ok "开始菜单: $lnkPath"
    } catch {
        $script:warnCount++
        Warn2 "开始菜单快捷方式创建失败（不影响使用，可以直接双击程序）：$($_.Exception.Message)"
    }
}

$deskLnk = $null
if (-not $NoDesktopShortcut) {
    $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    try {
        New-Lnk $deskLnk $AppDisplay
        Ok "桌面: $deskLnk"
    } catch {
        $script:warnCount++
        $deskLnk = $null
        Warn2 "桌面快捷方式创建失败（不影响使用）：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 6. 注册卸载项
Say ''
Say '[6/6] 注册到「应用和功能」'
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
$uninstScript = Join-Path $InstallDir 'Uninstall-BootAnimApp.ps1'
$uninstPs1 = Join-Path $Root 'install\Uninstall-App.ps1'
if (Test-Path -LiteralPath $uninstPs1) {
    Copy-Item -LiteralPath $uninstPs1 -Destination $uninstScript -Force
} else {
    Warn2 "没有找到 $uninstPs1，卸载项会指向缺失的脚本"
}

$uninstCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $uninstScript + '"'

try {
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
$props = @{
    'DisplayName'     = $AppDisplay
    'DisplayVersion'  = $AppVersion
    'Publisher'       = $Publisher
    'InstallLocation' = $InstallDir
    'DisplayIcon'     = "$exeInstalled,0"
    'UninstallString' = $uninstCmd
    'QuietUninstallString' = $uninstCmd + ' -Quiet'
    'NoModify'        = 1
    'NoRepair'        = 1
    'EstimatedSize'   = [int]($totalBytes / 1KB)
    'InstallDate'     = (Get-Date -Format 'yyyyMMdd')
    'Comments'        = 'ESP 开机动画（Windows 无法设置开机动画的替代方案）'
}
foreach ($k in $props.Keys) {
    New-ItemProperty -Path $regPath -Name $k -Value $props[$k] -PropertyType $(if ($props[$k] -is [int]) { 'DWord' } else { 'String' }) -Force | Out-Null
}
$script:regOk = $true
Ok "已注册: $regPath"
} catch {
    $script:warnCount++
    Warn2 "注册「应用和功能」失败（不影响使用）：$($_.Exception.Message)"
    Warn2 '  想卸载时直接删掉安装目录和快捷方式即可'
}

# ---------------------------------------------------------------- 完成
Say ''
Say '=========================================================' Green
if ($script:warnCount -gt 0) {
    Say "  安装完成（有 $($script:warnCount) 项没能完成，见上面的 [注意]）" Green
} else {
    Say '  安装完成' Green
}
Say '=========================================================' Green
Say ''
Say "  程序      : $exeInstalled"
Say "  安装目录  : $InstallDir"
if ($script:startMenuOk) { Say '  开始菜单  : 已创建（搜 "BootAnim" 就能找到）' }
elseif (-not $NoStartMenu) { Warn2 '开始菜单快捷方式没建成，直接双击安装目录里的 BootAnimGUI.exe 即可' }
if ($script:deskOk)      { Say "  桌面      : $deskLnk" }
if ($script:regOk) {
    Say '  卸载      : 设置 -> 应用 -> 已安装的应用 -> BootAnim -> 卸载'
} else {
    Say '  卸载      : 直接删掉安装目录（和快捷方式）即可，没有注册进「应用和功能」'
}
Say ''
Say '  首次使用提醒：' Yellow
Say '    * 程序运行时会弹 UAC 请求管理员权限（要读写 EFI 系统分区），这是正常的'
if (-not $haveEfi) {
    Say '    * 没有随包带上 bootanim.efi，「安装接管」不可用。' Yellow
    Say '      需要它的话：编译出 dist\bootanim.efi 后重新运行本脚本，' Yellow
    Say '      或者把 .efi 放到安装目录的 dist\ 子目录里。' Yellow
}
if (-not $srcFF) {
    Say '    * 想用视频拆帧：把 ffmpeg.exe 放到安装目录，' 
    Say '      或在 WSL 里装（wsl -e sudo apt install -y ffmpeg）'
}
Say ''
