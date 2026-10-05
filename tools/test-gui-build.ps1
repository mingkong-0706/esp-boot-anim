# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  test-gui-build.ps1 -- 不显示窗口，把整个窗体"造"一遍
#
#  为什么需要它：把字符串赋给枚举属性（例如 SelectionMode = 'Extended'）
#  这类错误语法解析抓不到，只有真的执行到那一行才会抛异常。
#  而 WinForms 的控件在 ShowDialog 之前就已经全部创建并赋值完毕，
#  所以把 GUI 脚本截到 ShowDialog 之前执行，就能一次性找出所有这类问题。
#
#  用法: powershell -ExecutionPolicy Bypass -File tools\test-gui-build.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here   = $PSScriptRoot
$Root   = Split-Path -Parent $Here
$GuiDir = Join-Path $Root 'gui'
$Gui    = Join-Path $GuiDir 'BootAnimGUI.ps1'

$TmpDir = Join-Path $env:TEMP ('guibuild_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$TmpScript = Join-Path $TmpDir 'gui_selftest.ps1'
$LogFile   = Join-Path $TmpDir 'out.txt'

Write-Host "被检查的脚本: $Gui"
Write-Host ''

# ---- 1. 读取并截断 ----
$code = [IO.File]::ReadAllText($Gui)
$marker = '[void]$form.ShowDialog()'
$idx = $code.IndexOf($marker)
if ($idx -lt 0) {
    Write-Host "  [FAIL] 找不到标记 $marker" -ForegroundColor Red
    exit 1
}
$code = $code.Substring(0, $idx)
Write-Host ("[1] 截取到 ShowDialog 之前，长度 " + $code.Length + " 字符")

# ---- 2. 把 $GuiDir = $PSScriptRoot 换成真实路径 ----
$before = $code
$code = $code.Replace('$GuiDir     = $PSScriptRoot', ("`$GuiDir     = '" + $GuiDir + "'"))
if ($code -eq $before) {
    Write-Host '  [FAIL] 没能替换 $GuiDir = $PSScriptRoot' -ForegroundColor Red
    exit 1
}
Write-Host '[2] 已把 $GuiDir 固定为真实路径'

# ---- 3. 去掉自提权块（沙箱里不是管理员） ----
$eStart = $code.IndexOf('$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()')
$eEnd   = $code.IndexOf('[System.Windows.Forms.Application]::EnableVisualStyles()')
if ($eStart -ge 0 -and $eEnd -gt $eStart) {
    $code = $code.Substring(0, $eStart) + $code.Substring($eEnd)
    Write-Host '[3] 已移除自提权块'
} else {
    Write-Host '[3] 没找到自提权块（跳过）'
}

# ---- 4. 追加自检代码（用数组拼，不用 here-string） ----
$append = @(
    '',
    '# ===================== 自检追加部分 =====================',
    'Write-Host "FORM_BUILT_OK"',
    'Write-Host ("  form.Controls      = " + $form.Controls.Count)',
    'Write-Host ("  LstImages.SelMode  = " + $script:LstImages.SelectionMode)',
    'Write-Host ("  PicPreview.SizeMode= " + $script:PicPreview.SizeMode)',
    'Write-Host ("  PicPreview.Border  = " + $script:PicPreview.BorderStyle)',
    'Write-Host ("  CboFit.DropDown    = " + $script:CboFit.DropDownStyle)',
    'Write-Host ("  form.StartPosition = " + $form.StartPosition)',
    'Write-Host ("  Prg.Style          = " + $script:Prg.Style)',
    'Write-Host ("  LogBox.Scrollbar   = " + $script:LogBox.HorizontalScrollbar)',
    'foreach ($c in $form.Controls) { [void]$c.Text; [void]$c.Enabled }',
    'Write-Host "CONTROLS_WALK_OK"',
    'try {',
    '    Refresh-Status',
    '    Write-Host "REFRESH_OK: " ',
    '} catch {',
    '    Write-Host ("REFRESH_THREW: " + $_.Exception.Message)',
    '}',
    '$s = @(Sort-FileNames -Names @("frame10.png","frame2.png","frame1.png"))',
    'Write-Host ("SORT: " + ($s -join ","))',
    '$tc = Join-Path $env:TEMP "guibuild_test.cfg"',
    'Set-CfgValue -Path $tc -Pairs @{ "ENABLED" = "0" }',
    '$rc = Read-Cfg -Path $tc',
    'Write-Host ("CFG_ENABLED: " + $rc.Enabled)',
    'Remove-Item $tc -Force -ErrorAction SilentlyContinue',
    'Write-Host "SELFTEST_DONE"',
    '$form.Dispose()',
    ''
)
$code = $code + ($append -join "`r`n")

[IO.File]::WriteAllText($TmpScript, $code, (New-Object Text.UTF8Encoding($true)))
Write-Host "[4] 生成自检脚本: $TmpScript"
Write-Host ''
Write-Host '--- 子进程输出 ---'

# ---- 5. 执行，输出落盘后按 UTF-8 读回来 ----
& powershell -NoProfile -ExecutionPolicy Bypass -File $TmpScript *> $LogFile
$childExit = $LASTEXITCODE

$lines = @()
if (Test-Path $LogFile) {
    $lines = @([IO.File]::ReadAllLines($LogFile, [Text.Encoding]::UTF8))
}
$lines | ForEach-Object { Write-Host ("  " + $_) }

Write-Host ''
Write-Host '---------------------------------------------------------'
$okMark   = @($lines | Where-Object { $_ -match 'SELFTEST_DONE' }).Count -ge 1
$built    = @($lines | Where-Object { $_ -match 'FORM_BUILT_OK' }).Count -ge 1
$badLines = @($lines | Where-Object { $_ -match 'Exception|is not recognized|Cannot convert|无法将|不是内部|SetValueInvocation' })

if ($built -and $okMark -and $badLines.Count -eq 0 -and $childExit -eq 0) {
    Write-Host '窗体构造自检: OK' -ForegroundColor Green
    Write-Host '  上面 REFRESH_OK / SORT / CFG_ENABLED 三行就是主要逻辑的输出'
    $code2 = 0
} else {
    Write-Host '窗体构造自检: 失败' -ForegroundColor Red
    if (-not $built)    { Write-Host '  窗体根本没建起来（FORM_BUILT_OK 没出现）' -ForegroundColor Red }
    if (-not $okMark)   { Write-Host '  自检没有跑完（SELFTEST_DONE 没出现）' -ForegroundColor Red }
    if ($childExit -ne 0) { Write-Host "  子进程退出码 $childExit" -ForegroundColor Red }
    $badLines | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
    $code2 = 1
}

Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
exit $code2
