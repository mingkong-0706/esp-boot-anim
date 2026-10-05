# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
  把仓库里的 OWNER/REPO 占位符替换成你的 GitHub 仓库地址。

.DESCRIPTION
  .github/ 下的 issue 模板和工作流里有几处指向仓库自身的链接，用的是
  OWNER/REPO 占位符。发布前跑一次这个脚本把它们换掉。

  会改这些文件：
    .github/ISSUE_TEMPLATE/config.yml
    .github/ISSUE_TEMPLATE/bug_report.yml
    README.md（如果里面留了占位符）
    CHANGELOG.md（版本比较链接）

.PARAMETER Url
  你的仓库地址，形如 https://github.com/你的用户名/仓库名

.PARAMETER Owner
  只要用户名的话可以分别给 -Owner 和 -Repo

.PARAMETER Repo
  仓库名

.PARAMETER WhatIf
  只显示会改什么

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\set-repo-url.ps1 -Url https://github.com/drifterala/esp-boot-anim

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\set-repo-url.ps1 -Owner drifterala -Repo esp-boot-anim
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Url,
    [string]$Owner,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

# ---- 解析出 owner/repo ----
if ($Url) {
    $m = [regex]::Match($Url.Trim().TrimEnd('/'), '^https?://github\.com/([^/]+)/([^/]+?)(\.git)?$')
    if (-not $m.Success) {
        Write-Host "[错误] 看不懂这个地址: $Url" -ForegroundColor Red
        Write-Host '       应该形如 https://github.com/用户名/仓库名'
        exit 2
    }
    $Owner = $m.Groups[1].Value
    $Repo  = $m.Groups[2].Value
}
if (-not $Owner -or -not $Repo) {
    Write-Host '[错误] 请用 -Url，或者同时给 -Owner 和 -Repo' -ForegroundColor Red
    Write-Host ''
    Write-Host '  例：powershell -ExecutionPolicy Bypass -File tools\set-repo-url.ps1 -Url https://github.com/你的用户名/仓库名'
    exit 2
}

$slug     = "$Owner/$Repo"
$fullUrl  = "https://github.com/$slug"
Write-Host "仓库: $slug"
Write-Host ''

# ---- 要处理的文件 ----
$targets = @(
    '.github\ISSUE_TEMPLATE\config.yml',
    '.github\ISSUE_TEMPLATE\bug_report.yml',
    '.github\pull_request_template.md',
    'README.md',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'SECURITY.md'
)

$total = 0
foreach ($rel in $targets) {
    $p = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $t = [IO.File]::ReadAllText($p)
    $orig = $t

    # 先把"相对链接"形式补齐（CHANGELOG 用的是 ../../compare/...）
    $t = $t.Replace('https://github.com/OWNER/REPO', $fullUrl)
    $t = $t.Replace('OWNER/REPO', $slug)

    if ($t -ne $orig) {
        $cnt = ([regex]::Matches($orig, 'OWNER/REPO')).Count
        if ($PSCmdlet.ShouldProcess($rel, "替换 $cnt 处")) {
            [IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("  [已替换] {0,-42} {1} 处" -f $rel, $cnt) -ForegroundColor Green
            $total += $cnt
        } else {
            Write-Host ("  [将替换] {0,-42} {1} 处" -f $rel, $cnt)
        }
    }
}

Write-Host ''
if ($total -eq 0) {
    Write-Host '没有找到 OWNER/REPO 占位符（可能已经替换过了）' -ForegroundColor Yellow
} else {
    Write-Host "共替换 $total 处" -ForegroundColor Green
}
Write-Host ''
Write-Host '别忘了顺手检查这两处（脚本不会自动改，因为你可能想用别的名字）：'
Write-Host '  * LICENSE 里 "第一部分：项目声明" 那段的版权署名'
Write-Host '    （现在是 "Copyright (C) 2024 BootAnim contributors"）'
Write-Host '  * install\Install-App.ps1 里的 $Publisher 变量'
Write-Host ''
Write-Host '接下来：'
Write-Host "  git init -b main"
Write-Host "  git add -A"
Write-Host '  git commit -m "chore: 首次提交"'
Write-Host "  git remote add origin $fullUrl.git"
Write-Host '  git push -u origin main'
