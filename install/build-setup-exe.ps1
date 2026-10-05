<#
.SYNOPSIS
  把安装程序打包成单个 exe（BootAnimSetup.exe）。

.DESCRIPTION
  和 gui\build-gui-exe.ps1 是同一套思路：用 Windows 自带的 csc.exe 编译一个
  C# 启动器，把"应用负载"作为内嵌资源带进去。

  负载内容（解包后保持和源码仓库一样的目录结构）：
    gui\BootAnimGUI.exe         主程序（必须先用 build-gui-exe.ps1 打出来）
    install\Install-App.ps1     真正的安装逻辑
    install\Uninstall-App.ps1   卸载
    install\bootanim.cfg        配置模板
    dist\bootanim.efi           引导程序（有就带上）
    LICENSE / THIRD_PARTY_NOTICES.md / README.md / 编译说明.md / docs\
    可选的 ffmpeg-src\ffmpeg.exe（加 -WithFFmpeg）

  产物：install\BootAnimSetup.exe
    不内置 ffmpeg 约 1~2 MB；内置 ffmpeg 约 108 MB。

.PARAMETER WithFFmpeg
  把 ffmpeg.exe 一起内置（产物约 101 MB）。内置会自动把它的 LICENSE 和
  README.txt 一起带上，满足 GPLv3 的署名要求。
  许可证上本项目是 GPL-3.0-or-later，和 GPLv3 的 ffmpeg 同族，没有冲突。
  注意：本项目的分发义务不变 —— 发二进制就要能提供源码，见 THIRD_PARTY_NOTICES.md。

.PARAMETER FFmpegPath
  指定用哪个 ffmpeg.exe。不指定就按和 GUI 一样的顺序自动找。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\build-setup-exe.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install\build-setup-exe.ps1 -WithFFmpeg

.NOTES
  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
#>
[CmdletBinding()]
param(
    [switch]$WithFFmpeg,
    [string]$FFmpegPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$InstallDir = $PSScriptRoot
$Root       = Split-Path -Parent $InstallDir
$GuiDir     = Join-Path $Root 'gui'
$OutExe     = Join-Path $InstallDir 'BootAnimSetup.exe'
$Work       = Join-Path $env:TEMP ('basSetup_' + [guid]::NewGuid().ToString('N').Substring(0, 8))

Write-Host 'BootAnim 安装程序打包器'
Write-Host "  项目根: $Root"
Write-Host ''

function Fail([string]$m) { Write-Host "[错误] $m" -ForegroundColor Red; exit 2 }

# ---- 1. 找 csc ----
$csc = $null
foreach ($c in @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))) {
    if (Test-Path $c) { $csc = $c; break }
}
if (-not $csc) { Fail '找不到 csc.exe（.NET Framework 4 的 C# 编译器）' }
Write-Host "[1/5] C# 编译器: $csc"

# ---- 2. 检查主程序 ----
$guiExe = Join-Path $GuiDir 'BootAnimGUI.exe'
if (-not (Test-Path -LiteralPath $guiExe)) {
    Fail "找不到主程序 $guiExe`n       先执行: powershell -ExecutionPolicy Bypass -File gui\build-gui-exe.ps1"
}
Write-Host "[2/5] 主程序: $([int]((Get-Item $guiExe).Length/1KB)) KB"

# ---- 3. 收集负载 ----
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$payload = New-Object System.Collections.ArrayList

function Add-Item([string]$src, [string]$rel) {
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    if ((Get-Item -LiteralPath $src).PSIsContainer) {
        foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -File)) {
            $sub = $f.FullName.Substring($src.Length).TrimStart('\', '/')
            [void]$payload.Add(@{ Src = $f.FullName; Rel = ($rel.TrimEnd('/') + '/' + $sub).Replace('\', '/') })
        }
    } else {
        [void]$payload.Add(@{ Src = $src; Rel = $rel.Replace('\', '/') })
    }
    return $true
}

[void](Add-Item $guiExe                              'gui/BootAnimGUI.exe')
[void](Add-Item (Join-Path $InstallDir 'Install-App.ps1')   'install/Install-App.ps1')
[void](Add-Item (Join-Path $InstallDir 'Uninstall-App.ps1') 'install/Uninstall-App.ps1')
[void](Add-Item (Join-Path $InstallDir 'bootanim.cfg')      'install/bootanim.cfg')
[void](Add-Item (Join-Path $Root 'LICENSE')                 'LICENSE')
[void](Add-Item (Join-Path $Root 'THIRD_PARTY_NOTICES.md')  'THIRD_PARTY_NOTICES.md')
[void](Add-Item (Join-Path $Root 'README.md')               'README.md')
[void](Add-Item (Join-Path $Root '编译说明.md')              '编译说明.md')
[void](Add-Item (Join-Path $Root 'docs')                    'docs')
[void](Add-Item (Join-Path $Root 'dist\bootanim.efi')       'dist/bootanim.efi')

# ffmpeg（可选）
$srcFF = $null
if ($WithFFmpeg) {
    if ($FFmpegPath) {
        if (-not (Test-Path -LiteralPath $FFmpegPath)) { Fail "指定的 ffmpeg 不存在: $FFmpegPath" }
        $srcFF = (Resolve-Path -LiteralPath $FFmpegPath).Path
    } else {
        $direct = @(
            (Join-Path $Root 'ffmpeg.exe'), (Join-Path $Root 'bin\ffmpeg.exe'),
            (Join-Path $Root 'ffmpeg\bin\ffmpeg.exe'), (Join-Path $Root 'tools\ffmpeg.exe'),
            (Join-Path $GuiDir 'ffmpeg.exe'))
        foreach ($c in $direct) { if (Test-Path -LiteralPath $c) { $srcFF = $c; break } }
        if (-not $srcFF) {
            $hit = @(Get-ChildItem -LiteralPath $Root -Recurse -Depth 4 -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -notmatch '\\AppData\\' } |
                     Sort-Object { $_.FullName.Length } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $srcFF = $hit[0].FullName }
        }
        if (-not $srcFF) { Fail '在项目里没找到 ffmpeg.exe（可以用 -FFmpegPath 指定）' }
    }
    [void](Add-Item $srcFF 'ffmpeg-src/ffmpeg.exe')
    # GPL 合规：把 ffmpeg 自己的许可证和构建说明一起带上
    $ffRoot = Split-Path -Parent (Split-Path -Parent $srcFF)
    [void](Add-Item (Join-Path $ffRoot 'LICENSE')    'ffmpeg-src/LICENSE')
    [void](Add-Item (Join-Path $ffRoot 'README.txt') 'ffmpeg-src/README.txt')
    Write-Host "[3/5] 内置 ffmpeg: $srcFF  ($([int]((Get-Item $srcFF).Length/1MB)) MB)"
    Write-Host '      [注意] 该构建是 GPL v3。会连它的 LICENSE/README.txt 一起带上；本项目是 GPL-3.0-or-later，同族无冲突' -ForegroundColor Yellow
} else {
    Write-Host '[3/5] 不内置 ffmpeg（安装后由使用者自行提供，或加 -WithFFmpeg 重新打包）'
}
Write-Host "      负载文件数: $($payload.Count)"

# ---- 4. 生成 manifest 并编译 ----
if ($payload.Count -eq 0) { Fail '负载是空的' }
$manifestPath = Join-Path $Work 'payload.manifest'
$lines = New-Object System.Collections.ArrayList
$used = @{}
$idx = 0
foreach ($p in $payload) {
    # 资源名不能和别的重名，加序号前缀保证唯一
    $resName = ('p{0:D4}_' -f $idx) + ($p.Rel -replace '[\\/]', '__')
    $idx++
    [void]$lines.Add(($resName + '|' + $p.Rel))
    $p.Res = $resName
}
[IO.File]::WriteAllLines($manifestPath, [string[]]$lines.ToArray(), (New-Object Text.UTF8Encoding($false)))

$src = Join-Path $InstallDir 'BootAnimSetup.cs'
$ico = Join-Path $GuiDir 'BootAnimGUI.ico'
if (-not (Test-Path $src)) { Fail "找不到 $src" }

$cscArgs = New-Object System.Collections.ArrayList
[void]$cscArgs.AddRange([string[]]@(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', '/codepage:65001',
    ('/out:"' + $OutExe + '"'),
    '/reference:System.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll'
))
if (Test-Path $ico) { [void]$cscArgs.Add('/win32icon:"' + $ico + '"') }
[void]$cscArgs.Add('/resource:"' + $manifestPath + '",payload.manifest')
foreach ($p in $payload) { [void]$cscArgs.Add('/resource:"' + $p.Src + '",' + $p.Res) }
[void]$cscArgs.Add('"' + $src + '"')

if (Test-Path $OutExe) { Remove-Item $OutExe -Force }
Write-Host '[4/5] 正在编译…'
$out = & $csc @cscArgs 2>&1
$rc = $LASTEXITCODE
if ($out) { $out | ForEach-Object { Write-Host "      $_" } }
if ($rc -ne 0 -or -not (Test-Path $OutExe)) { Fail "编译失败（csc 返回 $rc）" }

$exe = Get-Item $OutExe
Write-Host ("[5/5] 产物: {0}  ({1:N1} MB)" -f $exe.FullName, ($exe.Length / 1MB)) -ForegroundColor Green

# ---- 5. 自检：能解包吗 ----
Write-Host ''
Write-Host '--- 自检（--silent 会把负载解包，这里只验证资源完整性）---'
try {
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($OutExe))
    $names = @($asm.GetManifestResourceNames())
    Write-Host "      内嵌资源 $($names.Count) 个（含 manifest）"
    $mf = $asm.GetManifestResourceStream('payload.manifest')
    if ($mf) {
        $sr = New-Object IO.StreamReader($mf, [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd(); $sr.Dispose()
        $cnt = @($txt -split "`n" | Where-Object { $_.Trim() }).Count
        Write-Host "      manifest 条目 $cnt 条"
        $missing = @()
        foreach ($ln in ($txt -split "`n")) {
            $l = $ln.Trim()
            if (-not $l) { continue }
            $rn = $l.Substring(0, $l.IndexOf('|'))
            if ($names -notcontains $rn) { $missing += $rn }
        }
        if ($missing.Count -eq 0) { Write-Host '      [OK] manifest 里的资源全都在' -ForegroundColor Green }
        else { Write-Host "      [失败] 缺 $($missing.Count) 个资源" -ForegroundColor Red }
    } else {
        Write-Host '      [失败] 读不到 payload.manifest' -ForegroundColor Red
    }
} catch {
    Write-Host "      自检失败: $($_.Exception.Message)" -ForegroundColor Yellow
}

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "完成。双击 install\BootAnimSetup.exe 即可安装。"
Write-Host '（安装逻辑在 install\Install-App.ps1，改了它重新跑本脚本即可）'
