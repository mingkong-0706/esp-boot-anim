# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  check-textfiles.ps1 -- 检查各类文本文件的编码与行尾是否符合要求
#
#  为什么需要这个：不同的解释器对编码的容忍度差别极大，
#  踩过一次坑（.cmd 用 UTF-8 存中文 → cmd.exe 按 GBK 误读 → 中文字节里
#  冒出 '|' / '&' → 后半行被当命令执行），所以固化下来自动检查。
#
#  规则：
#    .bat/.cmd   必须纯 ASCII + CRLF
#                  cmd.exe 按 OEM 代码页逐行解析，非 ASCII 会出人命；
#                  裸 LF 会让 goto :label 和 (...) 块解析出错
#    .ps1        必须带 UTF-8 BOM
#                  否则 Windows PowerShell 5.1 会按系统 ANSI 代码页读，
#                  中文注释会变乱码甚至把语法搞坏
#    .inf/.dsc/.dec  必须纯 ASCII（EDK2 的构建工具是 Python 写的，
#                  在非 UTF-8 locale 下会解码失败）
#    .c/.h       必须带 UTF-8 BOM（MSVC 默认按系统代码页读无 BOM 的源文件）
#    .cfg        不允许带 BOM（UEFI 程序读它，虽然能处理但没必要）
#
#  用法: powershell -ExecutionPolicy Bypass -File tools\check-textfiles.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

$script:pass = 0
$script:fail = 0
function Check($cond, $what) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; Write-Host "  [FAIL] $what" -ForegroundColor Red }
}

function Get-Info([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $nonAscii = 0
    foreach ($x in $b) { if ($x -gt 127) { $nonAscii++ } }
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $crlf = 0; $bareLf = 0
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -eq 10) {
            if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $bareLf++ }
        }
    }
    return [PSCustomObject]@{ NonAscii = $nonAscii; Bom = $bom; Crlf = $crlf; BareLf = $bareLf }
}

$all = @(Get-ChildItem $Root -Recurse -File |
         Where-Object { $_.FullName -notmatch '\\_testdata\\|\\__pycache__\\|\.zip$' })

Write-Host "检查 $($all.Count) 个文件，根目录 $Root"
Write-Host ''

# ---- .bat / .cmd ----
Write-Host '[1] .bat / .cmd : 必须纯 ASCII + CRLF'
$n = 0
foreach ($f in ($all | Where-Object { $_.Extension -in '.bat', '.cmd' })) {
    $n++
    $i = Get-Info $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)
    Check ($i.NonAscii -eq 0) "$rel 含 $($i.NonAscii) 个非 ASCII 字节（cmd.exe 会误读并可能执行出乱命令）"
    Check ($i.BareLf -eq 0) "$rel 有 $($i.BareLf) 个裸 LF（cmd.exe 解析 goto/括号块会出错）"
    Write-Host ("  {0,-34} 非ASCII={1,-3} CRLF={2,-4} 裸LF={3}" -f $rel, $i.NonAscii, $i.Crlf, $i.BareLf)
}
Check ($n -gt 0) "找到 .bat/.cmd 文件（找到 $n 个）"

# ---- .ps1 ----
Write-Host ''
Write-Host '[2] .ps1 : 必须带 UTF-8 BOM'
foreach ($f in ($all | Where-Object { $_.Extension -eq '.ps1' })) {
    $i = Get-Info $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)
    Check ($i.Bom) "$rel 缺少 UTF-8 BOM（Windows PowerShell 5.1 会按 ANSI 读，中文注释会乱码）"
    Write-Host ("  {0,-34} BOM={1}" -f $rel, $i.Bom)
}

# ---- EDK2 元数据 ----
Write-Host ''
Write-Host '[3] .inf / .dsc / .dec : 必须纯 ASCII'
foreach ($f in ($all | Where-Object { $_.Extension -in '.inf', '.dsc', '.dec' })) {
    $i = Get-Info $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)
    Check ($i.NonAscii -eq 0) "$rel 含 $($i.NonAscii) 个非 ASCII 字节（EDK2 构建工具可能解码失败）"
    Write-Host ("  {0,-34} 非ASCII={1}" -f $rel, $i.NonAscii)
}

# ---- C 源文件 ----
Write-Host ''
Write-Host '[4] .c / .h / .cs : 必须带 UTF-8 BOM'
foreach ($f in ($all | Where-Object { $_.Extension -in '.c', '.h', '.cs' })) {
    $i = Get-Info $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)
    Check ($i.Bom) "$rel 缺少 UTF-8 BOM（MSVC/csc 默认按系统代码页读源文件）"
    Write-Host ("  {0,-34} BOM={1}" -f $rel, $i.Bom)
}

# ---- 配置文件 ----
Write-Host ''
Write-Host '[5] .cfg : 不应带 BOM'
foreach ($f in ($all | Where-Object { $_.Extension -eq '.cfg' -and $_.FullName -notmatch '\\dist\\' })) {
    $i = Get-Info $f.FullName
    $rel = $f.FullName.Substring($Root.Length + 1)
    Check (-not $i.Bom) "$rel 带了 BOM（虽然程序能处理，但没必要）"
    Write-Host ("  {0,-34} BOM={1}" -f $rel, $i.Bom)
}

# ---- 许可证声明 ----
# 每个代码文件都要声明 SPDX 标识，而且全项目必须一致。
# 这样 tools\set-license.ps1 换许可证时漏改文件会被立刻发现。
Write-Host ''
Write-Host '[6] 代码文件必须声明 SPDX 许可证标识，且全项目一致'
$spdxRe = [regex]'SPDX-License-Identifier:\s*([A-Za-z0-9.\-+]+)'
$ids = @{}
$missingSpdx = @()
foreach ($f in ($all | Where-Object { $_.Extension -in '.c', '.h', '.ps1', '.cs', '.py' })) {
    $txt = [IO.File]::ReadAllText($f.FullName)
    $m = $spdxRe.Match($txt)
    $rel = $f.FullName.Substring($Root.Length + 1)
    if (-not $m.Success) {
        $missingSpdx += $rel
    } else {
        $id = $m.Groups[1].Value
        if (-not $ids.ContainsKey($id)) { $ids[$id] = @() }
        $ids[$id] += $rel
    }
}
Check ($missingSpdx.Count -eq 0) ("缺 SPDX 标识的代码文件: " + ($missingSpdx -join ', '))
Check ($ids.Keys.Count -le 1) ("SPDX 标识不唯一: " + (($ids.Keys | Sort-Object) -join ', '))
foreach ($k in ($ids.Keys | Sort-Object)) {
    Write-Host ("  {0,-26} {1} 个文件" -f $k, $ids[$k].Count)
}
if ($ids.Keys.Count -eq 1) {
    Write-Host ("  -> 全项目统一使用 " + ($ids.Keys | Select-Object -First 1))
}

Write-Host ''
Write-Host '========================================================='
if ($script:fail -eq 0) { Write-Host "$($script:pass) passed, 0 failed" -ForegroundColor Green }
else { Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor Red }
Write-Host '========================================================='
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
