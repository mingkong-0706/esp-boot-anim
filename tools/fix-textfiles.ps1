# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
  把各类文本文件的编码和行尾修正到本项目要求的规范。

.DESCRIPTION
  这是 tools\check-textfiles.ps1 的"自动修复"版本。检查脚本只报告，
  这个脚本动手改。CI 上跑检查，本地想省事就跑这个。

  规则（和 .editorconfig、.gitattributes、check-textfiles.ps1 一一对应）：

    .ps1 / .c / .h / .cs   补上 UTF-8 BOM
                           没有 BOM 时 Windows PowerShell 5.1 和 MSVC
                           会按系统 ANSI 代码页读，中文注释变乱码甚至破坏语法
    .bat / .cmd            转成纯 ASCII + CRLF
                           cmd.exe 按 OEM 代码页逐行解析，UTF-8 中文被误读时
                           字节里会冒出 | 或 &，后半行会被当命令执行；
                           裸 LF 会让 goto :label 和 (...) 块解析出错
    .inf / .dsc / .dec     转成纯 ASCII（EDK2 构建工具在非 UTF-8 locale 下会解码失败）
    .cfg                   去掉 BOM（UEFI 程序直接读它）

.PARAMETER WhatIf
  只报告要改什么，不实际修改。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\fix-textfiles.ps1
  powershell -ExecutionPolicy Bypass -File tools\fix-textfiles.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:fixed = 0
$script:scanned = 0

function Get-Files([string[]]$Patterns) {
    return @(Get-ChildItem $Root -Recurse -File -Include $Patterns -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\_testdata\\|\\__pycache__\\|\\ffmpeg-[^\\]*\\' })
}

function Get-Bytes([string]$Path) { return [IO.File]::ReadAllBytes($Path) }

function Test-HasBom([byte[]]$B) {
    return ($B.Length -ge 3 -and $B[0] -eq 0xEF -and $B[1] -eq 0xBB -and $B[2] -eq 0xBF)
}

function Test-IsAscii([byte[]]$B) {
    foreach ($x in $B) { if ($x -gt 127) { return $false } }
    return $true
}

function Get-BareLfCount([byte[]]$B) {
    $n = 0
    for ($i = 0; $i -lt $B.Length; $i++) {
        if ($B[$i] -eq 10 -and ($i -eq 0 -or $B[$i - 1] -ne 13)) { $n++ }
    }
    return $n
}

function Normalize([string]$Path, [bool]$WantBom) {
    $script:scanned++
    $b = Get-Bytes $Path
    $rel = $Path.Substring($Root.Length + 1)
    $hasBom = Test-HasBom $b
    $text = [IO.File]::ReadAllText($Path, $Utf8NoBom)
    $changed = @()

    if ($hasBom -ne $WantBom) { $changed += $(if ($WantBom) { '补 BOM' } else { '去 BOM' }) }

    # 行尾：批处理必须 CRLF，其它统一 LF
    $isBatch = ($Path -match '\.(bat|cmd)$')
    $bareLf = Get-BareLfCount $b
    $hasCrlf = ($text -match "`r`n")
    if ($isBatch) {
        if ($bareLf -gt 0) { $changed += "CRLF（原有 $bareLf 个裸 LF）"; $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n" }
    } elseif ($hasCrlf) {
        $changed += 'LF（原来是 CRLF）'
        $text = $text -replace "`r`n", "`n"
    }

    # 纯 ASCII 要求
    if ($Path -match '\.(bat|cmd|inf|dsc|dec)$') {
        $nb = [Text.Encoding]::UTF8.GetBytes($text)
        if (-not (Test-IsAscii $nb)) {
            Write-Host "  [需人工处理] $rel 含非 ASCII 字符，本脚本不会自动删掉它们" -ForegroundColor Yellow
            Write-Host "               cmd.exe / EDK2 构建工具会误读，请改成英文或用 ASCII 转义" -ForegroundColor Yellow
            return
        }
    }

    if ($changed.Count -eq 0) { return }

    if ($PSCmdlet.ShouldProcess($rel, ($changed -join '，'))) {
        $enc = if ($WantBom) { $Utf8Bom } else { $Utf8NoBom }
        [IO.File]::WriteAllText($Path, $text, $enc)
        $script:fixed++
        Write-Host ("  [已修正] {0,-46} {1}" -f $rel, ($changed -join '，')) -ForegroundColor Green
    } else {
        Write-Host ("  [将修正] {0,-46} {1}" -f $rel, ($changed -join '，'))
    }
}

Write-Host "修正文本文件编码/行尾，根目录 $Root"
Write-Host ''

Write-Host '[1] .ps1 / .c / .h / .cs  ->  UTF-8 带 BOM，LF'
foreach ($f in (Get-Files @('*.ps1', '*.c', '*.h', '*.cs'))) { Normalize $f.FullName $true }

Write-Host ''
Write-Host '[2] .bat / .cmd  ->  纯 ASCII，CRLF'
foreach ($f in (Get-Files @('*.bat', '*.cmd'))) { Normalize $f.FullName $false }

Write-Host ''
Write-Host '[3] .inf / .dsc / .dec  ->  纯 ASCII，LF'
foreach ($f in (Get-Files @('*.inf', '*.dsc', '*.dec'))) { Normalize $f.FullName $false }

Write-Host ''
Write-Host '[4] .cfg  ->  不带 BOM'
foreach ($f in (Get-Files @('*.cfg'))) { Normalize $f.FullName $false }

Write-Host ''
Write-Host '========================================================='
if ($script:fixed -eq 0) {
    Write-Host "扫描 $($script:scanned) 个文件，没有需要修正的" -ForegroundColor Green
} else {
    Write-Host "扫描 $($script:scanned) 个文件，修正了 $($script:fixed) 个" -ForegroundColor Green
}
Write-Host '========================================================='
Write-Host ''
Write-Host '改完请再跑一次检查确认：'
Write-Host '  powershell -ExecutionPolicy Bypass -File tools\check-textfiles.ps1'
