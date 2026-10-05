# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  test-gui-video.ps1 -- 验证 GUI 的视频拆帧接线
#
#  这个环境里没有真的 ffmpeg，也没法验证 WinRT（沙箱拦住了 WinRT 的
#  代理文件访问），所以这里用一个"桩 ffmpeg.exe"来验证**我写的代码**：
#    * 命令行参数是否拼对（尤其是 -vf 这种带逗号的参数必须是一个参数）
#    * 输出帧是否被按名字顺序收集
#    * 帧数上限是否正确传递
#    * ffmpeg 不可用时是否会优雅地转向 WinRT 而不是崩掉
#
#  用法: powershell -ExecutionPolicy Bypass -File tools\test-gui-video.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here   = $PSScriptRoot
$Root   = Split-Path -Parent $Here
$GuiDir = Join-Path $Root 'gui'
$Gui    = Join-Path $GuiDir 'BootAnimGUI.ps1'
# 临时目录**刻意不放 %TEMP%**：实测某些环境下子进程（比如这里要编译的
# 桩 ffmpeg）往 %TEMP% 写文件会被策略拦成 Permission denied，
# 而写程序旁边的目录完全正常。.bootanim-frames/ 已经在 .gitignore 里。
$ScratchBase = Join-Path $Root '.bootanim-frames'
New-Item -ItemType Directory -Force -Path $ScratchBase | Out-Null
$LibDir = Join-Path $ScratchBase ('guivid_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Stub   = Join-Path $GuiDir 'ffmpeg.exe'          # 临时占用这个名字
$ArgLog = Join-Path $GuiDir 'ffmpeg_args.txt'
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Check($cond, $what) {
    if ($cond) { $script:pass++; Write-Host "  [OK]   $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}
function Skip($what) { $script:skip++; Write-Host "  [跳过] $what" -ForegroundColor Yellow }

# 本机的应用程序控制策略时好时坏地拦新建 exe，所以要能区分
# "我的代码错了" 和 "环境不让跑"
function Test-CanRunExe($path) {
    try { & $path 2>&1 | Out-Null; return $true }
    catch { return ($_.Exception.Message -notmatch 'Application Control|blocked') }
}

Write-Host "GUI: $Gui"
Write-Host ''

if (Test-Path $Stub) {
    Write-Host '  [跳过] gui\ffmpeg.exe 已存在（可能是你自己放的），不覆盖它' -ForegroundColor Yellow
    Remove-Item -Recurse -Force $LibDir -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---------------------------------------------------------------- 1. 编桩
Write-Host '[1] 编译桩 ffmpeg.exe（记录参数 + 产出 PNG）'
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" }

$stubCs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Text;

class StubFFmpeg
{
    [STAThread]
    static int Main(string[] a)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        File.WriteAllLines(Path.Combine(exeDir, "ffmpeg_args.txt"), a, new UTF8Encoding(false));

        string pattern = null; int frames = 0; string vf = null; string input = null;
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i] == "-i" && i + 1 < a.Length) input = a[i + 1];
            else if (a[i] == "-frames:v" && i + 1 < a.Length) int.TryParse(a[i + 1], out frames);
            else if (a[i] == "-vf" && i + 1 < a.Length) vf = a[i + 1];
            else if (a[i].EndsWith(".png", StringComparison.OrdinalIgnoreCase)) pattern = a[i];
        }
        if (pattern == null || frames <= 0) return 3;
        if (input == null || vf == null) return 4;

        for (int i = 1; i <= frames; i++)
        {
            string p = pattern.Replace("%05d", i.ToString("D5"));
            using (Bitmap b = new Bitmap(32, 18, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(b))
                {
                    g.Clear(Color.Black);
                    g.FillRectangle(Brushes.Orange, (i * 3) % 20, 4, 6, 10);
                }
                b.Save(p, ImageFormat.Png);
            }
        }
        return 0;
    }
}
'@
$csPath = Join-Path $LibDir 'stub.cs'
[IO.File]::WriteAllText($csPath, $stubCs, (New-Object Text.UTF8Encoding($true)))
& $csc /nologo /target:exe /codepage:65001 "/out:$Stub" /reference:System.Drawing.dll $csPath | ForEach-Object { Write-Host "    $_" }
Check (Test-Path $Stub) "桩 ffmpeg.exe 已生成（$((Get-Item $Stub -EA SilentlyContinue).Length) 字节）"

# ---------------------------------------------------------------- 2. 抽函数
Write-Host ''
Write-Host '[2] 从 GUI 脚本里抽出视频相关函数'
$toks = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count) {
    Check $false 'GUI 脚本有语法错误'
    $errs | ForEach-Object { Write-Host "    line $($_.Extent.StartLineNumber): $($_.Message)" }
    Remove-Item $Stub -Force -EA SilentlyContinue
    exit 1
}
Check $true 'GUI 脚本语法解析通过'

$want = @('Find-FFmpeg', 'Get-FFmpegArgs', 'Expand-Video-FFmpeg', 'ConvertTo-WslPath', 'Test-WslFFmpeg', 'Expand-Video-WSL', 'Expand-VideoFile')
$all = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$src = ''
foreach ($f in $all) { if ($want -contains $f.Name) { $src += $f.Extent.Text + "`n`n" } }
foreach ($w in $want) { Check (($all | Where-Object { $_.Name -eq $w }).Count -eq 1) "找到函数 $w" }

# 这些变量/函数是那些函数依赖的
$ProjRoot = $Root
$script:FrameDir = Join-Path $LibDir 'frames'
$script:VideoExts = @('.mp4', '.m4v', '.mov', '.wmv', '.avi', '.mkv', '.webm', '.mpg', '.mpeg')
$script:VideoMaxFrames = 1200
$script:WslFF = $null
$script:logLines = New-Object System.Collections.ArrayList

Invoke-Expression $src
# 覆盖 Add-Log，收集日志而不是丢给不存在的 LogBox
function Add-Log { param([string]$Text, [string]$Level = 'info') [void]$script:logLines.Add("[$Level] $Text") }

# 一个假的"视频"文件。桩 ffmpeg 不校验内容，但路径必须非空 ——
# 空字符串参数在传给原生 exe 时会被丢掉，会让下面的参数比对失真。
$dummy = Join-Path $LibDir 'fake.mp4'
[IO.File]::WriteAllBytes($dummy, [byte[]](1..64))

Write-Host ''
Write-Host '[3] 命令行拼装（不依赖 ffmpeg 本体，确定性验证）'
$pat = Join-Path $LibDir 'v%05d.png'
$args1 = Get-FFmpegArgs -InputPath $dummy -OutPattern $pat -Fps 25 -W 1920 -H 1080 -MaxFrames 1200
Write-Host '    Get-FFmpegArgs 产出:'
$i = 0
foreach ($a in $args1) { Write-Host ("      [{0,2}] {1}" -f $i, $a); $i++ }

Check ($args1 -contains '-hide_banner') '有 -hide_banner'
Check ($args1 -contains '-nostdin')    '有 -nostdin（GUI 程序必须加，否则 ffmpeg 会抢标准输入）'
Check ($args1 -contains '-an')         '有 -an（不要音频）'
Check ($args1 -contains '-sn')         '有 -sn（不要字幕）'
$iIn = [array]::IndexOf($args1, '-i')
Check ($iIn -ge 0 -and $args1[$iIn + 1] -eq $dummy) '-i 后面紧跟输入路径'
$iVf = [array]::IndexOf($args1, '-vf')
Check ($iVf -ge 0) '有 -vf'
if ($iVf -ge 0) {
    $vf = $args1[$iVf + 1]
    Write-Host "    -vf 的值: '$vf'"
    Check ($vf -eq 'fps=25,scale=w=1920:h=1080:force_original_aspect_ratio=decrease') `
          '-vf 是**一个**参数且内容完全正确（$W/$H 没被当成作用域）'
    Check ($vf -notmatch '=:|=h=|=w=$') '-vf 里没有变量插值留下的空洞'
}
$iF = [array]::IndexOf($args1, '-frames:v')
Check ($iF -ge 0 -and $args1[$iF + 1] -eq '1200') '-frames:v 传的是 1200'
Check ($args1 -contains '-y') '-y（覆盖已有文件）'
Check ($args1[-1] -eq $pat) '最后一个是输出模板 v%05d.png'
Check ($args1.Count -eq 14) "参数个数是 14（实际 $($args1.Count)）"

Write-Host ''
Write-Host '[4] 真的执行桩 ffmpeg（环境允许时）'
if (-not (Test-CanRunExe $Stub)) {
    Skip '本机的应用控制策略拦住了桩 exe，跳过实际执行部分'
    Skip '（参数拼装已在上一节确定性验证过了）'
} else {
    Remove-Item $ArgLog -Force -EA SilentlyContinue
    $r = $null
    try { $r = Expand-VideoFile -Path $dummy -Fps 25 -W 1920 -H 1080 -Progress $null }
    catch { Check $false "Expand-VideoFile 抛异常: $($_.Exception.Message)" }
    Check ($null -ne $r) '拿到了结果对象'
    if ($r) {
        Check ($r.How -eq 'ffmpeg') "走的是 ffmpeg（实际 $($r.How)）"
        Check ($r.Frames.Count -eq 1200) "收了 1200 帧（实际 $($r.Frames.Count)）"
        Check ($r.Clamped -eq $true) '正确标记为「被上限截断」'
        Check ($r.Frames[0] -like '*v00001.png') "第一帧 v00001.png（实际 $(Split-Path -Leaf $r.Frames[0])）"
        Check ($r.Frames[1199] -like '*v01200.png') "最后一帧 v01200.png（实际 $(Split-Path -Leaf $r.Frames[1199])）"
        $sorted = @($r.Frames | Sort-Object)
        Check (($sorted -join '|') -eq ($r.Frames -join '|')) '帧顺序按名字升序'
    }
    if (Test-Path $ArgLog) {
        $got = @([IO.File]::ReadAllLines($ArgLog, [Text.Encoding]::UTF8))
        # 输出模板那一项两边路径不同（第三节用 $LibDir，这里用拆帧子目录），
        # 所以只比对它之前的部分，再单独确认模板落点
        $gotHead = @($got[0..($got.Count - 2)])
        $expHead = @($args1[0..($args1.Count - 2)])
        Check (($gotHead -join "`n") -eq ($expHead -join "`n")) '桩收到的参数（除输出模板外）与 Get-FFmpegArgs 产出一字不差'
        Check ($got[-1] -like '*vid_fake\ff\v%05d.png') "输出模板落在预期的拆帧子目录（实际 $($got[-1])）"
    } else {
        Check $false '桩没有写出参数日志'
    }

    Write-Host ''
    Write-Host '[5] 帧数上限能被尊重'
    $script:VideoMaxFrames = 30
    $r2 = Expand-VideoFile -Path $dummy -Fps 30 -W 320 -H 180 -Progress $null
    Check ($null -ne $r2 -and $r2.Frames.Count -eq 30) "上限 30 时只收 30 帧（实际 $(@($r2.Frames).Count)）"
    $script:VideoMaxFrames = 1200
}

# ---------------------------------------------------------------- 6. 没有 ffmpeg 时
Write-Host ''
Write-Host '[6] 把 ffmpeg 拿走，应该优雅转向 WSL 而不是崩'
Remove-Item $Stub -Force -EA SilentlyContinue
$script:WslFF = 'no'               # 假装 WSL 也不可用，走到底
$r3 = $null
$threw = $false
try { $r3 = Expand-VideoFile -Path $dummy -Fps 30 -W 320 -H 180 -Progress $null }
catch { $threw = $true; Write-Host "    抛异常: $($_.Exception.Message)" }
Check (-not $threw) '没有抛异常'
Check ($null -eq $r3) '返回 $null（交给上层弹说明框）'
$winlog = @($script:logLines | Where-Object { $_ -match 'WSL|都不可用' })
Check ($winlog.Count -ge 1) '日志里有尝试 WSL 并最终放弃的记录'
$winlog | ForEach-Object { Write-Host "    $_" }

# ---------------------------------------------------------------- 7. WSL 路径转换
Write-Host ''
Write-Host '[7] Windows 路径 -> WSL 路径'
$cases = @(
    @('C:\Users\a\b.mp4',                 '/mnt/c/Users/a/b.mp4'),
    @('D:\x y\v%05d.png',                  '/mnt/d/x y/v%05d.png'),
    @('C:\Work\proj\clip.mp4',           '/mnt/c/Work/proj/clip.mp4')
)
foreach ($c in $cases) {
    $got = ConvertTo-WslPath $c[0]
    Check ($got -eq $c[1]) "$($c[0])  ->  $got"
}

Write-Host ''
Write-Host '========================================================='
$tail = if ($script:skip -gt 0) { ", $($script:skip) skipped" } else { "" }
if ($script:fail -eq 0) { Write-Host "$($script:pass) passed, 0 failed$tail" -ForegroundColor Green }
else { Write-Host "$($script:pass) passed, $($script:fail) failed$tail" -ForegroundColor Red }
Write-Host '========================================================='

Remove-Item $Stub -Force -EA SilentlyContinue
Remove-Item $ArgLog -Force -EA SilentlyContinue
Remove-Item -Recurse -Force $LibDir -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:FrameDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $script:FrameDir -ErrorAction SilentlyContinue
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
