# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
  批量切换全项目的 SPDX 许可证标识。

.DESCRIPTION
  把每个源文件里的 `SPDX-License-Identifier: ...` 换成指定的标识，
  并给缺标识的代码文件补上首行。

  **它只改机器可读的 SPDX 标识，不动正文。** 改完之后你还需要手动同步三处文案：

    1. LICENSE            —— 换成对应许可证的完整正文
                             预置的声明段（版权、"or later" 那句）也要跟着改
    2. THIRD_PARTY_NOTICES.md —— 分发义务那一段
    3. README.md          —— 「许可证」一节和徽章

  脚本最后会把这份清单再打印一遍。

  为什么要用 `-or-later` 而不是 `-only`：
    * `GPL-2.0-only` 和 GPLv3 **不兼容**（不能合并成一个作品）。
      本项目会用 GPLv3 的 ffmpeg，所以 v2 必须写 `GPL-2.0-or-later`
    * SPDX 自 2018 年起用 `-or-later` 取代了旧的末尾 `+` 写法
      （`GPL-3.0+` 已废弃，应写 `GPL-3.0-or-later`）

.PARAMETER Id
  目标 SPDX 标识，例如：
    GPL-3.0-or-later（当前值）
    GPL-2.0-or-later
    MIT
    Apache-2.0
    BSD-2-Clause-Patent

.PARAMETER WhatIf
  只显示会改哪些文件，不实际修改。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\set-license.ps1 -Id GPL-2.0-or-later

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\set-license.ps1 -Id GPL-3.0-or-later -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Id
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

# SPDX 标识的合法字符集
if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9.+-]*$') {
    Write-Host "[错误] '$Id' 不像一个 SPDX 标识" -ForegroundColor Red
    Write-Host '       例：GPL-3.0-or-later / GPL-2.0-or-later / MIT / Apache-2.0'
    exit 2
}
if ($Id -match '\+$') {
    Write-Host "[注意] '$Id' 用了已废弃的末尾 '+' 写法" -ForegroundColor Yellow
    Write-Host '       SPDX 自 2018 年起改用 -or-later，例如 GPL-3.0-or-later'
}
if ($Id -match '^GPL-2\.0-only$') {
    Write-Host '[警告] GPL-2.0-only 与 GPLv3 不兼容。' -ForegroundColor Yellow
    Write-Host '       本项目会使用 GPLv3 的 ffmpeg，建议改成 GPL-2.0-or-later。' -ForegroundColor Yellow
    Write-Host '       确实要用的话，请自行确认这一点的后果。' -ForegroundColor Yellow
}

# 各扩展名的注释前缀
$comment = @{
    '.c' = '//'; '.h' = '//'; '.cs' = '//'
    '.ps1' = '#'; '.py' = '#'; '.yml' = '#'; '.yaml' = '#'; '.sh' = '#'; '.cfg' = '#'
    '.bat' = 'rem '; '.cmd' = 'rem '
    '.inf' = '# '; '.dsc' = '# '; '.dec' = '# '
}
# 需要补标识的代码文件类型（文档类只替换、不新增）
$addTo = @('.c', '.h', '.cs', '.ps1', '.py')

$reSpdx = [regex]'SPDX-License-Identifier:\s*[A-Za-z0-9.\-+]+'

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-TextPreserve([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    return @{
        Text = [IO.File]::ReadAllText($Path, $utf8NoBom)
        Bom = $hasBom
    }
}

Write-Host "把全项目的 SPDX 标识改成: $Id"
Write-Host "根目录: $Root"
Write-Host ''

$files = @(Get-ChildItem $Root -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object {
               $_.FullName -notmatch '\\ffmpeg-[^\\]*\\|\\\.git\\|\\__pycache__\\|\\_testdata\\|\\\.bootanim-frames\\' -and
               ($comment.ContainsKey($_.Extension.ToLower()) -or $_.Extension -in '.md', '.txt')
           })

$replaced = 0
$added = 0

foreach ($f in $files) {
    $r = Read-TextPreserve $f.FullName
    $t = $r.Text
    $rel = $f.FullName.Substring($Root.Length + 1)
    $ext = $f.Extension.ToLower()
    $new = $t

    if ($reSpdx.IsMatch($t)) {
        $new = $reSpdx.Replace($t, "SPDX-License-Identifier: $Id")
        if ($new -ne $t) {
            if ($PSCmdlet.ShouldProcess($rel, "替换 SPDX 标识")) {
                [IO.File]::WriteAllText($f.FullName, $new, $(if ($r.Bom) { $utf8Bom } else { $utf8NoBom }))
            }
            Write-Host ("  [替换] {0}" -f $rel)
            $replaced++
        }
    } elseif ($addTo -contains $ext) {
        $lines = $t -split "`n"
        $prefix = $comment[$ext]
        if ($prefix.EndsWith(' ')) { $line = $prefix + "SPDX-License-Identifier: $Id" }
        else { $line = $prefix + " SPDX-License-Identifier: $Id" }
        $pos = if ($lines.Count -gt 0 -and $lines[0].StartsWith('#!')) { 1 } else { 0 }
        $lines = @($lines[0..($pos - 1)]) + @($line) + @($lines[$pos..($lines.Count - 1)])
        $new = $lines -join "`n"
        if ($PSCmdlet.ShouldProcess($rel, "补 SPDX 标识")) {
            [IO.File]::WriteAllText($f.FullName, $new, $(if ($r.Bom) { $utf8Bom } else { $utf8NoBom }))
        }
        Write-Host ("  [新增] {0}" -f $rel)
        $added++
    }
}

Write-Host ''
Write-Host "替换 $replaced 个文件，新增 $added 个文件"
Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host ' 还需要手动改这三处（脚本只管 SPDX 标识，不动正文）' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. LICENSE' -ForegroundColor Yellow
Write-Host '     * 换成对应许可证的完整正文'
Write-Host '     * "第一部分：项目声明" 里版权那句和 "or later" 那句都要跟着改'
Write-Host '     * 常用正文地址：'
Write-Host '         GPLv3        https://www.gnu.org/licenses/gpl-3.0.txt'
Write-Host '         GPLv2        https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt'
Write-Host '         LGPLv3       https://www.gnu.org/licenses/lgpl-3.0.txt'
Write-Host '         Apache-2.0   https://www.apache.org/licenses/LICENSE-2.0.txt'
Write-Host '         MIT          https://opensource.org/license/mit'
Write-Host ''
Write-Host '  2. THIRD_PARTY_NOTICES.md' -ForegroundColor Yellow
Write-Host '     * 「分发本程序时你必须做什么」那一节'
Write-Host '     * 以及和 ffmpeg（GPLv3）的兼容性说明'
Write-Host ''
Write-Host '  3. README.md' -ForegroundColor Yellow
Write-Host '     * 头部的徽章（![License: ...]）'
Write-Host '     * 「13. 许可证」一节'
Write-Host '     * 英文摘要里的 Licensing 那段'
Write-Host ''
Write-Host '改完请跑一遍检查确认没弄坏编码：' -ForegroundColor Green
Write-Host '  powershell -ExecutionPolicy Bypass -File tools\check-textfiles.ps1' -ForegroundColor Green
Write-Host '  powershell -ExecutionPolicy Bypass -File tools\fix-textfiles.ps1' -ForegroundColor Green
