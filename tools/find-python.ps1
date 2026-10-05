# SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================
#  find-python.ps1 -- 找一个能用的 Python 3（供 tools/ 下的参考实现和测试用）
#
#  为什么单独一个文件：好几个测试都要用 Python，硬编码路径不能进公开仓库，
#  各自复制一份探测逻辑又容易不一致。
#
#  用法：
#      . (Join-Path $PSScriptRoot 'find-python.ps1')
#      $Py = Find-Python
#      if (-not $Py) { Write-Host '没找到 Python，跳过'; exit 0 }
#
#  查找顺序（先找到先用）：
#      1. 显式给的 -Path
#      2. 环境变量 BOOTANIM_PYTHON     <- 想指定就用这个，比如 CI 或自带的解释器
#      3. 仓库里的虚拟环境 .venv / venv / env
#      4. PATH 里的 python / python3
#      5. py 启动器（Windows 官方那个）
#      6. 常见安装位置
#
#  注意：故意**不**接受 Windows 商店那个 python.exe 占位程序
#  （在 %LOCALAPPDATA%\Microsoft\WindowsApps 下），执行它会弹应用商店。
# =====================================================================

function Find-Python {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Quiet
    )

    $candidates = New-Object System.Collections.ArrayList

    # ---- 1) 显式指定 ----
    if ($Path) { [void]$candidates.Add($Path) }

    # ---- 2) 环境变量 ----
    # 给 CI 和"系统里有多个 Python"的情况留的口子。
    # 也方便开发者指向自带的解释器，而不用把绝对路径写进代码。
    if ($env:BOOTANIM_PYTHON) { [void]$candidates.Add($env:BOOTANIM_PYTHON) }

    # ---- 3) 仓库里的虚拟环境 ----
    $repoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($venv in '.venv', 'venv', 'env') {
        foreach ($sub in 'Scripts\python.exe', 'bin/python') {
            $p = Join-Path $repoRoot (Join-Path $venv $sub)
            if (Test-Path -LiteralPath $p) { [void]$candidates.Add($p) }
        }
    }

    # ---- 4) PATH ----
    foreach ($name in 'python', 'python3') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            if ($cmd.Source -notmatch '\\WindowsApps\\') { [void]$candidates.Add($cmd.Source) }
        }
    }

    # ---- 5) py 启动器 ----
    $py = Get-Command 'py' -CommandType Application -ErrorAction SilentlyContinue
    if ($py -and $py.Source) { [void]$candidates.Add($py.Source) }

    # ---- 6) 常见安装位置 ----
    foreach ($v in '313', '312', '311', '310', '39') {
        foreach ($base in @(
            "$env:LOCALAPPDATA\Programs\Python\Python$v",
            "$env:ProgramFiles\Python$v",
            "${env:ProgramFiles(x86)}\Python$v",
            "C:\Python$v")) {
            if ($base -and (Test-Path -LiteralPath $base)) {
                $exe = Join-Path $base 'python.exe'
                if (Test-Path -LiteralPath $exe) { [void]$candidates.Add($exe) }
            }
        }
    }

    # ---- 逐个验证是不是可用的 Python 3 ----
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            $out = & $c -c "import sys; print(sys.version_info[0])" 2>&1
            if ("$out".Trim() -eq '3') {
                if (-not $Quiet) { Write-Verbose "找到 Python: $c" }
                return $c
            }
        } catch {
            # 跑不起来就试下一个
        }
    }

    if (-not $Quiet) {
        Write-Host '  [提示] 没找到可用的 Python 3。'
        Write-Host '         tools/ 下的参考实现和部分测试需要它。'
        Write-Host ''
        Write-Host '         装一个：https://www.python.org/downloads/'
        Write-Host '         或者指定一个：'
        Write-Host '             $env:BOOTANIM_PYTHON = "D:\Python\python.exe"'
        Write-Host '         或者在仓库里建虚拟环境：'
        Write-Host '             python -m venv .venv'
    }
    return $null
}

# 顺带一个"有没有 PIL/Pillow"的检查，测试里常用
function Test-PythonPillow {
    param([string]$Python)
    if (-not $Python) { return $false }
    try {
        $out = & $Python -c "import PIL; print(PIL.__version__)" 2>&1
        return ("$out" -match '^\d')
    } catch { return $false }
}
