# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  build-gui-exe.ps1 -- 把 PowerShell 版管理工具打包成单个 BootAnimGUI.exe
#
#  依赖：Windows 自带的 .NET Framework C# 编译器（csc.exe）。
#        不需要 .NET SDK、不需要 Visual Studio、不需要联网。
#
#  产物：gui\BootAnimGUI.exe  —— 双击即用，无黑窗口，自动弹 UAC
#
#  用法：powershell -ExecutionPolicy Bypass -File gui\build-gui-exe.ps1
#
#  打包原理：exe 里内嵌了 4 个资源（EspTools.ps1 / BootAnimPacker.ps1 /
#  BootAnimGUI.ps1 / bootanim.cfg）。运行时启动器把它们解到
#  %TEMP%\BootAnimGUI_<版本>\，对 BootAnimGUI.ps1 做三处路径改写并去掉
#  自提权块，然后用隐藏窗口的 powershell.exe 跑它。
#  所以：**改了 .ps1 之后必须重跑本脚本才会反映到 exe 里**。
# =====================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$GuiDir     = $PSScriptRoot
$ProjRoot   = Split-Path -Parent $GuiDir
$InstallDir = Join-Path $ProjRoot 'install'
$OutExe     = Join-Path $GuiDir 'BootAnimGUI.exe'
$RepFile    = Join-Path $env:TEMP 'BootAnimGUI_selfcheck.txt'

Write-Host 'BootAnim 图形界面打包器'
Write-Host "  项目根: $ProjRoot"
Write-Host ''

# ---- 1. 找 C# 编译器 ----
$csc = $null
foreach ($c in @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))) {
    if (Test-Path $c) { $csc = $c; break }
}
if (-not $csc) {
    Write-Host '[错误] 找不到 csc.exe（.NET Framework 4 的 C# 编译器）。' -ForegroundColor Red
    Write-Host '       它通常随 Windows 一起安装。也可以在“启用或关闭 Windows 功能”里'
    Write-Host '       勾选 .NET Framework 4.x。'
    exit 2
}
Write-Host "[1/4] C# 编译器: $csc"

# ---- 2. 检查要内嵌的资源 ----
$res = @(
    @{ Path = (Join-Path $InstallDir 'EspTools.ps1');   Name = 'EspTools.ps1' },
    @{ Path = (Join-Path $GuiDir 'BootAnimPacker.ps1'); Name = 'BootAnimPacker.ps1' },
    @{ Path = (Join-Path $GuiDir 'BootAnimGUI.ps1');    Name = 'BootAnimGUI.ps1' },
    @{ Path = (Join-Path $InstallDir 'bootanim.cfg');   Name = 'bootanim.cfg' }
)
foreach ($r in $res) {
    if (-not (Test-Path $r.Path)) {
        Write-Host "[错误] 缺少资源文件: $($r.Path)" -ForegroundColor Red
        exit 3
    }
}
Write-Host "[2/4] 待内嵌资源 $($res.Count) 个"
foreach ($r in $res) {
    Write-Host ("        {0,-22} {1,7:N0} B" -f $r.Name, (Get-Item $r.Path).Length)
}

# ---- 3. 组装 csc 参数并编译 ----
$src = Join-Path $GuiDir 'BootAnimLauncher.cs'
$ico = Join-Path $GuiDir 'BootAnimGUI.ico'

$cscArgs = New-Object System.Collections.ArrayList
[void]$cscArgs.AddRange([string[]]@(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    '/codepage:65001',
    ('/out:"' + $OutExe + '"'),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll'
))
# 刻意不用 /win32manifest：某些环境下内嵌清单会引发
# "side-by-side configuration is incorrect"。清单能给的唯一实际好处
# （高 DPI 感知）改用运行时的 SetProcessDPIAware()；提权用 runas 重启自己。
# （旁边的 BootAnimGUI.manifest 只是留作参考，没有嵌入。）
if (Test-Path $ico) { [void]$cscArgs.Add('/win32icon:"' + $ico + '"') }
foreach ($r in $res) {
    [void]$cscArgs.Add('/resource:"' + $r.Path + '",' + $r.Name)
}
[void]$cscArgs.Add('"' + $src + '"')

if (Test-Path $OutExe) { Remove-Item $OutExe -Force }
Write-Host '[3/4] 正在编译…'
$out = & $csc @cscArgs 2>&1
$rc = $LASTEXITCODE
if ($out) { $out | ForEach-Object { Write-Host ("        " + $_) } }
if ($rc -ne 0 -or -not (Test-Path $OutExe)) {
    Write-Host "[错误] 编译失败（csc 返回 $rc）" -ForegroundColor Red
    exit 4
}
$exe = Get-Item $OutExe
Write-Host ("[4/4] 产物: {0}  ({1:N0} 字节)" -f $exe.FullName, $exe.Length) -ForegroundColor Green

# ---- 4. 自检 ----
Write-Host ''
Write-Host '--- 自检（--selfcheck，不弹界面）---'
Remove-Item $RepFile -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'BootAnimGUI_1.1.0') -Recurse -Force -ErrorAction SilentlyContinue

$ran = $false
try {
    # 注意：WinExe 用 & 启动时 PowerShell 不会等它，所以下面轮询报告文件
    & $OutExe --selfcheck | Out-Null
    $ran = $true
} catch {
    Write-Host ("  （直接启动被拦住了：" + $_.Exception.Message + "）") -ForegroundColor Yellow
}

if ($ran) {
    for ($i = 0; $i -lt 24 -and -not (Test-Path $RepFile); $i++) { Start-Sleep -Milliseconds 250 }
}

if (-not (Test-Path $RepFile)) {
    Write-Host '  直接启动拿不到报告，改用「加载程序集 + 反射调用自检」：'
    try {
        # Load(byte[]) 而不是 LoadFile(path)：后者会被 CAS 策略以
        # "从网络位置加载程序集" 为由拒绝
        $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($OutExe))
        $t   = $asm.GetType('BootAnimLauncher')
        $mi  = $t.GetMethod('SelfCheck', [Reflection.BindingFlags]'NonPublic,Static')
        $args2 = [object[]]@([string]$GuiDir, [string]$ProjRoot,
                             [string](Join-Path $env:TEMP 'BootAnimGUI_1.1.0'))
        [void]$mi.Invoke($null, $args2)
    } catch {
        Write-Host ("  反射自检也失败：" + $_.Exception.Message) -ForegroundColor Red
    }
}

if (Test-Path $RepFile) {
    [IO.File]::ReadAllLines($RepFile, [Text.Encoding]::UTF8) | ForEach-Object { Write-Host ("  " + $_) }
} else {
    Write-Host '  （没有拿到自检报告）' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '完成。双击 gui\BootAnimGUI.exe 即可使用。'
Write-Host '（原来的 BootAnimGUI.cmd + .ps1 仍然可用；改了 .ps1 要重跑本脚本重新打包）'
