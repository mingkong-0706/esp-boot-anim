# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  test-gui-packer.ps1 -- 在开发机上验证 GUI 的 C# 打包内核
#
#  做三件事：
#    1. 从 BootAnimPacker.ps1 里抽出 C# 源码，用系统自带的 csc 编译
#    2. 用 C# 内核把一组图片打包成 .baa（RLE 与不压缩各一次）
#    3. 调用 tools/ 里的 Python 参考解码器逐像素比对
#
#  用法: powershell -ExecutionPolicy Bypass -File tools\test-gui-packer.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
# Python 从环境里找，不写死路径（公开仓库不能带个人机器路径）
. (Join-Path $PSScriptRoot 'find-python.ps1')
$Py = Find-Python
if (-not $Py) {
    Write-Host ''
    Write-Host '本测试需要 Python 3（做参考解码器和比对）。没找到，跳过。' -ForegroundColor Yellow
    exit 0
}
Write-Host "Python: $Py"
$Tmp  = Join-Path $env:TEMP ('baapack_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

$script:pass = 0
$script:fail = 0
function Check($cond, $what) {
    if ($cond) { $script:pass++; Write-Host "  [OK]   $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

Write-Host "临时目录: $Tmp"
Write-Host ''

# ---------------------------------------------------------------- 1. 编译
Write-Host '[1] 从 BootAnimPacker.ps1 抽出 C# 并编译'
$packerPs1 = Join-Path $Root 'gui\BootAnimPacker.ps1'
$text = [IO.File]::ReadAllText($packerPs1)
$m = [regex]::Match($text, "(?s)@'\r?\n(.*?)\r?\n'@")
Check $m.Success '能在脚本里找到 C# here-string'
$cs = $m.Groups[1].Value
$csPath = Join-Path $Tmp 'Packer.cs'
[IO.File]::WriteAllText($csPath, $cs, (New-Object Text.UTF8Encoding($false)))
Write-Host "  C# 源码 $($cs.Length) 字符"

try {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing' -Language CSharp -ErrorAction Stop
    Check $true 'Add-Type 编译通过（说明 C# 语法没问题）'
} catch {
    Check $false "Add-Type 编译失败: $($_.Exception.Message)"
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 2. 造素材
Write-Host ''
Write-Host '[2] 用 Python/Pillow 生成测试图片'
$genSrc = @'
import os, sys, random
from PIL import Image
outdir = sys.argv[1]
random.seed(1234)
w, h, n = 64, 48, 8
for i in range(n):
    img = Image.new("RGB", (w, h))
    px = []
    for y in range(h):
        for x in range(w):
            if (x // 8 + y // 8) % 3 == 0:
                px.append((i * 30 % 256, (x * 4) % 256, (y * 5) % 256))
            else:
                px.append((random.randrange(256), random.randrange(256), random.randrange(256)))
    img.putdata(px)
    img.save(os.path.join(outdir, "f%04d.png" % i))
img = Image.new("RGB", (32, 24), (200, 30, 30))
img.save(os.path.join(outdir, "small.png"))
print("generated")
'@
$genPy = Join-Path $Tmp 'gen.py'
[IO.File]::WriteAllText($genPy, $genSrc, (New-Object Text.UTF8Encoding($false)))
$genOut = & $Py $genPy $Tmp 2>&1
Write-Host "  $genOut"
$files = @(0..7 | ForEach-Object { Join-Path $Tmp ("f{0:D4}.png" -f $_) })
Check (Test-Path $files[0]) "生成了 $($files.Count) 张 64x48 测试图"

# ---------------------------------------------------------------- 3. 打包
Write-Host ''
Write-Host '[3] 用 C# 内核打包'
$outRle = Join-Path $Tmp 'rle.baa'
$outRaw = Join-Path $Tmp 'raw.baa'
$script:progCalls = 0
$progress = [Action[int, string]]{ param($pct, $msg) $script:progCalls++ }

try {
    [BootAnimGui.Packer]::Pack([string[]]$files, 64, 48, 24, 'none', 0, 0, 0, $true, $outRle, $progress) | Out-Null
    Check $true 'Pack(RLE) 调用成功'
    [BootAnimGui.Packer]::Pack([string[]]$files, 64, 48, 24, 'none', 0, 0, 0, $false, $outRaw, $null) | Out-Null
    Check $true 'Pack(不压缩) 调用成功'
    Check ($script:progCalls -eq 8) "进度回调被调用 8 次（实际 $($script:progCalls)）"
} catch {
    Check $false "Pack 抛异常: $($_.Exception.Message)"
}

$szRle = (Get-Item $outRle).Length
$szRaw = (Get-Item $outRaw).Length
$expectRaw = 64 + 8 * 8 + 8 * 64 * 48 * 4
Write-Host "  RLE 文件 $szRle 字节 / 未压缩应有 $expectRaw 字节（压缩比 $([math]::Round(100*$szRle/$expectRaw,1))%）"
Check ($szRaw -eq $expectRaw) '不压缩时文件大小精确等于 64 + 索引 + 帧数据'

# ---------------------------------------------------------------- 4. Python 校验
Write-Host ''
Write-Host '[4] 用 Python 参考解码器逐像素校验'
$verSrc = @'
import sys, os, json
sys.path.insert(0, sys.argv[1])
import baanim
from PIL import Image

tmp = sys.argv[2]
files = [os.path.join(tmp, "f%04d.png" % i) for i in range(8)]
expected = [baanim.pillow_to_bgrx(Image.open(p).convert("RGBA")) for p in files]

fails = []
for name in ("rle.baa", "raw.baa"):
    blob = open(os.path.join(tmp, name), "rb").read()
    a = baanim.AnimFile(blob)
    info = a.info()
    print("FILE %s frames=%d %dx%d fps=%d rle=%s" %
          (name, info.frame_count, info.width, info.height, info.fps, info.rle))
    if (info.frame_count, info.width, info.height, info.fps) != (8, 64, 48, 24):
        fails.append("%s 头部字段不对" % name)
    if info.rle != (name == "rle.baa"):
        fails.append("%s RLE 标志不对" % name)
    for i in range(8):
        got = a.frame(i)
        if len(got) != len(expected[i]):
            fails.append("%s 第 %d 帧长度不对" % (name, i)); break
        if got != expected[i]:
            for k in range(0, len(got), 4):
                if got[k:k+4] != expected[i][k:k+4]:
                    fails.append("%s 第%d帧 像素%d got=%s exp=%s" %
                                 (name, i, k//4, list(got[k:k+4]), list(expected[i][k:k+4])))
                    break
            break
print("PYFAILS=" + json.dumps(fails))
'@
$verPy = Join-Path $Tmp 'verify.py'
[IO.File]::WriteAllText($verPy, $verSrc, (New-Object Text.UTF8Encoding($false)))
$pyOut = & $Py $verPy (Join-Path $Root 'tools') $Tmp 2>&1
$pyOut | ForEach-Object { Write-Host "  $_" }
$last = ($pyOut | Where-Object { "$_" -like 'PYFAILS=*' } | Select-Object -Last 1)
if ($last) {
    $fails = ("$last" -replace '^PYFAILS=', '') | ConvertFrom-Json
    if (@($fails).Count -eq 0) { Check $true 'Python 逐像素比对：完全一致' }
    else { Check $false ("Python 比对失败: " + ($fails -join '; ')) }
} else {
    Check $false 'Python 校验脚本没有输出结果'
}

# ---------------------------------------------------------------- 5. 示例动画
Write-Host ''
Write-Host '[5] Demo.Generate 生成示例动画并校验'
$outDemo = Join-Path $Tmp 'demo.baa'
try {
    [BootAnimGui.Demo]::Generate(96, 64, 12, 30, $outDemo, $null) | Out-Null
    Check $true 'Demo.Generate 调用成功'
} catch {
    Check $false "Demo.Generate 抛异常: $($_.Exception.Message)"
}
$info = [BootAnimGui.Packer]::GetInfo($outDemo)
Check ($null -ne $info) 'GetInfo 能读出 .baa 头'
if ($info) {
    Check ($info[0] -eq 12 -and $info[1] -eq 96 -and $info[2] -eq 64 -and $info[3] -eq 30 -and $info[4] -eq 1) `
        "GetInfo 字段正确：帧=$($info[0]) 宽=$($info[1]) 高=$($info[2]) fps=$($info[3]) rle=$($info[4])"
}
$verDemoSrc = @'
import sys
sys.path.insert(0, sys.argv[1])
import baanim
a = baanim.AnimFile(open(sys.argv[2], "rb").read())
inf = a.info()
print("DEMO frames=%d %dx%d fps=%d rle=%s" % (inf.frame_count, inf.width, inf.height, inf.fps, inf.rle))
frames = [a.frame(i) for i in range(inf.frame_count)]
fb, other = frames[0], frames[6]
diff = sum(1 for k in range(0, len(fb), 4) if fb[k:k+4] != other[k:k+4])
nonbg = sum(1 for k in range(0, len(fb), 4) if fb[k:k+4] != b"\x00\x00\x00\xff")
print("DEMOINFO nonbg=%d diff=%d" % (nonbg, diff))
print("PYOK=%s" % ("1" if (nonbg > 50 and diff > 50) else "0"))
'@
$verDemo = Join-Path $Tmp 'verify_demo.py'
[IO.File]::WriteAllText($verDemo, $verDemoSrc, (New-Object Text.UTF8Encoding($false)))
$dOut = & $Py $verDemo (Join-Path $Root 'tools') $outDemo 2>&1
$dOut | ForEach-Object { Write-Host "  $_" }
Check (($dOut | Where-Object { "$_" -like 'PYOK=1' }).Count -eq 1) '示例动画有内容且帧间有变化'

# ---------------------------------------------------------------- 6. 缩放路径
Write-Host ''
Write-Host '[6] 缩放路径（32x24 纯色 -> 64x48 fit=contain）'
$outScale = Join-Path $Tmp 'scale.baa'
try {
    [BootAnimGui.Packer]::Pack([string[]]@(Join-Path $Tmp 'small.png'), 64, 48, 30, 'contain', 7, 8, 9, $true, $outScale, $null) | Out-Null
    $inf2 = [BootAnimGui.Packer]::GetInfo($outScale)
    Check ($null -ne $inf2 -and $inf2[1] -eq 64 -and $inf2[2] -eq 48) '缩放后尺寸正确'
} catch {
    Check $false "缩放路径失败: $($_.Exception.Message)"
}
$verScaleSrc = @'
import sys
sys.path.insert(0, sys.argv[1])
import baanim
a = baanim.AnimFile(open(sys.argv[2], "rb").read())
inf = a.info()
f = a.frame(0)
k = (24 * inf.width + 32) * 4
px = f[k:k+4]
print("SCALE %dx%d frames=%d center_px=%s" % (inf.width, inf.height, inf.frame_count, list(px)))
ok = (inf.width == 64 and inf.height == 48 and inf.frame_count == 1
      and abs(px[0] - 30) <= 2 and abs(px[1] - 30) <= 2 and abs(px[2] - 200) <= 2)
print("PYOK=%s" % ("1" if ok else "0"))
'@
$verScale = Join-Path $Tmp 'verify_scale.py'
[IO.File]::WriteAllText($verScale, $verScaleSrc, (New-Object Text.UTF8Encoding($false)))
$scOut = & $Py $verScale (Join-Path $Root 'tools') $outScale 2>&1
$scOut | ForEach-Object { Write-Host "  $_" }
Check (($scOut | Where-Object { "$_" -like 'PYOK=1' }).Count -eq 1) '缩放后中心像素颜色正确（GDI+ 缩放与 BGRX 通道顺序都对）'

# ---------------------------------------------------------------- 7. GIF 拆帧
Write-Host ''
Write-Host '[7] 多帧 GIF 的探测与拆帧'

$gifSrc = @'
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
W, H, N = 64, 48, 24
frames = []
for i in range(N):
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    x = int(i * (W - 10) / N)
    d.rectangle([x, 8, x + 9, H - 9], fill=(0, 120, 212))
    d.ellipse([22, 14, 42, 34], fill=(255, 200, 0))
    frames.append(img)
frames[0].save(out, save_all=True, append_images=frames[1:], duration=40, loop=0)
print("gif_written frames=%d size=%dx%d" % (N, W, H))
'@
$gifPy = Join-Path $Tmp 'mk_gif.py'
[IO.File]::WriteAllText($gifPy, $gifSrc, (New-Object Text.UTF8Encoding($false)))
& $Py $gifPy (Join-Path $Tmp 'anim.gif') | ForEach-Object { Write-Host "  $_" }

$gifPath = Join-Path $Tmp 'anim.gif'
Check (Test-Path $gifPath) '生成了 24 帧测试 GIF'

# Probe 应认出帧数和帧间隔
$probe = $null
try { $probe = [BootAnimGui.Packer]::Probe($gifPath) } catch { }
Check ($null -ne $probe) 'Probe 能读 GIF'
if ($probe) {
    Write-Host "  Probe: 帧数=$($probe[0])  平均帧间隔=$($probe[1]) ms"
    Check ($probe[0] -eq 24) "Probe 认出 24 帧（实际 $($probe[0])）"
    Check ($probe[1] -eq 40) "Probe 认出 40 ms 帧间隔（实际 $($probe[1])）"
}
# 静态 PNG 应报 1 帧
$probePng = [BootAnimGui.Packer]::Probe((Join-Path $Tmp 'f0000.png'))
Check ($null -ne $probePng -and $probePng[0] -eq 1) '静态 PNG 被正确识别为 1 帧'

# 拆帧
$frameDir = Join-Path $Tmp 'gifframes'
$extracted = $null
try { $extracted = [BootAnimGui.Packer]::ExtractFrames($gifPath, $frameDir, $null) } catch {
    Check $false "ExtractFrames 抛异常: $($_.Exception.Message)"
}
Check ($null -ne $extracted -and $extracted.Count -eq 24) "拆出 24 张 PNG（实际 $(@($extracted).Count)）"
Check (@(Get-ChildItem $frameDir -Filter *.png -File).Count -eq 24) '拆出的 PNG 文件数正确'
# 单帧文件应该原样返回，不产生副本
$one = [BootAnimGui.Packer]::ExtractFrames((Join-Path $Tmp 'f0000.png'), (Join-Path $Tmp 'x'), $null)
Check ($one.Count -eq 1 -and $one[0] -eq (Join-Path $Tmp 'f0000.png')) '单帧文件原样返回，不产生副本'

# 把拆出来的帧打包，再用 Python 校验
$outGif = Join-Path $Tmp 'fromgif.baa'
try {
    [BootAnimGui.Packer]::Pack([string[]]$extracted, 64, 48, 25, 'none', 0, 0, 0, $true, $outGif, $null) | Out-Null
    Check $true '把拆出的帧打包成功'
} catch {
    Check $false "打包拆出的帧失败: $($_.Exception.Message)"
}

$verGifSrc = @'
import sys, os, json
sys.path.insert(0, sys.argv[1])
import baanim
from PIL import Image, ImageSequence

tmp = sys.argv[2]
gif = os.path.join(tmp, "anim.gif")
baa = os.path.join(tmp, "fromgif.baa")
frame_dir = os.path.join(tmp, "gifframes")

fails = []

# 1) Pillow 自己拆 GIF，作为对照
im = Image.open(gif)
exp = [f.convert("RGBA") for f in ImageSequence.Iterator(im)]
print("PILLOW gif frames=%d" % len(exp))

# 2) GDI+ 拆出来的 PNG 和 Pillow 的对照
got = [Image.open(os.path.join(frame_dir, "anim_%05d.png" % i)).convert("RGBA") for i in range(len(exp))]
diffs = 0
for i in range(len(exp)):
    if got[i].tobytes() != exp[i].tobytes():
        diffs += 1
        if diffs == 1:
            # 报第一处差异
            a, b = got[i].tobytes(), exp[i].tobytes()
            for k in range(0, len(a), 4):
                if a[k:k+4] != b[k:k+4]:
                    fails.append("GIF 第%d帧 像素%d GDI+=%s Pillow=%s" %
                                 (i, k//4, list(a[k:k+4]), list(b[k:k+4])))
                    break
print("GIF_COMPARE diffs=%d/%d" % (diffs, len(exp)))

# 3) .baa 里的帧应该等于 GDI+ 拆出来的帧（1:1 直通，无重采样）
a2 = baanim.AnimFile(open(baa, "rb").read())
inf2 = a2.info()
print("BAA frames=%d %dx%d" % (inf2.frame_count, inf2.width, inf2.height))
if inf2.frame_count != len(exp):
    fails.append(".baa 帧数 %d != GIF 帧数 %d" % (inf2.frame_count, len(exp)))
else:
    nexp = [baanim.pillow_to_bgrx(img) for img in exp]
    for i in range(inf2.frame_count):
        if a2.frame(i) != nexp[i]:
            fails.append(".baa 第%d帧与 GIF 原始帧不符" % i)
            break

# 4) 动画真的在动：首帧和末帧必须不同
if inf2.frame_count > 1:
    d = sum(1 for k in range(0, len(a2.frame(0)), 4) if a2.frame(0)[k:k+4] != a2.frame(inf2.frame_count-1)[k:k+4])
    print("MOTION first_vs_last_diff=%d" % d)
    if d < 20:
        fails.append("首末帧几乎一样，拆帧可能只取了同一帧")

print("PYFAILS=" + json.dumps(fails))
'@
$verGif = Join-Path $Tmp 'verify_gif.py'
[IO.File]::WriteAllText($verGif, $verGifSrc, (New-Object Text.UTF8Encoding($false)))
$gOut = & $Py $verGif (Join-Path $Root 'tools') $Tmp 2>&1
$gOut | ForEach-Object { Write-Host "  $_" }
$gLast = ($gOut | Where-Object { "$_" -like 'PYFAILS=*' } | Select-Object -Last 1)
if ($gLast) {
    $gf = ("$gLast" -replace '^PYFAILS=', '') | ConvertFrom-Json
    if (@($gf).Count -eq 0) { Check $true 'GDI+ 拆帧与 Pillow 拆帧逐像素一致，且 .baa 内容正确' }
    else { Check $false ("GIF 校验失败: " + ($gf -join '; ')) }
} else {
    Check $false 'GIF 校验脚本没有输出结果'
}

Write-Host ''
Write-Host '========================================================='
if ($script:fail -eq 0) {
    Write-Host "$($script:pass) passed, 0 failed" -ForegroundColor Green
} else {
    Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor Red
}
Write-Host '========================================================='
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
