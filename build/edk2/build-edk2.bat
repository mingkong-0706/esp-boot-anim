@echo off
rem ===================================================================
rem  build-edk2.bat -- build bootanim.efi with EDK2 on Windows.
rem
rem  Usage:
rem     build-edk2.bat [EDK2 path] [toolchain] [target] [arch]
rem
rem  Examples:
rem     build-edk2.bat D:\edk2
rem     build-edk2.bat D:\edk2 VS2022 RELEASE X64
rem     build-edk2.bat D:\edk2 GCC    RELEASE X64
rem
rem  You can also just set the environment variables
rem  EDK2_DIR / EDK2_TOOLCHAIN / EDK2_TARGET / EDK2_ARCH.
rem
rem  Output: dist\bootanim.efi
rem
rem  IMPORTANT: run this from a "Developer Command Prompt for VS 2022",
rem  otherwise cl.exe is not on PATH and edksetup.bat will fail.
rem
rem  IMPORTANT: this file is deliberately pure ASCII. cmd.exe parses
rem  .bat/.cmd files using the OEM code page, and a mis-decoded UTF-8
rem  character can produce a stray '|' or '&' that cmd then executes as
rem  a command. Chinese documentation lives in README.md and the Chinese build guide.
rem
rem  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
rem ===================================================================
setlocal EnableDelayedExpansion

set "HERE=%~dp0"
pushd "%HERE%..\.." >nul
set "PROJ=%CD%"
popd >nul

if not "%~1"=="" set "EDK2_DIR=%~1"
if not "%~2"=="" set "EDK2_TOOLCHAIN=%~2"
if not "%~3"=="" set "EDK2_TARGET=%~3"
if not "%~4"=="" set "EDK2_ARCH=%~4"

if "%EDK2_DIR%"=="" (
  echo [ERROR] No EDK2 path given. Usage: build-edk2.bat D:\edk2
  echo         Or set the EDK2_DIR environment variable.
  exit /b 2
)
if "%EDK2_TARGET%"==""    set "EDK2_TARGET=RELEASE"
if "%EDK2_ARCH%"==""      set "EDK2_ARCH=X64"

if not exist "%EDK2_DIR%\edksetup.bat" (
  echo [ERROR] "%EDK2_DIR%" has no edksetup.bat - wrong EDK2 path?
  exit /b 2
)

rem ---------- toolchain: auto-detect when not given ----------
if not "%EDK2_TOOLCHAIN%"=="" goto :tc_done
if not exist "%EDK2_DIR%\Conf\tools_def.txt" (
  echo [NOTE] %EDK2_DIR%\Conf\tools_def.txt does not exist yet.
  echo        Toolchain auto-detect needs one "edksetup.bat Rebuild" run
  echo        first; falling back to VS2022.
  set "EDK2_TOOLCHAIN=VS2022"
  goto :tc_done
)
set "TC="
for %%T in (VS2022 VS2019 GCC CLANGDWARF CLANGPDB CLANG38 GCC5) do (
  if not defined TC (
    findstr /C:"*_%%T_*_*_" "%EDK2_DIR%\Conf\tools_def.txt" >nul 2>&1 && set "TC=%%T"
  )
)
if not defined TC (
  echo [ERROR] Could not auto-detect a toolchain in
  echo         %EDK2_DIR%\Conf\tools_def.txt
  echo         Pass one explicitly, e.g.: build-edk2.bat %EDK2_DIR% VS2022
  exit /b 4
)
set "EDK2_TOOLCHAIN=!TC!"
echo       (auto-detected toolchain: !TC!)
:tc_done

echo ==========================================================
echo  Project  : %PROJ%
echo  EDK2     : %EDK2_DIR%
echo  Toolchain: %EDK2_TOOLCHAIN%
echo  Target   : %EDK2_TARGET%
echo  Arch     : %EDK2_ARCH%
echo ==========================================================

rem ---------- 1. copy sources and package files ----------
set "PKG=%EDK2_DIR%\BootAnimPkg"
if not exist "%PKG%\src" mkdir "%PKG%\src" >nul 2>&1

copy /Y "%PROJ%\src\*.c" "%PKG%\src\" >nul || goto :copyfail
copy /Y "%PROJ%\src\*.h" "%PKG%\src\" >nul || goto :copyfail
copy /Y "%PROJ%\build\edk2\BootAnim.inf"      "%PKG%\BootAnim.inf"      >nul || goto :copyfail
copy /Y "%PROJ%\build\edk2\BootAnimPkg.dec"   "%PKG%\BootAnimPkg.dec"   >nul || goto :copyfail
copy /Y "%PROJ%\build\edk2\BootAnimPkg.dsc"   "%PKG%\BootAnimPkg.dsc"   >nul || goto :copyfail
if not exist "%PKG%\Include" mkdir "%PKG%\Include" >nul 2>&1

rem Refresh the [LibraryClasses] section from MdePkg, so we never miss a
rem mapping when EDK2 adds a new library class (e.g. RegisterFilterLib).
set "PYCMD="
where python >nul 2>&1 && set "PYCMD=python"
if not defined PYCMD where python3 >nul 2>&1 && set "PYCMD=python3"
if defined PYCMD (
  if exist "%HERE%make_dsc.py" (
    "%PYCMD%" "%HERE%make_dsc.py" "%EDK2_DIR%" "%PKG%\BootAnimPkg.dsc"
    if errorlevel 1 echo [NOTE] make_dsc.py failed - keeping the built-in LibraryClasses list
  )
) else (
  echo [NOTE] python not found - skipping the LibraryClasses refresh
)

echo [1/4] Sources copied to %PKG%

rem ---------- 2. initialise the EDK2 environment ----------
pushd "%EDK2_DIR%" >nul
call edksetup.bat Rebuild
if errorlevel 1 (
  popd >nul
  echo [ERROR] edksetup.bat failed. Make sure the Visual Studio
  echo         "Desktop development with C++" workload is installed.
  exit /b 3
)
echo [2/4] EDK2 environment ready

rem ---------- 3. build ----------
build -p BootAnimPkg\BootAnimPkg.dsc -a %EDK2_ARCH% -t %EDK2_TOOLCHAIN% -b %EDK2_TARGET% -n 4
if errorlevel 1 (
  popd >nul
  echo [ERROR] build failed - see the compiler output above.
  exit /b 4
)
popd >nul
echo [3/4] Build finished

rem ---------- 4. collect the artifact ----------
set "EFI=%EDK2_DIR%\Build\BootAnimPkg\%EDK2_TARGET%_%EDK2_TOOLCHAIN%\%EDK2_ARCH%\BootAnim.efi"
if not exist "%EFI%" (
  echo [ERROR] Artifact not found: %EFI%
  echo         Check the build output and the Build\BootAnimPkg directory.
  exit /b 5
)
if not exist "%PROJ%\dist" mkdir "%PROJ%\dist" >nul 2>&1
copy /Y "%EFI%" "%PROJ%\dist\bootanim.efi" >nul
echo [4/4] Artifact: %PROJ%\dist\bootanim.efi
for %%F in ("%PROJ%\dist\bootanim.efi") do echo        size: %%~zF bytes
echo.
echo Next:
echo   1) Run install\Install-BootAnim.ps1 in an ADMIN PowerShell, or
echo   2) Use gui\BootAnimGUI.cmd (graphical manager)
exit /b 0

:copyfail
echo [ERROR] Failed to copy sources into "%PKG%".
echo         If EDK2 lives under Program Files you need administrator rights.
exit /b 3
