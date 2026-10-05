# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  test-gui-cfg.ps1 -- 单测 GUI 里的纯数据逻辑
#
#  GUI 脚本本身要弹窗口，没法直接跑；这里用 PowerShell 的 AST 解析器
#  把 BootAnimGUI.ps1 里的函数定义精确抽出来，在测试作用域里执行，
#  验证「开关动画」依赖的那几个函数。
#
#  用法: powershell -ExecutionPolicy Bypass -File tools\test-gui-cfg.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Gui  = Join-Path $Root 'gui\BootAnimGUI.ps1'
$Tmp  = Join-Path $env:TEMP ('baacfg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

$script:pass = 0
$script:fail = 0
function Check($cond, $what) {
    if ($cond) { $script:pass++; Write-Host "  [OK]   $what" }
    else { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

Write-Host "GUI 脚本: $Gui"
Write-Host ''

# ---------------------------------------------------------------- 抽函数
Write-Host '[1] 用 AST 从 GUI 脚本里抽出需要单测的函数'
$toks = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count) {
    Check $false 'GUI 脚本有语法错误'
    $errs | ForEach-Object { Write-Host "   line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    exit 1
}
Check $true 'GUI 脚本语法解析通过'

$want = @('Read-Cfg', 'Set-CfgValue', 'Get-BaaInfo', 'Sort-FileNames')
$all = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$src = ''
foreach ($f in $all) {
    if ($want -contains $f.Name) { $src += $f.Extent.Text + "`n`n" }
}
foreach ($w in $want) {
    Check (($all | Where-Object { $_.Name -eq $w }).Count -eq 1) "找到函数 $w"
}
Invoke-Expression $src

# ---------------------------------------------------------------- 配置读写
Write-Host ''
Write-Host '[2] bootanim.cfg 读写（「启用/禁用」就是改这个键）'

$cfg = Join-Path $Tmp 'bootanim.cfg'
$original = @'
# =====================================================================
#  bootanim.cfg -- 带注释的配置，验证 Set-CfgValue 不会破坏注释
# =====================================================================

# ---------- 开关 ----------
ENABLED=1

ANIM=anim.baa
FPS=30
PACING=auto
# 结尾注释
'@
[IO.File]::WriteAllText($cfg, $original, (New-Object Text.UTF8Encoding($false)))

$r1 = Read-Cfg -Path $cfg
Check ($r1.Enabled -eq $true)  '读回 ENABLED=1 → 启用'
Check ($r1.Anim -eq 'anim.baa') '读回 ANIM'
Check ($r1.Fps -eq '30')       '读回 FPS'

Set-CfgValue -Path $cfg -Pairs @{ 'ENABLED' = '0' }
$after = [IO.File]::ReadAllText($cfg)
$r2 = Read-Cfg -Path $cfg
Check ($r2.Enabled -eq $false) '改成 ENABLED=0 → 读到禁用'
Check ($after -match '带注释的配置') '注释没有被破坏'
Check ($after -match '结尾注释')     '结尾注释保留'
Check (($after -split "`n" | Where-Object { $_ -match '^ENABLED=' }).Count -eq 1) 'ENABLED 只有一行（没有重复追加）'
Check ($r2.Anim -eq 'anim.baa' -and $r2.Fps -eq '30') '其它键没被动过'

Set-CfgValue -Path $cfg -Pairs @{ 'ENABLED' = '1' }
Check ((Read-Cfg -Path $cfg).Enabled -eq $true) '再改回 1 → 启用（可反复切换）'

# 没有任何键时应该追加
$cfg2 = Join-Path $Tmp 'empty.cfg'
[IO.File]::WriteAllText($cfg2, "# 空配置`n", (New-Object Text.UTF8Encoding($false)))
Set-CfgValue -Path $cfg2 -Pairs @{ 'ENABLED' = '0'; 'FPS' = '24' }
$r3 = Read-Cfg -Path $cfg2
Check ($r3.Enabled -eq $false -and $r3.Fps -eq '24') '键不存在时自动追加'

# 文件不存在时应该能创建
$cfg3 = Join-Path $Tmp 'nofile\bootanim.cfg'
Set-CfgValue -Path $cfg3 -Pairs @{ 'ENABLED' = '0' }
Check (Test-Path $cfg3) '配置文件不存在时能自动新建（含目录）'
Check ((Read-Cfg -Path $cfg3).Enabled -eq $false) '新建后值正确'

# 各种"关"的写法都要认
foreach ($v in '0', 'off', 'no', 'false', 'disable', 'disabled') {
    Set-CfgValue -Path $cfg2 -Pairs @{ 'ENABLED' = $v }
    Check ((Read-Cfg -Path $cfg2).Enabled -eq $false) "ENABLED=$v 识别为禁用"
}
Set-CfgValue -Path $cfg2 -Pairs @{ 'ENABLED' = '1' }
Check ((Read-Cfg -Path $cfg2).Enabled -eq $true) 'ENABLED=1 识别为启用'

# 注释里的 ENABLED= 不能被当成配置
$cfg4 = Join-Path $Tmp 'comment.cfg'
[IO.File]::WriteAllText($cfg4, "# ENABLED=0`n;ENABLED=0`nENABLED=1`n", (New-Object Text.UTF8Encoding($false)))
Check ((Read-Cfg -Path $cfg4).Enabled -eq $true) '注释行里的 ENABLED 被忽略'

# ---------------------------------------------------------------- .baa 头
Write-Host ''
Write-Host '[3] Get-BaaInfo 读 .baa 头'
$baa = Join-Path $Tmp 't.baa'
$hdr = New-Object byte[] 64
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('BAANIM01'), $hdr, 8)
$u32 = {
    param($off, $v)
    $hdr[$off] = $v -band 0xFF
    $hdr[$off+1] = ($v -shr 8) -band 0xFF
    $hdr[$off+2] = ($v -shr 16) -band 0xFF
    $hdr[$off+3] = ($v -shr 24) -band 0xFF
}
$hdr[8] = 64
& $u32 12 60
& $u32 16 1920
& $u32 20 1080
& $u32 24 30
& $u32 28 1
[IO.File]::WriteAllBytes($baa, $hdr)
$bi = Get-BaaInfo -Path $baa
Check ($null -ne $bi) '能读出 .baa 头'
if ($bi) {
    Check ($bi.Frames -eq 60 -and $bi.Width -eq 1920 -and $bi.Height -eq 1080 -and $bi.Fps -eq 30 -and $bi.Rle -eq $true) `
        "字段正确：$($bi.Width)x$($bi.Height) $($bi.Frames) 帧 $($bi.Fps)fps RLE=$($bi.Rle)"
}
Check ((Get-BaaInfo -Path (Join-Path $Tmp 'nope.baa')) -eq $null) '文件不存在返回 null'
$bad = Join-Path $Tmp 'bad.baa'
[IO.File]::WriteAllBytes($bad, (New-Object byte[] 64))
Check ((Get-BaaInfo -Path $bad) -eq $null) '魔数不对返回 null'

# ---------------------------------------------------------------- 自然排序
Write-Host ''
Write-Host '[4] Sort-FileNames 自然排序'
$names = @('frame10.png', 'frame2.png', 'frame1.png', 'frame20.png', 'frame3.png')
$sorted = @(Sort-FileNames -Names $names)
Write-Host "  $($sorted -join ', ')"
Check ($sorted[0] -eq 'frame1.png' -and $sorted[1] -eq 'frame2.png' -and $sorted[2] -eq 'frame3.png' `
       -and $sorted[3] -eq 'frame10.png' -and $sorted[4] -eq 'frame20.png') 'frame2 排在 frame10 前面'

Write-Host ''
Write-Host '========================================================='
if ($script:fail -eq 0) { Write-Host "$($script:pass) passed, 0 failed" -ForegroundColor Green }
else { Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor Red }
Write-Host '========================================================='
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
