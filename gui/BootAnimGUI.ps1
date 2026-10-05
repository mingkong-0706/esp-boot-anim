<#
.SYNOPSIS
  BootAnim 图形管理工具 —— 换图片、开关动画、装/卸引导接管。

.DESCRIPTION
  一个 WinForms 界面的管理工具，全部依赖 Windows 自带能力：
    * 界面      : PowerShell + System.Windows.Forms
    * 图像处理  : GDI+ (System.Drawing)
    * 打包/RLE  : Add-Type 在内存里用系统自带的 C# 编译器编出原生代码
  所以不需要安装 Python、.NET SDK 或任何编译器。

  功能：
    * 启用 / 禁用开机动画（改 ESP 上 bootanim.cfg 的 ENABLED 键，不用卸载）
    * 换图片：选一堆图片 → 设分辨率/帧率/适配方式 → 生成 .baa → 写进 ESP
    * 一键生成示例动画（没有任何素材也能玩）
    * 安装 / 卸载引导接管（bootmgfw.efi 的备份与还原）
    * 预览第一帧、查看当前动画信息

  需要管理员权限（会自己弹 UAC 提权）。

.EXAMPLE
  双击 gui\BootAnim管理工具.cmd
  或者  powershell -ExecutionPolicy Bypass -File gui\BootAnimGUI.ps1

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# WinForms / GDI+ 要先加载，因为下面提权失败时要用 MessageBox 报错
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------
#  自提权
# ---------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"')
        ) | Out-Null
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "需要管理员权限，但提权被取消或失败了。`n`n$($_.Exception.Message)",
            'BootAnim', 'OK', 'Error')
    }
    exit
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$GuiDir     = $PSScriptRoot
$ProjRoot   = Split-Path -Parent $GuiDir
$InstallDir = Join-Path $ProjRoot 'install'
$DistDir    = Join-Path $ProjRoot 'dist'

# 复用安装脚本里的 ESP 工具函数
. (Join-Path $InstallDir 'EspTools.ps1')
. (Join-Path $GuiDir 'BootAnimPacker.ps1')

# GUI 里不要 StrictMode；错误保持 Stop，这样 try/catch 才抓得住
# （例如 Copy-FileSafe 失败必须能中断流程，不能静默继续）
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:Esp       = $null
$script:EspPath   = ''
$script:AnimDir   = ''
$script:Images    = New-Object System.Collections.ArrayList
$script:BaaTemp   = Join-Path $env:TEMP 'bootanim_pack_tmp.baa'
$script:PackerReady = $false
$script:LastRatio = 0.0     # 上次打包实测的压缩比，用来估算体积
# 拆帧（GIF / 视频）的落脚处。
# **刻意不放在 %TEMP%**，原因是实测踩到过：
#   * 外部程序（ffmpeg）往 %TEMP% 写文件可能被安全策略拦住，报 Permission denied，
#     而它往程序自己所在目录写完全正常
#   * 有些安全软件会把 %TEMP% 重定向到别处，或者对它做限制
#   * 一次拆帧可能产生几百 MB，放系统盘不合适
# 策略：优先用程序旁边的目录，写不进去再退回 %TEMP%。
# 单独成函数是为了让测试能直接验证这段选择逻辑（见 tools\test-gui-mp4real.ps1）。
function Initialize-FrameDir {
    param([string]$Preferred)
    $dir = ''
    $cands = New-Object System.Collections.ArrayList
    if ($Preferred) { [void]$cands.Add($Preferred) }
    [void]$cands.Add((Join-Path $ProjRoot '.bootanim-frames'))
    [void]$cands.Add((Join-Path $env:TEMP 'BootAnimGUI_frames'))
    foreach ($cand in $cands) {
        try {
            New-Item -ItemType Directory -Force -Path $cand -ErrorAction Stop | Out-Null
            $probe = Join-Path $cand '.writetest'
            [IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $dir = $cand
            break
        } catch { }
    }
    return $dir
}
$script:FrameDir = Initialize-FrameDir
$script:WslFF = $null      # $null 未探测；'no' 不可用；否则是 wsl.exe 的路径
$script:FFmpegPath = $null # 找到的 ffmpeg.exe 路径（只缓存命中，不缓存未命中）

# ---------------------------------------------------------------------
#  日志
# ---------------------------------------------------------------------
function Add-Log {
    param([string]$Text, [string]$Level = 'info')
    if (-not $script:LogBox) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'ok'   { '[ OK ]' }
        'warn' { '[注意]' }
        'err'  { '[错误]' }
        default { '[信息]' }
    }
    $line = "$stamp $prefix $Text"
    [void]$script:LogBox.Items.Add($line)
    $script:LogBox.TopIndex = $script:LogBox.Items.Count - 1
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Error {
    param([string]$Title, [string]$Text)
    Add-Log "$Title : $Text" 'err'
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Error')
}

# ---------------------------------------------------------------------
#  .baa 头读取（纯 PowerShell 就够）
# ---------------------------------------------------------------------
function Get-BaaInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [byte[]]::new(64)
        $fs = [IO.File]::OpenRead($Path)
        try {
            if ($fs.Length -lt 64) { return $null }
            [void]$fs.Read($bytes, 0, 64)
        } finally { $fs.Dispose() }
        if ([Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne 'BAANIM01') { return $null }
        # 必须先把每个 byte 转成 [uint32] 再移位：
        # PowerShell 的 -shl/-shr 会保留左操作数的类型，而 $bytes[$i] 是 Byte，
        # 于是 [byte]7 -shl 8 会被截断成 0，拼出来的宽高就全错了。
        $f = {
            param([int]$o)
            ([uint32]$bytes[$o]) -bor
            (([uint32]$bytes[$o + 1]) -shl 8) -bor
            (([uint32]$bytes[$o + 2]) -shl 16) -bor
            (([uint32]$bytes[$o + 3]) -shl 24)
        }
        $fc = & $f 12; $w = & $f 16; $h = & $f 20; $fps = & $f 24; $fl = & $f 28
        if ($fc -eq 0 -or $w -eq 0 -or $h -eq 0) { return $null }
        return [PSCustomObject]@{
            Frames = $fc; Width = $w; Height = $h; Fps = $fps
            Rle = (($fl -band 1) -ne 0)
            Size = (Get-Item -LiteralPath $Path).Length
        }
    } catch { return $null }
}

# ---------------------------------------------------------------------
#  bootanim.cfg 读写（保留注释，只改需要的键）
# ---------------------------------------------------------------------
function Read-Cfg {
    param([string]$Path)
    $cfg = @{ Enabled = $true; Anim = 'anim.baa'; Fps = $null; Pacing = $null; Raw = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    try {
        $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    } catch {
        $lines = [IO.File]::ReadAllLines($Path)
    }
    $cfg.Raw = $lines
    foreach ($l in $lines) {
        if ($l -match '^\s*[#;]') { continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $k = $Matches[1].ToUpperInvariant()
            $v = $Matches[2].Trim()
            switch ($k) {
                'ENABLED' { $cfg.Enabled = -not ($v -match '^(0|off|no|false|disable|disabled)$') }
                'ANIM'    { $cfg.Anim = $v }
                'FPS'     { $cfg.Fps = $v }
                'PACING'  { $cfg.Pacing = $v }
            }
        }
    }
    return $cfg
}

function Set-CfgValue {
    param([string]$Path, [hashtable]$Pairs)
    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        try { $lines = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) }
        catch { $lines = @([IO.File]::ReadAllLines($Path)) }
    }
    $text = [System.Collections.ArrayList]::new()
    foreach ($l in $lines) { [void]$text.Add($l) }

    foreach ($key in $Pairs.Keys) {
        $val = [string]$Pairs[$key]
        $found = $false
        for ($i = 0; $i -lt $text.Count; $i++) {
            if ($text[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                $text[$i] = "$key=$val"
                $found = $true
                break
            }
        }
        if (-not $found) { [void]$text.Add("$key=$val") }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllLines($Path, [string[]]$text.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------
#  ESP 连接 / 断开
# ---------------------------------------------------------------------
function Connect-Esp {
    if ($script:EspPath -and (Test-DirExists $script:EspPath)) { return $true }
    try {
        Add-Log '正在定位 EFI 系统分区…'
        $script:Esp     = Get-EspRoot
        $script:EspPath = $script:Esp.Path
        $script:AnimDir = Join-Path $script:EspPath 'EFI\BootAnim'
        Add-Log "ESP = $script:EspPath" 'ok'
        return $true
    } catch {
        $script:Esp = $null; $script:EspPath = ''; $script:AnimDir = ''
        Add-Log "定位 ESP 失败：$($_.Exception.Message)" 'err'
        return $false
    }
}

function Disconnect-Esp {
    if ($script:Esp) {
        Remove-EspAccess -Esp $script:Esp
        $script:Esp = $null; $script:EspPath = ''; $script:AnimDir = ''
        Add-Log '已释放 ESP 盘符' 'ok'
    }
}

# ---------------------------------------------------------------------
#  状态刷新
# ---------------------------------------------------------------------
function Refresh-Status {
    if (-not $script:EspPath) {
        $script:LblStatus.Text = '未连接 ESP'
        return
    }
    try {
        $shimPath = Join-Path $script:EspPath 'EFI\Microsoft\Boot\bootmgfw.efi'
        $origPath = Join-Path $script:EspPath 'EFI\Microsoft\Boot\bootmgfw-orig.efi'
        $cfgPath  = Join-Path $script:AnimDir 'bootanim.cfg'
        $animPath = Join-Path $script:AnimDir 'anim.baa'

        $shimOurs = Test-IsBootAnimLoader -Path $shimPath
        $origOk   = (Test-Path -LiteralPath $origPath) -and (-not (Test-IsBootAnimLoader -Path $origPath))
        $cfg      = Read-Cfg -Path $cfgPath
        $info     = Get-BaaInfo -Path $animPath

        $installed = if ($shimOurs) { '已接管开机' } else { '未接管' }
        $onoff     = if (-not $shimOurs) { '-' } elseif ($cfg.Enabled) { '启用中' } else { '已禁用' }
        $animTxt   = if ($info) {
            "$($info.Width)x$($info.Height)  $($info.Frames) 帧  $($info.Fps)fps  " +
            ("{0:N0} KB" -f ($info.Size / 1KB)) + $(if ($info.Rle) { '  RLE' } else { '' })
        } else { '（没有 anim.baa）' }

        $script:LblStatus.Text = "ESP: $script:EspPath        引导接管: $installed        动画: $onoff"
        $script:LblAnim.Text   = "当前动画: $animTxt"
        $script:LblCfg.Text    = "配置文件: $(if (Test-Path -LiteralPath $cfgPath) { $cfgPath } else { '（不存在，将用内置默认值）' })"
        $script:LblOrig.Text   = if ($shimOurs) {
            if ($origOk) { "原版引导备份: 正常（bootmgfw-orig.efi）" } else { "原版引导备份: 缺失！卸载会有风险" }
        } else { '' }

        $script:RadEnable.Checked  = [bool]$cfg.Enabled
        $script:RadDisable.Checked = -not [bool]$cfg.Enabled
        $script:RadEnable.Enabled  = $shimOurs
        $script:RadDisable.Enabled = $shimOurs
        $script:BtnApplyPower.Enabled = $shimOurs
        if ($script:LblOrig.Text -and -not $origOk) { $script:LblOrig.ForeColor = 'Red' }
        else { $script:LblOrig.ForeColor = 'DimGray' }
    } catch {
        $script:LblStatus.Text = '刷新状态失败：' + $_.Exception.Message
    }
}

# ---------------------------------------------------------------------
#  预览
# ---------------------------------------------------------------------
function Update-Preview {
    if ($script:Images.Count -eq 0) {
        if ($script:PicPreview.Image) { $script:PicPreview.Image.Dispose() }
        $script:PicPreview.Image = $null
        $script:LblPreview.Text = '（未选择图片）'
        return
    }
    try {
        $img = [System.Drawing.Image]::FromFile($script:Images[0])
        if ($script:PicPreview.Image) { $script:PicPreview.Image.Dispose() }
        $script:PicPreview.Image = $img
        $script:LblPreview.Text = "$($script:Images.Count) 张，预览第 1 张  ($($img.Width)x$($img.Height))"
    } catch {
        $script:LblPreview.Text = '预览失败：' + $_.Exception.Message
    }
}

function Update-ImageList {
    $script:LstImages.BeginUpdate()
    $script:LstImages.Items.Clear()
    foreach ($p in $script:Images) { [void]$script:LstImages.Items.Add([IO.Path]::GetFileName($p)) }
    $script:LstImages.EndUpdate()
    Update-Preview
    Update-Estimate
}

# 实时显示「多少张 -> 多长 -> 多大」。
# 10 秒动画就是 300 张，这个数必须在打包前就看得到。
function Update-Estimate {
    if (-not $script:LblEst) { return }
    $n = $script:Images.Count
    if ($n -eq 0) { $script:LblEst.Text = ''; return }
    $fps = [int]$script:NumFps.Value
    if ($fps -lt 1) { $fps = 30 }
    $w = [int]$script:NumW.Value
    $h = [int]$script:NumH.Value
    $sec  = $n / [double]$fps
    $rawM = ($n * [double]$w * [double]$h * 4.0) / 1MB
    $msg = "{0} 张  ->  {1} fps 下约 {2:N1} 秒  ·  未压缩 {3:N0} MiB" -f $n, $fps, $sec, $rawM
    if ($sec -gt 15.0) {
        $msg += "  ·  [注意] 超过 TIMEOUT_MS 默认的 15 秒上限，要改配置才能播完"
    }
    if ($script:LastRatio -gt 0) {
        $est = $rawM * $script:LastRatio
        $msg += ("  ·  按上次实测压缩到 {0:N1}%，约 {1:N1} MiB" -f (100 * $script:LastRatio), $est)
        if ($est -gt 32.0) {
            $msg += "`r`n  [注意] 超过 32 MiB 就不会被读进内存了（改成逐帧读 FAT，会明显变慢）"
            if ($est -gt 90.0) {
                $msg += "`r`n  [注意] 这个体积很可能放不下 EFI 分区。建议降分辨率、降帧率，或用 LOOP 循环一段短素材"
            }
        }
        $script:LblEst.Height = $(if ($est -gt 32.0) { 34 } else { 20 })
    } else {
        $msg += "  ·  （第一次打包后这里会显示按实测压缩比的体积估算）"
    }
    $script:LblEst.Text = $msg
}

# 统一的「加图片」入口：
#   * 普通图片原样加入
#   * 多帧 GIF/TIFF 自动拆成一张张 PNG 再加入
#     （GDI+ 的 Image.FromFile 对多帧文件只给第一帧，不拆的话
#       用户选一个 300 帧的 GIF 会静默地只放进去 1 张）
# 返回 @{ Added = 张数; GifFrames = 拆出的帧数; AvgDelay = 平均帧间隔ms }
function Add-ImageFiles {
    param([string[]]$Paths)

    $res = @{ Added = 0; GifFrames = 0; AvgDelay = 0; VideoFrames = 0 }
    if ($Paths.Count -eq 0) { return $res }
    if (-not (Initialize-PackerSafe)) { return $res }

    $delaySum = 0; $delayN = 0
    $idx = 0
    foreach ($p in $Paths) {
        $idx++
        $script:Prg.Value = [int](100 * $idx / $Paths.Count)
        $script:LblPreview.Text = "正在检查 $idx/$($Paths.Count) …"
        [System.Windows.Forms.Application]::DoEvents()

        $info = $null
        try { $info = [BootAnimGui.Packer]::Probe($p) } catch { $info = $null }

        if ($script:VideoExts -contains [IO.Path]::GetExtension($p).ToLowerInvariant()) {
            # ---------- 视频 ----------
            $vfps = [int]$script:NumFps.Value
            if ($vfps -lt 1) { $vfps = 30 }
            $prog2 = [Action[int, string]]{
                param($pct, $msg)
                $script:Prg.Value = [Math]::Min(100, [Math]::Max(0, $pct))
                $script:LblPreview.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $vr = Expand-VideoFile -Path $p -Fps $vfps -W ([int]$script:NumW.Value) `
                                   -H ([int]$script:NumH.Value) -Progress $prog2
            if ($vr) {
                foreach ($fr in $vr.Frames) { [void]$script:Images.Add($fr) }
                $res.Added += $vr.Frames.Count
                $res.VideoFrames += $vr.Frames.Count
                if ($vr.Clamped) {
                    Add-Log "帧数超过上限 $($script:VideoMaxFrames)，只取了前 $($script:VideoMaxFrames) 帧" 'warn'
                }
            } else {
                Show-VideoHelp -Path $p
            }
        } elseif ($info -and $info[0] -gt 1) {
            $sub2 = Join-Path $script:FrameDir ([IO.Path]::GetFileNameWithoutExtension($p))
            Add-Log "「$([IO.Path]::GetFileName($p))」是 $($info[0]) 帧的多帧文件，正在拆帧…"
            $prog = [Action[int, string]]{
                param($pct, $msg)
                $script:Prg.Value = [Math]::Min(100, [Math]::Max(0, $pct))
                $script:LblPreview.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            try {
                $frames = [BootAnimGui.Packer]::ExtractFrames($p, $sub2, $prog)
                foreach ($fr in $frames) { [void]$script:Images.Add($fr) }
                $res.Added    += $frames.Count
                $res.GifFrames += $frames.Count
                if ($info[1] -gt 0) { $delaySum += [int]$info[1]; $delayN++ }
                Add-Log "拆出 $($frames.Count) 帧" 'ok'
            } catch {
                Add-Log "拆帧失败，已跳过：$($_.Exception.Message)" 'err'
            }
        } else {
            [void]$script:Images.Add($p)
            $res.Added++
        }
    }
    $script:Prg.Value = 0
    if ($delayN -gt 0) { $res.AvgDelay = [int]($delaySum / $delayN) }
    return $res
}

# =====================================================================
#  视频（MP4 / MOV / MKV / AVI / WMV / WEBM）拆帧
#
#  两条路，按可靠性排序：
#    1) ffmpeg.exe —— 快、稳、格式全。放在 gui\ 或 PATH 里就会被自动发现。
#    2) Windows 自带的 Media Foundation（通过 WinRT 的
#       Windows.Media.Editing.MediaClip） —— 不用下载任何东西，但逐帧
#       GetThumbnailAsync 比较慢（每帧都要定位解码）。
#  两条都不行才会弹说明框。
# =====================================================================

$script:VideoExts = @('.mp4', '.m4v', '.mov', '.wmv', '.avi', '.mkv', '.webm', '.mpg', '.mpeg')
$script:VideoMaxFrames = 1200      # 上限，防止手滑选了个两小时的电影

function Find-FFmpeg {
    # 只缓存"找到"的结果；没找到不缓存，这样用户中途把 ffmpeg 丢进来
    # 不需要重启程序（README 里承诺过这一点）
    if ($script:FFmpegPath) { return $script:FFmpegPath }

    # ---- 0) 环境变量 / 安装目录 ----
    # BOOTANIM_FFMPEG 是给"ffmpeg 不在项目里"的情况留的口子：
    # CI、系统里另装了一份、或者安装后想指到别处。想指定就用它，
    # 不用把绝对路径写进代码。
    foreach ($cand in @($env:BOOTANIM_FFMPEG, (Join-Path $ProjRoot 'ffmpeg.exe'))) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $script:FFmpegPath = $cand; return $cand }
    }

    # ---- 1) 明确的位置 ----
    $direct = @(
        (Join-Path $GuiDir 'ffmpeg.exe'),
        (Join-Path $GuiDir 'ffmpeg\ffmpeg.exe'),
        (Join-Path $GuiDir 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $ProjRoot 'ffmpeg.exe'),
        (Join-Path $ProjRoot 'bin\ffmpeg.exe'),
        (Join-Path $ProjRoot 'ffmpeg\ffmpeg.exe'),
        (Join-Path $ProjRoot 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $ProjRoot 'tools\ffmpeg.exe')
    )
    foreach ($c in $direct) {
        if (Test-Path -LiteralPath $c) { $script:FFmpegPath = $c; return $c }
    }

    # ---- 2) 浅层递归找 ----
    # 覆盖最常见的情况：把官网下的压缩包解压后整个目录丢进项目里，
    # 例如 ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe
    foreach ($base in @($ProjRoot, $GuiDir)) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        try {
            $hit = @(Get-ChildItem -LiteralPath $base -Recurse -Depth 4 -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -notmatch '\\AppData\\' } |
                     Sort-Object { $_.FullName.Length } |
                     Select-Object -First 1)
            if ($hit.Count -gt 0) { $script:FFmpegPath = $hit[0].FullName; return $script:FFmpegPath }
        } catch { }
    }

    # ---- 3) PATH ----
    try {
        $cmd = Get-Command 'ffmpeg.exe' -ErrorAction SilentlyContinue
        if ($cmd) { $script:FFmpegPath = $cmd.Source; return $script:FFmpegPath }
    } catch { }

    return $null
}

# 把 ffmpeg 的命令行拼出来。单独成函数有两个好处：
#   1) Windows 侧和 WSL 侧共用同一份参数，不会写歪
#   2) 可以脱离 ffmpeg 本体直接单测参数拼得对不对
#      （-vf 里的逗号和冒号很容易踩 PowerShell 的插值坑）
function Get-FFmpegArgs {
    param([string]$InputPath, [string]$OutPattern, [int]$Fps, [int]$W, [int]$H, [int]$MaxFrames)
    return @(
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-i', $InputPath,
        '-an', '-sn',
        # scale 用 force_original_aspect_ratio=decrease —— 等比缩放到不超过 WxH，
        # 剩下的留白/裁剪交给打包器按用户选的"适配"方式处理
        '-vf', ("fps={0},scale=w={1}:h={2}:force_original_aspect_ratio=decrease" -f $Fps, $W, $H),
        '-frames:v', "$MaxFrames",
        '-y', $OutPattern
    )
}

# ---- 路线 1：ffmpeg ----
function Expand-Video-FFmpeg {
    param([string]$Path, [string]$OutDir, [int]$Fps, [int]$W, [int]$H,
          [int]$MaxFrames, [Action[int, string]]$Progress)

    $ff = Find-FFmpeg
    if (-not $ff) { return $null }

    Remove-Item -LiteralPath $OutDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $pat = Join-Path $OutDir 'v%05d.png'

    # 注意：不要把参数变量叫 $args —— 那是 PowerShell 的自动变量
    $ffArgs = Get-FFmpegArgs -InputPath $Path -OutPattern $pat -Fps $Fps -W $W -H $H -MaxFrames $MaxFrames
    if ($Progress) { $Progress.Invoke(3, '调用 ffmpeg 拆帧…') }
    Add-Log "ffmpeg: $ff"
    # 启动失败（文件损坏 / 架构不对 / 被安全策略拦）也要能回退，
    # 不能把异常直接甩给用户
    $outTxt = $null; $rc = -1
    $prevEap = $ErrorActionPreference
    try {
        # ffmpeg 会把信息写到 stderr。在 $ErrorActionPreference='Stop' 下
        # PowerShell 会把原生程序的 stderr 输出当成**终止错误**抛出来，
        # 于是"跑成功了但打了个警告"会被误判成失败、白白丢掉已拆好的帧。
        # 所以这里临时放宽到 Continue。
        $ErrorActionPreference = 'Continue'
        $outTxt = & $ff @ffArgs 2>&1
        $rc = $LASTEXITCODE
    } catch {
        Add-Log "ffmpeg 启动失败：$($_.Exception.Message)" 'warn'
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $files = @(Get-ChildItem -LiteralPath $OutDir -Filter 'v*.png' -File -ErrorAction SilentlyContinue |
               Sort-Object Name | Select-Object -ExpandProperty FullName)
    if ($files.Count -eq 0) {
        Add-Log "ffmpeg 没有产出任何帧（退出码 $rc）" 'warn'
        if ($outTxt) { ($outTxt | Select-Object -First 6) | ForEach-Object { Add-Log "  ffmpeg: $_" 'warn' } }
        return $null
    }
    return [PSCustomObject]@{
        Frames = $files
        How = 'ffmpeg'
        Seconds = ($files.Count / [double]$Fps)
        Clamped = ($files.Count -ge $MaxFrames)
    }
}

# ---- 路线 2：WSL 里的 ffmpeg（有 WSL 就不用往 Windows 侧装东西） ----
#
#  为什么不用 Windows 自带的 Media Foundation：
#  MediaComposition.GetThumbnailAsync 确实能按时间取帧，但要先把 MediaClip
#  塞进 MediaComposition.Clips —— 那是个 WinRT 的 IVector<MediaClip>，
#  在 PowerShell 5.1 里只能拿到裸 __ComObject，Add/Append 都调不到
#  （实测 "does not contain a method named 'Add'"）。
#  MediaClip 自己又没有 GetThumbnailAsync。所以这条路在 PowerShell 里走不通，
#  改用 WSL 里现成的 ffmpeg。命令行与 Windows 版完全一致，只是路径要转换。

function ConvertTo-WslPath {
    param([string]$WinPath)
    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
    }
    return $p
}

function Test-WslFFmpeg {
    if ($script:WslFF -eq 'no') { return $false }
    if ($script:WslFF) { return $true }
    $script:WslFF = 'no'
    try {
        $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
        if (-not (Test-Path -LiteralPath $wsl)) { return $false }
        $null = & $wsl -e sh -c 'command -v ffmpeg' 2>&1
        if ($LASTEXITCODE -eq 0) { $script:WslFF = $wsl; return $true }
    } catch { }
    return $false
}

function Expand-Video-WSL {
    param([string]$Path, [string]$OutDir, [int]$Fps, [int]$W, [int]$H,
          [int]$MaxFrames, [Action[int, string]]$Progress)

    if (-not (Test-WslFFmpeg)) { return $null }

    Remove-Item -LiteralPath $OutDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $pat = Join-Path $OutDir 'v%05d.png'

    $wslArgs = @('-e', 'ffmpeg') + (Get-FFmpegArgs -InputPath (ConvertTo-WslPath $Path) `
                                     -OutPattern (ConvertTo-WslPath $pat) `
                                     -Fps $Fps -W $W -H $H -MaxFrames $MaxFrames)
    if ($Progress) { $Progress.Invoke(3, '调用 WSL 里的 ffmpeg 拆帧…') }
    Add-Log "WSL: $($script:WslFF) -e ffmpeg  $($wslArgs[4])"
    $outTxt = $null; $rc = -1
    $prevEap2 = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'   # 同上：原生程序的 stderr 不能当致命错误
        $outTxt = & $script:WslFF @wslArgs 2>&1
        $rc = $LASTEXITCODE
    } catch {
        Add-Log "调 WSL 失败：$($_.Exception.Message)" 'warn'
        return $null
    } finally {
        $ErrorActionPreference = $prevEap2
    }
    $files = @(Get-ChildItem -LiteralPath $OutDir -Filter 'v*.png' -File -ErrorAction SilentlyContinue |
               Sort-Object Name | Select-Object -ExpandProperty FullName)
    if ($files.Count -eq 0) {
        Add-Log "WSL 里的 ffmpeg 没有产出任何帧（退出码 $rc）" 'warn'
        if ($outTxt) { ($outTxt | Select-Object -First 6) | ForEach-Object { Add-Log "  wsl: $_" 'warn' } }
        return $null
    }
    return [PSCustomObject]@{
        Frames = $files
        How = 'WSL ffmpeg'
        Seconds = ($files.Count / [double]$Fps)
        Clamped = ($files.Count -ge $MaxFrames)
    }
}

function Show-VideoHelp {
    param([string]$Path)
    $ffDir = $GuiDir
    $msg = @"
没法从这个视频里取帧：

  $([IO.Path]::GetFileName($Path))

程序先找 Windows 侧的 ffmpeg.exe，又试了 WSL 里的 ffmpeg，都没成功。

───────────────────────────────────────────────
 办法一（推荐，一次解决所有视频格式）
───────────────────────────────────────────────
 下载 ffmpeg，把 ffmpeg.exe 单独拷到：

   $ffDir
 然后重新添加视频即可，程序会自动发现它。

 下载：https://www.gyan.dev/ffmpeg/builds/
       选 ffmpeg-release-essentials.zip
       解压后从 bin\ 目录里把 ffmpeg.exe 拿出来

 放好之后不需要重启程序，直接再点一次「添加图片」就行。

───────────────────────────────────────────────
 办法二（不用下载任何东西）
───────────────────────────────────────────────
 你已经装了 WSL 的话，在 Ubuntu 里装一个 ffmpeg 就行，
 程序会自动发现并使用它（不需要往 Windows 侧拷任何东西）：

   wsl -e sudo apt update && wsl -e sudo apt install -y ffmpeg

 装完不需要重启程序，直接再点一次「添加图片」。

 或者把视频转成 GIF，用「添加图片」选那个 GIF ——
 GIF 拆帧用的是系统自带能力，完全不需要外部程序。
 （GIF 只有 256 色，有明显渐变的画面会出现色带）

───────────────────────────────────────────────
 排错
───────────────────────────────────────────────
 * 视频编码必须是系统能解的（H.264 / HEVC / VP9 一般没问题；
   某些 AV1 或专业编码需要装对应的解码器）
 * 详情看主窗口下面的日志
"@
    Add-Log '两条拆帧路线都失败了，已弹出说明' 'err'
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'BootAnim - 视频拆帧',
        'OK', 'Information')
}

# 视频拆帧总入口：ffmpeg 优先（快且稳），WinRT 兜底（不用下载）
function Expand-VideoFile {
    param([string]$Path, [int]$Fps, [int]$W, [int]$H, [Action[int, string]]$Progress)

    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $base = Join-Path $script:FrameDir ('vid_' + $stem)
    $max = $script:VideoMaxFrames
    Add-Log "视频拆帧：$([IO.Path]::GetFileName($Path))  目标 $Fps fps，上限 $max 帧"

    $r = Expand-Video-FFmpeg -Path $Path -OutDir (Join-Path $base 'ff') -Fps $Fps `
                             -W $W -H $H -MaxFrames $max -Progress $Progress
    if ($r) {
        Add-Log "ffmpeg 拆出 $($r.Frames.Count) 帧（约 $([Math]::Round($r.Seconds,1)) 秒素材）" 'ok'
        return $r
    }

    if ($Progress) { $Progress.Invoke(1, '试 WSL 里的 ffmpeg…') }
    $r = Expand-Video-WSL -Path $Path -OutDir (Join-Path $base 'wsl') -Fps $Fps `
                          -W $W -H $H -MaxFrames $max -Progress $Progress
    if ($r) {
        Add-Log "WSL 里的 ffmpeg 拆出 $($r.Frames.Count) 帧（约 $([Math]::Round($r.Seconds,1)) 秒素材）" 'ok'
        return $r
    }

    Add-Log 'ffmpeg.exe 和 WSL 里的 ffmpeg 都不可用，无法拆帧' 'warn'
    return $null
}

# =====================================================================
#  界面
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'BootAnim 开机动画管理工具'
$form.Size          = New-Object System.Drawing.Size(820, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(760, 700)
try {
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
} catch {
    try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9) } catch { }
}

# ---------- 状态 ----------
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = '状态'
$grpStatus.Location = New-Object System.Drawing.Point(10, 8)
$grpStatus.Size = New-Object System.Drawing.Size(782, 108)
$form.Controls.Add($grpStatus)

$script:LblStatus = New-Object System.Windows.Forms.Label
$script:LblStatus.Location = New-Object System.Drawing.Point(12, 22)
$script:LblStatus.Size = New-Object System.Drawing.Size(756, 20)
$grpStatus.Controls.Add($script:LblStatus)

$script:LblAnim = New-Object System.Windows.Forms.Label
$script:LblAnim.Location = New-Object System.Drawing.Point(12, 46)
$script:LblAnim.Size = New-Object System.Drawing.Size(756, 20)
$grpStatus.Controls.Add($script:LblAnim)

$script:LblCfg = New-Object System.Windows.Forms.Label
$script:LblCfg.Location = New-Object System.Drawing.Point(12, 68)
$script:LblCfg.Size = New-Object System.Drawing.Size(756, 18)
$script:LblCfg.ForeColor = 'DimGray'
$grpStatus.Controls.Add($script:LblCfg)

$script:LblOrig = New-Object System.Windows.Forms.Label
$script:LblOrig.Location = New-Object System.Drawing.Point(12, 86)
$script:LblOrig.Size = New-Object System.Drawing.Size(756, 18)
$script:LblOrig.ForeColor = 'DimGray'
$grpStatus.Controls.Add($script:LblOrig)

# ---------- 启用 / 禁用 ----------
$grpPower = New-Object System.Windows.Forms.GroupBox
$grpPower.Text = '动画开关（不用卸载，改一行配置即可）'
$grpPower.Location = New-Object System.Drawing.Point(10, 122)
$grpPower.Size = New-Object System.Drawing.Size(782, 62)
$form.Controls.Add($grpPower)

$script:RadEnable = New-Object System.Windows.Forms.RadioButton
$script:RadEnable.Text = '启用（开机播放动画）'
$script:RadEnable.Location = New-Object System.Drawing.Point(18, 24)
$script:RadEnable.Size = New-Object System.Drawing.Size(180, 22)
$grpPower.Controls.Add($script:RadEnable)

$script:RadDisable = New-Object System.Windows.Forms.RadioButton
$script:RadDisable.Text = '禁用（跳过动画，直接进 Windows）'
$script:RadDisable.Location = New-Object System.Drawing.Point(210, 24)
$script:RadDisable.Size = New-Object System.Drawing.Size(260, 22)
$grpPower.Controls.Add($script:RadDisable)

$script:BtnApplyPower = New-Object System.Windows.Forms.Button
$script:BtnApplyPower.Text = '应用'
$script:BtnApplyPower.Location = New-Object System.Drawing.Point(690, 21)
$script:BtnApplyPower.Size = New-Object System.Drawing.Size(78, 26)
$grpPower.Controls.Add($script:BtnApplyPower)

# ---------- 帧图片 ----------
$grpImages = New-Object System.Windows.Forms.GroupBox
$grpImages.Text = '帧图片（选好图片 -> 生成动画 -> 写进 ESP）'
$grpImages.Location = New-Object System.Drawing.Point(10, 190)
$grpImages.Size = New-Object System.Drawing.Size(782, 336)
$form.Controls.Add($grpImages)

$btnAddFiles = New-Object System.Windows.Forms.Button
$btnAddFiles.Text = '添加图片…'
$btnAddFiles.Location = New-Object System.Drawing.Point(12, 22)
$btnAddFiles.Size = New-Object System.Drawing.Size(96, 26)
$grpImages.Controls.Add($btnAddFiles)

$btnAddDir = New-Object System.Windows.Forms.Button
$btnAddDir.Text = '添加文件夹…'
$btnAddDir.Location = New-Object System.Drawing.Point(114, 22)
$btnAddDir.Size = New-Object System.Drawing.Size(106, 26)
$grpImages.Controls.Add($btnAddDir)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = '上移'
$btnUp.Location = New-Object System.Drawing.Point(226, 22)
$btnUp.Size = New-Object System.Drawing.Size(60, 26)
$grpImages.Controls.Add($btnUp)

$btnDown = New-Object System.Windows.Forms.Button
$btnDown.Text = '下移'
$btnDown.Location = New-Object System.Drawing.Point(290, 22)
$btnDown.Size = New-Object System.Drawing.Size(60, 26)
$grpImages.Controls.Add($btnDown)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = '移除选中'
$btnRemove.Location = New-Object System.Drawing.Point(354, 22)
$btnRemove.Size = New-Object System.Drawing.Size(84, 26)
$grpImages.Controls.Add($btnRemove)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空'
$btnClear.Location = New-Object System.Drawing.Point(442, 22)
$btnClear.Size = New-Object System.Drawing.Size(60, 26)
$grpImages.Controls.Add($btnClear)

$btnDemo = New-Object System.Windows.Forms.Button
$btnDemo.Text = '生成示例动画…'
$btnDemo.Location = New-Object System.Drawing.Point(650, 22)
$btnDemo.Size = New-Object System.Drawing.Size(120, 26)
$grpImages.Controls.Add($btnDemo)

$script:LstImages = New-Object System.Windows.Forms.ListBox
$script:LstImages.Location = New-Object System.Drawing.Point(12, 56)
$script:LstImages.Size = New-Object System.Drawing.Size(380, 172)
$script:LstImages.SelectionMode = 'MultiExtended'
$script:LstImages.AllowDrop = $true
$grpImages.Controls.Add($script:LstImages)

$script:PicPreview = New-Object System.Windows.Forms.PictureBox
$script:PicPreview.Location = New-Object System.Drawing.Point(404, 56)
$script:PicPreview.Size = New-Object System.Drawing.Size(366, 172)
$script:PicPreview.BorderStyle = 'FixedSingle'
$script:PicPreview.SizeMode = 'Zoom'
$script:PicPreview.BackColor = [System.Drawing.Color]::Black
$grpImages.Controls.Add($script:PicPreview)

$script:LblPreview = New-Object System.Windows.Forms.Label
$script:LblPreview.Text = '（未选择图片）'
$script:LblPreview.Location = New-Object System.Drawing.Point(404, 232)
$script:LblPreview.Size = New-Object System.Drawing.Size(366, 18)
$script:LblPreview.ForeColor = 'DimGray'
$grpImages.Controls.Add($script:LblPreview)

# 「N 张 -> 多少秒 -> 多大」的实时预估
$script:LblEst = New-Object System.Windows.Forms.Label
$script:LblEst.Text = ''
$script:LblEst.Location = New-Object System.Drawing.Point(12, 316)
$script:LblEst.Size = New-Object System.Drawing.Size(756, 20)
$script:LblEst.ForeColor = 'SteelBlue'
$grpImages.Controls.Add($script:LblEst)

# --- 选项行 ---
$lblW = New-Object System.Windows.Forms.Label
$lblW.Text = '分辨率'
$lblW.Location = New-Object System.Drawing.Point(12, 262)
$lblW.Size = New-Object System.Drawing.Size(52, 20)
$grpImages.Controls.Add($lblW)

$script:NumW = New-Object System.Windows.Forms.NumericUpDown
$script:NumW.Location = New-Object System.Drawing.Point(64, 259)
$script:NumW.Size = New-Object System.Drawing.Size(66, 24)
$script:NumW.Minimum = 16; $script:NumW.Maximum = 8192; $script:NumW.Value = 1920
$grpImages.Controls.Add($script:NumW)

$lblX = New-Object System.Windows.Forms.Label
$lblX.Text = 'x'
$lblX.Location = New-Object System.Drawing.Point(133, 262)
$lblX.Size = New-Object System.Drawing.Size(12, 20)
$grpImages.Controls.Add($lblX)

$script:NumH = New-Object System.Windows.Forms.NumericUpDown
$script:NumH.Location = New-Object System.Drawing.Point(147, 259)
$script:NumH.Size = New-Object System.Drawing.Size(66, 24)
$script:NumH.Minimum = 16; $script:NumH.Maximum = 8192; $script:NumH.Value = 1080
$grpImages.Controls.Add($script:NumH)

$btnScreen = New-Object System.Windows.Forms.Button
$btnScreen.Text = '用屏幕分辨率'
$btnScreen.Location = New-Object System.Drawing.Point(219, 258)
$btnScreen.Size = New-Object System.Drawing.Size(104, 26)
$grpImages.Controls.Add($btnScreen)

$lblFps = New-Object System.Windows.Forms.Label
$lblFps.Text = '帧率'
$lblFps.Location = New-Object System.Drawing.Point(336, 262)
$lblFps.Size = New-Object System.Drawing.Size(34, 20)
$grpImages.Controls.Add($lblFps)

$script:NumFps = New-Object System.Windows.Forms.NumericUpDown
$script:NumFps.Location = New-Object System.Drawing.Point(372, 259)
$script:NumFps.Size = New-Object System.Drawing.Size(56, 24)
$script:NumFps.Minimum = 1; $script:NumFps.Maximum = 240; $script:NumFps.Value = 30
$grpImages.Controls.Add($script:NumFps)

$lblFit = New-Object System.Windows.Forms.Label
$lblFit.Text = '适配'
$lblFit.Location = New-Object System.Drawing.Point(440, 262)
$lblFit.Size = New-Object System.Drawing.Size(34, 20)
$grpImages.Controls.Add($lblFit)

$script:CboFit = New-Object System.Windows.Forms.ComboBox
$script:CboFit.DropDownStyle = 'DropDownList'
$script:CboFit.Location = New-Object System.Drawing.Point(476, 259)
$script:CboFit.Size = New-Object System.Drawing.Size(118, 24)
[void]$script:CboFit.Items.AddRange(@('contain 完整显示', 'cover 裁剪填满', 'stretch 拉伸', 'none 不缩放'))
$script:CboFit.SelectedIndex = 0
$grpImages.Controls.Add($script:CboFit)

$lblBg = New-Object System.Windows.Forms.Label
$lblBg.Text = '背景'
$lblBg.Location = New-Object System.Drawing.Point(604, 262)
$lblBg.Size = New-Object System.Drawing.Size(34, 20)
$grpImages.Controls.Add($lblBg)

$script:BtnBg = New-Object System.Windows.Forms.Button
$script:BtnBg.Text = '#000000'
$script:BtnBg.Location = New-Object System.Drawing.Point(640, 258)
$script:BtnBg.Size = New-Object System.Drawing.Size(80, 26)
$script:BtnBg.BackColor = [System.Drawing.Color]::Black
$script:BtnBg.ForeColor = [System.Drawing.Color]::White
$grpImages.Controls.Add($script:BtnBg)

$script:ChkRle = New-Object System.Windows.Forms.CheckBox
$script:ChkRle.Text = 'RLE 压缩'
$script:ChkRle.Checked = $true
$script:ChkRle.Location = New-Object System.Drawing.Point(12, 292)
$script:ChkRle.Size = New-Object System.Drawing.Size(100, 22)
$grpImages.Controls.Add($script:ChkRle)

$script:BtnPack = New-Object System.Windows.Forms.Button
$script:BtnPack.Text = '生成动画并写入 ESP'
$script:BtnPack.Location = New-Object System.Drawing.Point(600, 288)
$script:BtnPack.Size = New-Object System.Drawing.Size(170, 30)
$script:BtnPack.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$grpImages.Controls.Add($script:BtnPack)

$script:Prg = New-Object System.Windows.Forms.ProgressBar
$script:Prg.Location = New-Object System.Drawing.Point(120, 294)
$script:Prg.Size = New-Object System.Drawing.Size(470, 20)
$grpImages.Controls.Add($script:Prg)

# ---------- 引导接管 ----------
$grpBoot = New-Object System.Windows.Forms.GroupBox
$grpBoot.Text = 'Windows 引导接管（开机时先跑本程序，再交回 bootmgfw）'
$grpBoot.Location = New-Object System.Drawing.Point(10, 532)
$grpBoot.Size = New-Object System.Drawing.Size(782, 62)
$form.Controls.Add($grpBoot)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '安装接管'
$btnInstall.Location = New-Object System.Drawing.Point(12, 22)
$btnInstall.Size = New-Object System.Drawing.Size(96, 28)
$grpBoot.Controls.Add($btnInstall)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = '卸载（还原原版引导）'
$btnUninstall.Location = New-Object System.Drawing.Point(114, 22)
$btnUninstall.Size = New-Object System.Drawing.Size(160, 28)
$grpBoot.Controls.Add($btnUninstall)

$btnOpenAnim = New-Object System.Windows.Forms.Button
$btnOpenAnim.Text = '打开 ESP 动画目录'
$btnOpenAnim.Location = New-Object System.Drawing.Point(280, 22)
$btnOpenAnim.Size = New-Object System.Drawing.Size(150, 28)
$grpBoot.Controls.Add($btnOpenAnim)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = '刷新状态'
$btnReload.Location = New-Object System.Drawing.Point(436, 22)
$btnReload.Size = New-Object System.Drawing.Size(90, 28)
$grpBoot.Controls.Add($btnReload)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'
$btnExit.Location = New-Object System.Drawing.Point(680, 22)
$btnExit.Size = New-Object System.Drawing.Size(88, 28)
$grpBoot.Controls.Add($btnExit)

# ---------- 日志 ----------
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = '日志'
$grpLog.Location = New-Object System.Drawing.Point(10, 600)
$grpLog.Size = New-Object System.Drawing.Size(782, 112)
$form.Controls.Add($grpLog)

$script:LogBox = New-Object System.Windows.Forms.ListBox
$script:LogBox.Location = New-Object System.Drawing.Point(12, 20)
$script:LogBox.Size = New-Object System.Drawing.Size(756, 82)
$script:LogBox.HorizontalScrollbar = $true
$grpLog.Controls.Add($script:LogBox)

# =====================================================================
#  事件
# =====================================================================
$btnAddFiles.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = '选择图片 / GIF / 视频（GIF 和多帧 TIFF 会自动拆帧，视频会用 ffmpeg 或系统解码器拆帧）'
        $dlg.Filter = ('图片/动图/视频|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp;' +
                       '*.mp4;*.m4v;*.mov;*.wmv;*.avi;*.mkv;*.webm|' +
                       '图片|*.png;*.jpg;*.jpeg;*.bmp;*.webp|' +
                       '多帧动图|*.gif;*.tif;*.tiff|' +
                       '视频|*.mp4;*.m4v;*.mov;*.wmv;*.avi;*.mkv;*.webm|所有文件|*.*')
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $picked = @(Sort-FileNames -Names $dlg.FileNames)
        $r = Add-ImageFiles -Paths $picked
        if ($r.VideoFrames -gt 0) {
            Add-Log "加入 $($r.Added) 张，其中 $($r.VideoFrames) 张从视频拆出" 'ok'
        } elseif ($r.GifFrames -gt 0) {
            Add-Log "加入 $($r.Added) 张，其中 $($r.GifFrames) 张是从多帧文件拆出来的" 'ok'
        } else {
            Add-Log "加入 $($r.Added) 张图片"
        }
        Update-ImageList
        Invoke-FpsSuggest -AvgDelay $r.AvgDelay
    } catch {
        Show-Error '添加图片失败' $_.Exception.Message
    }
})

$btnAddDir.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择装着帧图片的文件夹'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $exts = @('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff', '.webp') + $script:VideoExts
        $found = @(Get-ChildItem -LiteralPath $dlg.SelectedPath -File |
                   Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } |
                   Select-Object -ExpandProperty FullName)
        if ($found.Count -eq 0) {
            Show-Error '没有图片' "$($dlg.SelectedPath) 里没有找到任何图片文件。"
            return
        }
        $picked = @(Sort-FileNames -Names $found)
        $r = Add-ImageFiles -Paths $picked
        if ($r.GifFrames -gt 0) {
            Add-Log "从文件夹加入 $($r.Added) 张，其中 $($r.GifFrames) 张是拆帧得到的" 'ok'
        } else {
            Add-Log "从文件夹加入 $($r.Added) 张图片" 'ok'
        }
        Update-ImageList
        Invoke-FpsSuggest -AvgDelay $r.AvgDelay
    } catch {
        Show-Error '添加文件夹失败' $_.Exception.Message
    }
})

$btnUp.Add_Click({
    if ($script:LstImages.SelectedIndex -lt 1) { return }
    $i = $script:LstImages.SelectedIndex
    $tmp = $script:Images[$i]
    $script:Images.RemoveAt($i)
    $script:Images.Insert($i - 1, $tmp)
    Update-ImageList
    $script:LstImages.SelectedIndex = $i - 1
})

$btnDown.Add_Click({
    $i = $script:LstImages.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:Images.Count - 1) { return }
    $tmp = $script:Images[$i]
    $script:Images.RemoveAt($i)
    $script:Images.Insert($i + 1, $tmp)
    Update-ImageList
    $script:LstImages.SelectedIndex = $i + 1
})

$btnRemove.Add_Click({
    $sel = @($script:LstImages.SelectedIndices)
    if ($sel.Count -eq 0) { return }
    [array]::Sort($sel)
    [array]::Reverse($sel)
    foreach ($i in $sel) { $script:Images.RemoveAt($i) }
    Update-ImageList
})

$btnClear.Add_Click({
    $script:Images.Clear()
    Update-ImageList
    Add-Log '已清空图片列表'
})

$script:LstImages.Add_SelectedIndexChanged({
    if ($script:LstImages.SelectedIndex -ge 0) {
        try {
            $img = [System.Drawing.Image]::FromFile($script:Images[$script:LstImages.SelectedIndex])
            if ($script:PicPreview.Image) { $script:PicPreview.Image.Dispose() }
            $script:PicPreview.Image = $img
            $script:LblPreview.Text = "$($script:LstImages.SelectedItem)  ($($img.Width)x$($img.Height))"
        } catch { }
    }
})

$btnScreen.Add_Click({
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $script:NumW.Value = $b.Width
        $script:NumH.Value = $b.Height
        Add-Log "已填入当前屏幕分辨率 $($b.Width)x$($b.Height)"
    } catch { }
})

# 分辨率/帧率一变，预估就跟着更新
$script:NumW.Add_ValueChanged({ Update-Estimate })
$script:NumH.Add_ValueChanged({ Update-Estimate })
$script:NumFps.Add_ValueChanged({ Update-Estimate })

# 如果帧是从 GIF 拆出来的，按它的原始帧间隔建议一个帧率
function Invoke-FpsSuggest {
    param([int]$AvgDelay)
    if ($AvgDelay -le 0) { return }
    $want = [int][Math]::Round(1000.0 / $AvgDelay)
    if ($want -lt 1) { $want = 1 }
    if ($want -gt 240) { $want = 240 }
    if ($want -eq [int]$script:NumFps.Value) {
        Add-Log "这些帧来自 GIF，原始帧率正好是 $want fps"
        return
    }
    $sec = $script:Images.Count / [double]$want
    $yes = [System.Windows.Forms.MessageBox]::Show(
        ("这些帧来自 GIF，原始帧间隔约 $AvgDelay ms，相当于 $want fps。`n`n" +
         "要把帧率从 $([int]$script:NumFps.Value) 改成 $want 吗？`n" +
         "（改成 $want fps 后，当前 $($script:Images.Count) 张 = 约 $([Math]::Round($sec,1)) 秒）"),
        'BootAnim 帧率建议', 'YesNo', 'Question')
    if ($yes -eq 'Yes') {
        $script:NumFps.Value = $want
        Add-Log "帧率已按 GIF 设为 $want fps" 'ok'
        Update-Estimate
    }
}

$script:BgColor = [System.Drawing.Color]::Black
$script:BgHex   = '000000'

$btnBg.Add_Click({
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.Color = $script:BgColor
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $script:BgColor = $dlg.Color
    $script:BgHex = ('{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
    $script:BtnBg.Text = '#' + $script:BgHex
    $script:BtnBg.BackColor = $dlg.Color
    $luma = 0.299 * $dlg.Color.R + 0.587 * $dlg.Color.G + 0.114 * $dlg.Color.B
    if ($luma -lt 128) { $script:BtnBg.ForeColor = [System.Drawing.Color]::White }
    else { $script:BtnBg.ForeColor = [System.Drawing.Color]::Black }
})

# ---- 生成并写入 ESP ----
$btnPack.Add_Click({
    if ($script:Images.Count -eq 0) {
        Show-Error '还没有图片' "先点「添加图片…」或「添加文件夹…」选一些图片。`n`n没有素材的话也可以点「生成示例动画…」。"
        return
    }
    if (-not (Connect-Esp)) {
        Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败，看日志里的具体原因。'
        return
    }
    if (-not (Initialize-PackerSafe)) { return }

    $w   = [int]$script:NumW.Value
    $h   = [int]$script:NumH.Value
    $fps = [int]$script:NumFps.Value
    $fit = @('contain', 'cover', 'stretch', 'none')[$script:CboFit.SelectedIndex]
    $rle = [bool]$script:ChkRle.Checked
    $files = [string[]]$script:Images.ToArray()

    $script:BtnPack.Enabled = $false
    $script:Prg.Value = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Add-Log "开始打包：$($files.Count) 帧，$w x $h，$fps fps，适配=$fit，RLE=$rle"

    $script:packTick = 0
    $progress = [Action[int, string]]{
        param($pct, $msg)
        $script:Prg.Value = [Math]::Min(100, [Math]::Max(0, $pct))
        $script:LblPreview.Text = "正在打包 $pct%  ($msg)"
        $script:packTick = ([int]$script:packTick + 1) % 3
        if ($script:packTick -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
    }

    try {
        [BootAnimGui.Packer]::Pack($files, $w, $h, $fps, $fit,
                                   $script:BgColor.R, $script:BgColor.G, $script:BgColor.B,
                                   $rle, $script:BaaTemp, $progress) | Out-Null
        $sw.Stop()
        $packedBytes = (Get-Item -LiteralPath $script:BaaTemp).Length
        $rawBytes = [double]$files.Count * [double]$w * [double]$h * 4.0
        if ($rawBytes -gt 0) { $script:LastRatio = $packedBytes / $rawBytes }
        $mb = $packedBytes / 1MB
        Add-Log ("打包完成：{0:N0} 帧，{1:N2} MiB，耗时 {2:N1} 秒" -f $files.Count, $mb, $sw.Elapsed.TotalSeconds) 'ok'

        # 写进 ESP（先写临时文件再改名，避免中途断电留下半个文件）
        $target = Join-Path $script:AnimDir 'anim.baa'
        if (-not (Test-Path -LiteralPath $script:AnimDir)) {
            New-Item -ItemType Directory -Force -Path $script:AnimDir | Out-Null
        }
        Copy-FileSafe -Source $script:BaaTemp -Dest $target
        Add-Log "已写入 $target" 'ok'
        if ($packedBytes -gt (32MB)) {
            Add-Log ("打包结果 {0:N1} MiB 超过 32 MiB：播放时会逐帧读 EFI 分区而不是走内存缓存，会变慢。想快就降分辨率或降帧率" -f ($packedBytes/1MB)) 'warn'
        }

        Set-CfgValue -Path (Join-Path $script:AnimDir 'bootanim.cfg') -Pairs @{
            'ANIM'    = 'anim.baa'
            'FPS'     = $fps
            'ENABLED' = 1
        }
        Add-Log '已更新 bootanim.cfg（ANIM / FPS / ENABLED=1）' 'ok'

        $script:Prg.Value = 100
        Refresh-Status
        Add-Log '完成。重启即可看到新动画。' 'ok'
        [void][System.Windows.Forms.MessageBox]::Show(
            "动画已写入 ESP。`n`n$w x $h    $($files.Count) 帧    $fps fps`n`n重启就能看到。",
            'BootAnim', 'OK', 'Information')
    } catch {
        Show-Error '打包失败' $_.Exception.Message
    } finally {
        $script:BtnPack.Enabled = $true
        Update-Preview
    }
})

# ---- 生成示例动画 ----
$btnDemo.Add_Click({
    if (-not (Connect-Esp)) {
        Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败，看日志里的具体原因。'
        return
    }
    if (-not (Initialize-PackerSafe)) { return }

    # 注意：这个对话框的控件全部放在 $script: 作用域。
    # PowerShell 的 scriptblock 不形成闭包，嵌套的事件处理器只能可靠地看到
    # script 作用域里的变量，用局部变量会在点击时变成 $null。
    $script:DlgDemo = New-Object System.Windows.Forms.Form
    $script:DlgDemo.Text = '生成示例动画'
    $script:DlgDemo.Size = New-Object System.Drawing.Size(370, 250)
    $script:DlgDemo.StartPosition = 'CenterParent'
    $script:DlgDemo.FormBorderStyle = 'FixedDialog'
    $script:DlgDemo.MaximizeBox = $false; $script:DlgDemo.MinimizeBox = $false
    $script:DlgDemo.Font = $form.Font

    $mk = {
        param($text, $y, $min, $max, $val)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point(20, ($y + 3))
        $l.Size = New-Object System.Drawing.Size(90, 20)
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Location = New-Object System.Drawing.Point(120, $y)
        $n.Size = New-Object System.Drawing.Size(90, 24)
        $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
        $script:DlgDemo.Controls.Add($l)
        $script:DlgDemo.Controls.Add($n)
        return $n
    }
    $script:DemoW   = & $mk '宽度' 20  160 7680 1920
    $script:DemoH   = & $mk '高度' 52  120 4320 1080
    $script:DemoF   = & $mk '帧数' 84  2   600  60
    $script:DemoFps = & $mk '帧率' 116 1   120  30

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '生成并写入 ESP'
    $ok.Location = New-Object System.Drawing.Point(60, 158)
    $ok.Size = New-Object System.Drawing.Size(140, 30)
    $script:DlgDemo.Controls.Add($ok)

    $cc = New-Object System.Windows.Forms.Button
    $cc.Text = '取消'
    $cc.Location = New-Object System.Drawing.Point(214, 158)
    $cc.Size = New-Object System.Drawing.Size(80, 30)
    $script:DlgDemo.Controls.Add($cc)
    $cc.Add_Click({ $script:DlgDemo.Close() })

    $ok.Add_Click({
        $dw = [int]$script:DemoW.Value
        $dh = [int]$script:DemoH.Value
        $df = [int]$script:DemoF.Value
        $dp = [int]$script:DemoFps.Value
        $script:DlgDemo.Enabled = $false
        $script:Prg.Value = 0
        $progress = [Action[int, string]]{
            param($pct, $msg)
            $script:Prg.Value = [Math]::Min(100, [Math]::Max(0, $pct))
            $script:LblPreview.Text = "正在生成 $pct%  ($msg)"
            [System.Windows.Forms.Application]::DoEvents()
        }
        try {
            Add-Log "生成示例动画：$dw x $dh, $df 帧, $dp fps"
            [BootAnimGui.Demo]::Generate($dw, $dh, $df, $dp, $script:BaaTemp, $progress) | Out-Null
            $target = Join-Path $script:AnimDir 'anim.baa'
            if (-not (Test-Path -LiteralPath $script:AnimDir)) {
                New-Item -ItemType Directory -Force -Path $script:AnimDir | Out-Null
            }
            Copy-FileSafe -Source $script:BaaTemp -Dest $target
            Set-CfgValue -Path (Join-Path $script:AnimDir 'bootanim.cfg') -Pairs @{
                'ANIM' = 'anim.baa'; 'FPS' = $dp; 'ENABLED' = 1
            }
            $script:Prg.Value = 100
            Refresh-Status
            Add-Log '示例动画已写入 ESP' 'ok'
            $script:DlgDemo.Close()
        } catch {
            $script:DlgDemo.Enabled = $true
            Show-Error '生成失败' $_.Exception.Message
        }
    })

    [void]$script:DlgDemo.ShowDialog($form)
    $script:DlgDemo.Dispose()
    $script:DlgDemo = $null
})

# ---- 启用 / 禁用 ----
$btnApplyPower.Add_Click({
    if (-not (Connect-Esp)) { Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败。'; return }
    $cfgPath = Join-Path $script:AnimDir 'bootanim.cfg'
    $want = if ($script:RadEnable.Checked) { '1' } else { '0' }
    try {
        if (-not (Test-Path -LiteralPath $script:AnimDir)) {
            New-Item -ItemType Directory -Force -Path $script:AnimDir | Out-Null
        }
        Set-CfgValue -Path $cfgPath -Pairs @{ 'ENABLED' = $want }
        if ($want -eq '1') { Add-Log '已启用开机动画' 'ok' } else { Add-Log '已禁用开机动画（开机直接进 Windows）' 'ok' }
        Refresh-Status
    } catch {
        Show-Error '写入配置失败' $_.Exception.Message
    }
})

# ---- 安装 / 卸载接管 ----
$btnInstall.Add_Click({
    $efi = Join-Path $DistDir 'bootanim.efi'
    if (-not (Test-Path -LiteralPath $efi)) {
        Show-Error '找不到 bootanim.efi' "没有找到：`n$efi`n`n请先编译（见 编译说明.md），或者把编译好的 bootanim.efi 放到 dist\ 目录下。"
        return
    }
    if (-not (Connect-Esp)) { Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败。'; return }

    $winBoot = Join-Path $script:EspPath 'EFI\Microsoft\Boot'
    $shim    = Join-Path $winBoot 'bootmgfw.efi'
    $orig    = Join-Path $winBoot 'bootmgfw-orig.efi'
    if (-not (Test-Path -LiteralPath $shim)) {
        Show-Error '不是 Windows 引导盘' "找不到 $shim"
        return
    }
    $yes = [System.Windows.Forms.MessageBox]::Show(
        "将要接管 Windows 引导程序：`n`n  备份  $shim`n        -> $orig`n  替换  $shim  <- bootanim.efi`n`n开机时会先播放动画，然后自动继续启动 Windows。`n`n确认继续？",
        'BootAnim 安装接管', 'YesNo', 'Question')
    if ($yes -ne 'Yes') { return }

    try {
        if (-not (Test-IsBootAnimLoader -Path $shim)) {
            if (-not (Test-Path -LiteralPath $orig)) {
                Copy-FileSafe -Source $shim -Dest $orig
                Add-Log '已备份原版引导 -> bootmgfw-orig.efi' 'ok'
            } else {
                Add-Log 'bootmgfw-orig.efi 已存在，保留' 'warn'
            }
        } else {
            Add-Log 'bootmgfw.efi 已经是 BootAnim，跳过备份'
        }
        if (-not (Test-Path -LiteralPath $orig)) { throw '没有可用的 bootmgfw-orig.efi，为了安全中止' }
        if (Test-IsBootAnimLoader -Path $orig) { throw 'bootmgfw-orig.efi 竟然也是 BootAnim，为了不死循环中止' }

        if (-not (Test-Path -LiteralPath $script:AnimDir)) {
            New-Item -ItemType Directory -Force -Path $script:AnimDir | Out-Null
        }
        Copy-FileSafe -Source $efi -Dest (Join-Path $script:AnimDir 'bootanim.efi')
        $cfgSrc = Join-Path $InstallDir 'bootanim.cfg'
        if ((Test-Path -LiteralPath $cfgSrc) -and
            (-not (Test-Path -LiteralPath (Join-Path $script:AnimDir 'bootanim.cfg')))) {
            Copy-FileSafe -Source $cfgSrc -Dest (Join-Path $script:AnimDir 'bootanim.cfg')
        }
        Copy-FileSafe -Source $efi -Dest $shim
        if (-not (Test-IsBootAnimLoader -Path $shim)) { throw '替换后校验失败' }
        Add-Log '安装接管完成' 'ok'
        Refresh-Status
        [void][System.Windows.Forms.MessageBox]::Show('安装完成，重启就能看到动画。' + "`n`n任何按键都可以跳过动画。",
            'BootAnim', 'OK', 'Information')
    } catch {
        Show-Error '安装失败' $_.Exception.Message
    }
})

$btnUninstall.Add_Click({
    if (-not (Connect-Esp)) { Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败。'; return }
    $winBoot = Join-Path $script:EspPath 'EFI\Microsoft\Boot'
    $shim    = Join-Path $winBoot 'bootmgfw.efi'
    $orig    = Join-Path $winBoot 'bootmgfw-orig.efi'

    if (-not (Test-IsBootAnimLoader -Path $shim)) {
        Add-Log 'bootmgfw.efi 不是 BootAnim，无需还原' 'warn'
        Refresh-Status
        return
    }
    if (-not (Test-Path -LiteralPath $orig)) {
        Show-Error '不能还原' "bootmgfw.efi 是 BootAnim，但找不到 bootmgfw-orig.efi。`n`n为避免机器开不了机，不会做任何修改。`n请用 Windows 恢复环境执行：bcdboot C:\Windows /s <ESP盘符>: /f UEFI"
        return
    }
    $yes = [System.Windows.Forms.MessageBox]::Show(
        "将还原原版引导程序：`n`n  $orig  ->  $shim`n`n还原后开机不再播放动画。素材文件会保留，随时可以再装回来。`n`n确认继续？",
        'BootAnim 卸载接管', 'YesNo', 'Question')
    if ($yes -ne 'Yes') { return }
    try {
        Copy-FileSafe -Source $orig -Dest $shim
        if (Test-IsBootAnimLoader -Path $shim) { throw '还原后校验失败' }
        Remove-Item -LiteralPath $orig -Force
        Add-Log '已还原原版引导，动画素材保留' 'ok'
        Refresh-Status
        [void][System.Windows.Forms.MessageBox]::Show('已还原。下次开机直接进 Windows。',
            'BootAnim', 'OK', 'Information')
    } catch {
        Show-Error '还原失败' $_.Exception.Message
    }
})

$btnOpenAnim.Add_Click({
    try {
        if (-not (Connect-Esp)) { Show-Error '连不上 ESP' '定位或挂载 EFI 系统分区失败。'; return }
        if (-not (Test-Path -LiteralPath $script:AnimDir)) {
            New-Item -ItemType Directory -Force -Path $script:AnimDir | Out-Null
        }
        Start-Process explorer.exe $script:AnimDir
    } catch {
        Show-Error '打开目录失败' $_.Exception.Message
    }
})

$btnReload.Add_Click({ Refresh-Status; Add-Log '已刷新状态' })

$btnExit.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    try { Disconnect-Esp } catch { }
    # 清掉 GIF 拆帧产生的临时 PNG（它们在本次会话里已经用完了）
    try { Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
})

$form.Add_Shown({
    Add-Log 'BootAnim 管理工具已启动'
    if (Test-Path -LiteralPath (Join-Path $DistDir 'bootanim.efi')) {
        Add-Log "找到 $(Join-Path $DistDir 'bootanim.efi')" 'ok'
    } else {
        Add-Log "dist\bootanim.efi 不存在（「安装接管」会不可用，需要先编译）" 'warn'
    }
    # 视频拆帧能力预检：提前告诉用户走哪条路
    $ff = Find-FFmpeg
    if ($ff) {
        Add-Log "找到 ffmpeg.exe，视频拆帧走它：$ff" 'ok'
    } elseif (Test-WslFFmpeg) {
        Add-Log 'Windows 侧没有 ffmpeg.exe，但 WSL 里有，视频拆帧会走 WSL' 'ok'
    } else {
        Add-Log '没有可用的 ffmpeg（Windows 侧和 WSL 都没有）；视频拆帧会不可用，GIF 不受影响' 'warn'
    }
    if (Connect-Esp) {
        Refresh-Status
        $cfg = Read-Cfg -Path (Join-Path $script:AnimDir 'bootanim.cfg')
        if ($cfg.Anim) { Add-Log "当前配置 ANIM=$($cfg.Anim)  ENABLED=$(if($cfg.Enabled){1}else{0})" }
    }
    Update-ImageList
})

# ---------------------------------------------------------------------
#  辅助
# ---------------------------------------------------------------------
function Initialize-PackerSafe {
    if ($script:PackerReady) { return $true }
    Add-Log '正在准备图像打包内核（首次约 1~2 秒，用系统自带的 C# 编译器）…'
    try {
        Initialize-BootAnimPacker
        $script:PackerReady = $true
        Add-Log '图像打包内核就绪' 'ok'
        return $true
    } catch {
        Show-Error '内核编译失败' ("无法在内存里编译 C# 打包内核。" + "`n`n" + $_.Exception.Message +
            "`n`n请确认用的是 Windows PowerShell 5.1（powershell.exe），而不是 PowerShell 7。")
        return $false
    }
}

# 自然排序：frame2 排在 frame10 前面
function Sort-FileNames {
    param([string[]]$Names)
    return @($Names | Sort-Object -Property @{
        Expression = {
            $n = [IO.Path]::GetFileNameWithoutExtension($_)
            [regex]::Replace($n, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
        }
    })
}

[void]$form.ShowDialog()
$form.Dispose()
