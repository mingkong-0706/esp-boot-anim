@echo off
rem ===================================================================
rem  BootAnimGUI.cmd -- launcher for the BootAnim management GUI.
rem
rem  Just double-click it. The script asks for administrator rights (UAC)
rem  because it needs to write to the EFI System Partition.
rem
rem  IMPORTANT: this file is deliberately pure ASCII.
rem  cmd.exe parses .bat/.cmd files using the OEM code page. If a UTF-8
rem  Chinese character gets mis-decoded, one of its bytes can land on
rem  '|' or '&', and cmd will then execute the rest of the line as a
rem  command. That is exactly why all Chinese messages live in
rem  BootAnimGUI.ps1 (which is UTF-8 with a BOM, so PowerShell reads it
rem  correctly) instead of here.
rem
rem  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
rem ===================================================================
setlocal
set "HERE=%~dp0"

rem Windows PowerShell 5.1 specifically: the imaging kernel relies on the
rem C# compiler and System.Drawing that ship with .NET Framework.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%HERE%BootAnimGUI.ps1"

if errorlevel 1 (
    echo.
    echo ============================================================
    echo  The script exited with an error - see the messages above.
    echo  Press any key to close this window.
    echo ============================================================
    pause >nul
)
endlocal
