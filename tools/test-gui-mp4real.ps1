# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  test-gui-mp4real.ps1 -- 用真实的 ffmpeg 和真实的视频做端到端验证
#
#  和 test-gui-video.ps1 的区别：
#    那个用"桩 ffmpeg"验证接线（参数拼装、帧收集、顺序、上限）；
#    这个用**真的 ffmpeg + 真的 MP4**跑完整链路：
#      Find-FFmpeg 找得到 -> ffmpeg 真的解码 -> 帧真的落盘
#      -> 真的打包成 .baa -> 用 Python 参考解码器校验
#
#  找不到 ffmpeg 或找不到视频时会优雅跳过（不算失败）。
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File tools\test-gui-mp4real.ps1
#    powershell ... -File tools\test-gui-mp4real.ps1 -Video D:\a.mp4 -Frames 40
# =====================================================================
[CmdletBinding()]
param(
    [string]$Video = '',
    [int]$Frames = 30,
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$Fps = 30
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'find-python.ps1')
$Py = Find-Python
if (-not $Py) {
    Write-Host '本测试需要 Python 3/Pillow 做校验。没找到，跳过。' -ForegroundColor Yellow
    exit 0
}

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$GuiDir = Join-Path $Root 'gui'
$Gui = Join-Path $GuiDir 'BootAnimGUI.ps1'

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Check($cond, $what) {
    if ($cond) { $script:pass++; Write-Host "  [OK]   $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}
function Skip($what) { $script:skip++; Write-Host "  [跳过] $what" -ForegroundColor Yellow }

Write-Host '真实 ffmpeg + 真实视频 的端到端验证'
Write-Host ''

# ---------------------------------------------------------------- 抽函数
Write-Host '[1] 从 GUI 脚本抽出视频相关函数'
$toks = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count) {
    Check $false 'GUI 脚本有语法错误'
    $errs | ForEach-Object { Write-Host "    line $($_.Extent.StartLineNumber): $($_.Message)" }
    exit 1
}
$want = @('Initialize-FrameDir', 'Find-FFmpeg', 'Get-FFmpegArgs', 'Expand-Video-FFmpeg',
          'ConvertTo-WslPath', 'Test-WslFFmpeg', 'Expand-Video-WSL', 'Expand-VideoFile')
$all = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$src = ''
foreach ($f in $all) { if ($want -contains $f.Name) { $src += $f.Extent.Text + "`n`n" } }

$ProjRoot = $Root
$script:VideoExts = @('.mp4', '.m4v', '.mov', '.wmv', '.avi', '.mkv', '.webm', '.mpg', '.mpeg')
$script:VideoMaxFrames = 1200
$script:WslFF = 'no'
$script:FFmpegPath = $null
$script:logLines = New-Object System.Collections.ArrayList
Invoke-Expression $src
function Add-Log { param([string]$Text, [string]$Level = 'info') [void]$script:logLines.Add("[$Level] $Text") }

# 用 GUI 自己的逻辑选拆帧目录。这一步本身也是被测对象：
# 拆帧目录不能落在 %TEMP%（实测 ffmpeg 往那儿写会被策略拦成 Permission denied）
$script:FrameDir = Initialize-FrameDir
Write-Host "    拆帧目录: $script:FrameDir"
if ($script:FrameDir -like "*$env:TEMP*") {
    $script:fail++
    Write-Host '  [FAIL] 拆帧目录落在 %TEMP% 里了，ffmpeg 很可能写不进去' -ForegroundColor Red
} else {
    $script:pass++
    Write-Host '  [OK]   拆帧目录不在 %TEMP%（避开会被策略拦的路径）' -ForegroundColor Green
}
$Tmp = Join-Path $script:FrameDir ('mp4real_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

# ---------------------------------------------------------------- 找 ffmpeg
Write-Host ''
Write-Host '[2] Find-FFmpeg 能不能找到你下载的那个'
$ff = Find-FFmpeg
if (-not $ff) {
    Skip '本机没找到 ffmpeg.exe，整个测试跳过'
    Write-Host "`n$($script:pass) passed, $($script:fail) failed, $($script:skip) skipped"
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
Write-Host "    找到: $ff"
Check (Test-Path -LiteralPath $ff) '返回的路径确实存在'
Check ($ff -like '*essentials_build\bin\ffmpeg.exe') '正是压缩包里的 bin\ffmpeg.exe（浅层递归搜索生效）'

$ver = & $ff -hide_banner -version 2>&1 | Select-Object -First 1
Write-Host "    版本: $ver"
Check ("$ver" -match 'ffmpeg version') 'ffmpeg 能正常执行'

# ---------------------------------------------------------------- 找视频
Write-Host ''
Write-Host '[3] 找一个真实视频'
if (-not $Video) {
    $cands = @()
    foreach ($d in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads",
                     "$env:USERPROFILE\Videos", "$env:PUBLIC\Videos")) {
        if (Test-Path -LiteralPath $d) {
            $cands += @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                        Where-Object { $script:VideoExts -contains $_.Extension.ToLowerInvariant() })
        }
    }
    if ($cands.Count -gt 0) {
        $Video = ($cands | Sort-Object Length | Select-Object -First 1).FullName
    }
}
if (-not $Video -or -not (Test-Path -LiteralPath $Video)) {
    Skip '本机没找到测试视频，跳过真实解码部分'
    Write-Host ''
    Write-Host '========================================================='
    $tail = if ($script:skip -gt 0) { ", $($script:skip) skipped" } else { '' }
    Write-Host "$($script:pass) passed, $($script:fail) failed$tail" -ForegroundColor Green
    Write-Host '========================================================='
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue
    exit $(if ($script:fail -eq 0) { 0 } else { 1 })
}
$vinfo = Get-Item -LiteralPath $Video
Write-Host "    视频: $($vinfo.Name)  ($([int]($vinfo.Length/1MB)) MB)"

# 顺便量一下源视频的分辨率/时长（用 ffmpeg 自己报，不依赖 ffprobe）
# ffmpeg 把信息写到 stderr，EAP=Stop 时会被当成终止错误，临时放宽
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$probeTxt = & $ff -hide_banner -i $Video 2>&1
$ErrorActionPreference = $prevEap
$durLine = @($probeTxt | Where-Object { "$_" -match 'Duration' })[0]
$vidLine = @($probeTxt | Where-Object { "$_" -match 'Video:' })[0]
if ($durLine) { Write-Host "    $("$durLine".Trim())" }
if ($vidLine) { Write-Host "    $("$vidLine".Trim())" }

# ---------------------------------------------------------------- 真实拆帧
Write-Host ''
Write-Host "[4] 用真 ffmpeg 拆 $Frames 帧（目标 ${Width}x${Height} @ $Fps fps）"
$script:VideoMaxFrames = $Frames
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = $null
try {
    $r = Expand-VideoFile -Path $Video -Fps $Fps -W $Width -H $Height -Progress $null
} catch {
    Check $false "Expand-VideoFile 抛异常: $($_.Exception.Message)"
}
$sw.Stop()
Check ($null -ne $r) '拆帧返回了结果对象'
if (-not $r) {
    $script:logLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Host "    走了哪条路: $($r.How)"
    Write-Host "    拆出 $($r.Frames.Count) 帧，耗时 $([Math]::Round($sw.Elapsed.TotalSeconds,1)) 秒"
    Check ($r.How -eq 'ffmpeg') '走的是 ffmpeg 路线'
    Check ($r.Frames.Count -eq $Frames) "拆出 $Frames 帧（实际 $($r.Frames.Count)）"
    $sizes = @($r.Frames | ForEach-Object { (Get-Item -LiteralPath $_).Length })
    $realFrames = @($sizes | Where-Object { $_ -gt 1000 })
    Check ($realFrames.Count -eq $Frames) "所有帧都是非空的真 PNG（$($realFrames.Count)/$Frames）"
    Write-Host "    单帧平均 $([int](($sizes | Measure-Object -Average).Average / 1KB)) KB"
    $probeFrame = & $Py -c "from PIL import Image; import sys; im=Image.open(sys.argv[1]); print('%dx%d' % im.size)" $r.Frames[0] 2>&1
    Write-Host "    第一帧尺寸: $probeFrame"
    # scale=w=...:h=...:force_original_aspect_ratio=decrease 保证不超过目标框
    if ("$probeFrame" -match '^(\d+)x(\d+)$') {
        Check ([int]$Matches[1] -le $Width -and [int]$Matches[2] -le $Height) `
              "缩放正确：$probeFrame 不超过 ${Width}x${Height}"
    }
    # 相邻帧应该不一样（否则说明抽帧没抽到变化）
    $h1 = (Get-FileHash -LiteralPath $r.Frames[0] -Algorithm MD5).Hash
    $h2 = (Get-FileHash -LiteralPath $r.Frames[[int]($Frames/2)] -Algorithm MD5).Hash
    Check ($h1 -ne $h2) '中间帧与首帧内容不同（真的在解码不同时刻）'
}

# ---------------------------------------------------------------- 打包 + Python 校验
if ($r) {
    Write-Host ''
    Write-Host '[5] 把真实帧打包成 .baa 并用 Python 校验'
    if (-not (Get-Command Add-Type)) { }
    $packerPs1 = Join-Path $GuiDir 'BootAnimPacker.ps1'
    $ptxt = [IO.File]::ReadAllText($packerPs1)
    $m = [regex]::Match($ptxt, "(?s)@'\r?\n(.*?)\r?\n'@")
    try {
        Add-Type -TypeDefinition $m.Groups[1].Value -ReferencedAssemblies 'System.Drawing' -Language CSharp -ErrorAction Stop
        Check $true '打包内核编译通过'
    } catch {
        if ("$($_.Exception.Message)" -match 'already exists') { Check $true '打包内核已在内存中' }
        else { Check $false "打包内核编译失败: $($_.Exception.Message)" }
    }
    $baa = Join-Path $Tmp 'real.baa'
    try {
        [BootAnimGui.Packer]::Pack([string[]]$r.Frames, $Width, $Height, $Fps, 'contain',
                                   0, 0, 0, $true, $baa, $null) | Out-Null
        Check $true '打包成功'
    } catch {
        Check $false "打包失败: $($_.Exception.Message)"
    }
    if (Test-Path $baa) {
        $mb = (Get-Item $baa).Length / 1MB
        $rawMb = $r.Frames.Count * $Width * $Height * 4 / 1MB
        Write-Host ("    .baa = {0:N2} MiB（未压缩会是 {1:N1} MiB，压缩到 {2:N1}%）" -f `
                    $mb, $rawMb, (100 * $mb / $rawMb))
        $chk = & $Py -c @"
import sys
sys.path.insert(0, sys.argv[1])
import baanim
a = baanim.AnimFile(open(sys.argv[2], 'rb').read())
inf = a.info()
frames = [a.frame(i) for i in range(inf.frame_count)]
d = sum(1 for k in range(0, len(frames[0]), 4)
        if frames[0][k:k+4] != frames[len(frames)//2][k:k+4])
print('BAA frames=%d %dx%d fps=%d rle=%s motion=%d' % (
    inf.frame_count, inf.width, inf.height, inf.fps, inf.rle, d))
ok = (inf.frame_count == $Frames and inf.width == $Width and inf.height == $Height
      and inf.fps == $Fps and inf.rle and d > 100)
print('PYOK=%s' % ('1' if ok else '0'))
"@ (Join-Path $Root 'tools') $baa 2>&1
        $chk | ForEach-Object { Write-Host "    $_" }
        Check (($chk | Where-Object { "$_" -like 'PYOK=1' }).Count -eq 1) `
              '.baa 能被参考解码器正确解码，帧数/尺寸/帧率/RLE/运动幅度全部正确'
    }
}

Write-Host ''
Write-Host '========================================================='
$tail = if ($script:skip -gt 0) { ", $($script:skip) skipped" } else { '' }
if ($script:fail -eq 0) { Write-Host "$($script:pass) passed, 0 failed$tail" -ForegroundColor Green }
else { Write-Host "$($script:pass) passed, $($script:fail) failed$tail" -ForegroundColor Red }
Write-Host '========================================================='
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
