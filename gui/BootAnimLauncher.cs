// =====================================================================
//  BootAnimLauncher.cs -- 把 PowerShell 版管理工具包成一个单文件 exe
//
//  它做的事：
//    1. 把自己所在目录（必要时向上找几层）当作项目根，用来定位
//       dist\bootanim.efi 和 install\bootanim.cfg
//    2. 把内嵌的 4 个资源解包到 %TEMP%\BootAnimGUI_<版本>\
//       （EspTools.ps1 / BootAnimPacker.ps1 / BootAnimGUI.ps1 / bootanim.cfg）
//    3. 对解出来的 BootAnimGUI.ps1 做三处文本改写：
//         $GuiDir    -> 临时目录（这样能找到旁边解出来的两个 .ps1）
//         $ProjRoot  -> 真实项目根
//         $InstallDir-> 临时目录
//       并去掉脚本里的自提权块（提权改由 exe 的清单负责）
//    4. 用 CreateNoWindow 起一个隐藏的 powershell.exe 跑它，等它结束
//    5. 清理临时目录
//
//  为什么不在进程内托管 PowerShell 引擎：那样要引用 GAC 里的
//  System.Management.Automation.dll，跨版本行为差异大；起子进程更稳，
//  而且能把 PowerShell 的错误原样暴露出来。
//
//  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
// =====================================================================

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class BootAnimLauncher
{
    private const string Version = "1.1.0";

    // 高 DPI 感知：不用应用程序清单（清单在某些环境下会引发
    // "side-by-side configuration is incorrect"），改成运行时调用 API。
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetProcessDPIAware(); } catch { }
        bool selfCheck = false;
        foreach (string a in args)
        {
            if (string.Equals(a, "--selfcheck", StringComparison.OrdinalIgnoreCase))
            {
                selfCheck = true;
            }
        }

        string exePath;
        try
        {
            exePath = Process.GetCurrentProcess().MainModule.FileName;
        }
        catch
        {
            exePath = Assembly.GetExecutingAssembly().Location;
        }

        string exeDir = Path.GetDirectoryName(exePath);
        if (string.IsNullOrEmpty(exeDir))
        {
            exeDir = Environment.CurrentDirectory;
        }

        string projRoot = FindProjectRoot(exeDir);
        string tempDir = Path.Combine(Path.GetTempPath(), "BootAnimGUI_" + Version);

        if (selfCheck)
        {
            return SelfCheck(exeDir, projRoot, tempDir);
        }

        if (!IsAdministrator())
        {
            // 用 runas 把自己重启一次，弹 UAC
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exePath);
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                psi.WorkingDirectory = projRoot;
                StringBuilder argLine = new StringBuilder();
                foreach (string a in args)
                {
                    if (argLine.Length > 0) { argLine.Append(' '); }
                    argLine.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
                }
                psi.Arguments = argLine.ToString();
                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "本工具需要管理员权限才能读写 EFI 系统分区，但提权被取消或失败了。\n\n" +
                    ex.Message + "\n\n" +
                    "可以右键 BootAnimGUI.exe 选择「以管理员身份运行」。",
                    "BootAnim 管理工具", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 2;
            }
        }

        try
        {
            Directory.CreateDirectory(tempDir);

            string espTools = Path.Combine(tempDir, "EspTools.ps1");
            string packer = Path.Combine(tempDir, "BootAnimPacker.ps1");
            string cfg = Path.Combine(tempDir, "bootanim.cfg");
            string driver = Path.Combine(tempDir, "BootAnimGUI.ps1");

            WriteResource("EspTools.ps1", espTools);
            WriteResource("BootAnimPacker.ps1", packer);
            WriteResource("bootanim.cfg", cfg);

            string src = ReadResourceText("BootAnimGUI.ps1");
            string patched = PatchScript(src, tempDir, projRoot);
            File.WriteAllText(driver, patched, new UTF8Encoding(true));

            int rc = RunDriver(driver, projRoot);
            SafeDeleteDir(tempDir);
            return rc;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动失败：\n\n" + ex.Message + "\n\n" + ex.GetType().FullName,
                "BootAnim 管理工具", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // -----------------------------------------------------------------
    //  路径
    // -----------------------------------------------------------------
    private static string FindProjectRoot(string startDir)
    {
        string dir = startDir;
        for (int i = 0; i < 4 && !string.IsNullOrEmpty(dir); i++)
        {
            if (Directory.Exists(Path.Combine(dir, "dist")) ||
                Directory.Exists(Path.Combine(dir, "install")))
            {
                return dir;
            }
            dir = Path.GetDirectoryName(dir);
        }
        return startDir;
    }

    private static bool IsAdministrator()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            {
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }
        catch
        {
            return false;
        }
    }

    // -----------------------------------------------------------------
    //  资源
    // -----------------------------------------------------------------
    private static Stream OpenResource(string name)
    {
        // 用 GetExecutingAssembly 而不是 GetEntryAssembly：
        // 前者返回"包含当前正在执行代码的程序集"，无论 exe 是直接运行还是被
        // 别的宿主（例如 PowerShell 反射调用自检）加载进来都成立。
        Assembly asm = Assembly.GetExecutingAssembly();
        Stream s = asm.GetManifestResourceStream(name);
        if (s == null)
        {
            // 兜底：按后缀匹配一次
            foreach (string rn in asm.GetManifestResourceNames())
            {
                if (rn.EndsWith(name, StringComparison.OrdinalIgnoreCase))
                {
                    s = asm.GetManifestResourceStream(rn);
                    break;
                }
            }
        }
        if (s == null)
        {
            throw new InvalidOperationException("内嵌资源缺失: " + name);
        }
        return s;
    }

    private static string ReadResourceText(string name)
    {
        using (Stream s = OpenResource(name))
        using (StreamReader r = new StreamReader(s, Encoding.UTF8, true))
        {
            return r.ReadToEnd();
        }
    }

    private static void WriteResource(string name, string path)
    {
        using (Stream s = OpenResource(name))
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                fs.Write(buf, 0, n);
            }
        }
    }

    // -----------------------------------------------------------------
    //  改写脚本
    // -----------------------------------------------------------------
    private static string PsQuote(string s)
    {
        return "'" + s.Replace("'", "''") + "'";
    }

    private static string PatchScript(string src, string tempDir, string projRoot)
    {
        // 1) $GuiDir = $PSScriptRoot   ->  解包目录（旁边就是两个 .ps1）
        src = Regex.Replace(src,
            @"\$GuiDir\s*=\s*\$PSScriptRoot",
            "$GuiDir     = " + PsQuote(tempDir));

        // 2) $ProjRoot = Split-Path -Parent $GuiDir  ->  真实项目根
        src = Regex.Replace(src,
            @"\$ProjRoot\s*=\s*Split-Path\s+-Parent\s+\$GuiDir",
            "$ProjRoot   = " + PsQuote(projRoot));

        // 3) $InstallDir = Join-Path $ProjRoot 'install'  ->  解包目录
        //    （这样 bootanim.cfg 模板也来自内嵌资源）
        src = Regex.Replace(src,
            @"\$InstallDir\s*=\s*Join-Path\s+\$ProjRoot\s+'install'",
            "$InstallDir = " + PsQuote(tempDir));

        // 4) 去掉自提权块：从 $identity = ... 一直到 EnableVisualStyles()
        //    提权已经由 exe 的清单（requireAdministrator）完成
        src = Regex.Replace(src,
            @"\$identity\s*=\s*\[Security\.Principal\.WindowsIdentity\]::GetCurrent\(\).*?\[System\.Windows\.Forms\.Application\]::EnableVisualStyles\(\)",
            "[System.Windows.Forms.Application]::EnableVisualStyles()",
            RegexOptions.Singleline);

        if (src.IndexOf("$GuiDir     = " + PsQuote(tempDir), StringComparison.Ordinal) < 0)
        {
            throw new InvalidOperationException(
                "脚本改写失败：没找到 $GuiDir = $PSScriptRoot。" +
                "（BootAnimGUI.ps1 是否被改过？）");
        }
        return src;
    }

    // -----------------------------------------------------------------
    //  运行
    // -----------------------------------------------------------------
    private static string PowerShellPath()
    {
        string p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                @"WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(p))
        {
            return p;
        }
        return "powershell.exe";
    }

    private static int RunDriver(string driver, string workDir)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = PowerShellPath();
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + driver + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = workDir;

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    private static void SafeDeleteDir(string dir)
    {
        try
        {
            if (Directory.Exists(dir))
            {
                Directory.Delete(dir, true);
            }
        }
        catch
        {
            // 文件被占用就留给系统清理，不影响使用
        }
    }

    // -----------------------------------------------------------------
    //  自检（用于验证 exe 打包是否正常，不启动界面）
    // -----------------------------------------------------------------
    private static int SelfCheck(string exeDir, string projRoot, string tempDir)
    {
        StringBuilder sb = new StringBuilder();
        int problems = 0;
        string reportPath = Path.Combine(Path.GetTempPath(), "BootAnimGUI_selfcheck.txt");

        // 每写一行就落一次盘：万一后面某步炸了，也能看到卡在哪里
        Action<string> say = delegate(string line)
        {
            sb.AppendLine(line);
            try { File.WriteAllText(reportPath, sb.ToString(), new UTF8Encoding(true)); }
            catch { }
        };

        say("BootAnimGUI.exe 自检");
        say("  版本        : " + Version);
        say("  exe 目录    : " + exeDir);
        say("  项目根      : " + projRoot);
        say("  临时目录    : " + tempDir);
        say("  powershell  : " + PowerShellPath());
        if (!File.Exists(PowerShellPath())) { problems++; say("  [X] 找不到 powershell.exe"); }
        say("");
        say("  当前进程    : " + SafeProcessName());

        // 必须用 GetExecutingAssembly：
        // 这个自检也可能被别的宿主（PowerShell 反射）调用，
        // 那时 GetEntryAssembly 返回的是宿主自己的程序集，资源就找错人了。
        Assembly asm = Assembly.GetExecutingAssembly();
        say("  程序集      : " + asm.GetName().Name + " " + asm.GetName().Version);
        say("  内嵌资源:");
        try
        {
            foreach (string rn in asm.GetManifestResourceNames())
            {
                long len = -1;
                using (Stream s = asm.GetManifestResourceStream(rn))
                {
                    if (s != null) { len = s.Length; }
                }
                say("    " + rn + "  (" + len + " 字节)");
            }
        }
        catch (Exception ex)
        {
            problems++;
            say("  [X] 枚举资源失败: " + ex.GetType().Name + ": " + ex.Message);
        }
        say("");

        try
        {
            Directory.CreateDirectory(tempDir);
            WriteResource("EspTools.ps1", Path.Combine(tempDir, "EspTools.ps1"));
            WriteResource("BootAnimPacker.ps1", Path.Combine(tempDir, "BootAnimPacker.ps1"));
            WriteResource("bootanim.cfg", Path.Combine(tempDir, "bootanim.cfg"));
            string src = ReadResourceText("BootAnimGUI.ps1");
            string patched = PatchScript(src, tempDir, projRoot);
            string driver = Path.Combine(tempDir, "BootAnimGUI.ps1");
            File.WriteAllText(driver, patched, new UTF8Encoding(true));
            say("  [OK] 4 个资源已解包，脚本改写成功");
            say("       driver 长度 = " + patched.Length + " 字符");

            // 关键改写点是否生效
            string[] must = new string[]
            {
                "$GuiDir     = " + PsQuote(tempDir),
                "$ProjRoot   = " + PsQuote(projRoot),
                "$InstallDir = " + PsQuote(tempDir)
            };
            foreach (string m in must)
            {
                if (patched.IndexOf(m, StringComparison.Ordinal) >= 0)
                {
                    say("  [OK] 已写入: " + m);
                }
                else
                {
                    problems++;
                    say("  [X]  缺少  : " + m);
                }
            }
            if (patched.IndexOf("WindowsIdentity]::GetCurrent()", StringComparison.Ordinal) >= 0)
            {
                problems++;
                say("  [X] 自提权块没有被移除");
            }
            else
            {
                say("  [OK] 自提权块已移除");
            }

            // 用 PowerShell 的解析器检查改写后的脚本语法
            string syntaxScript = Path.Combine(tempDir, "_syntax.ps1");
            File.WriteAllText(syntaxScript,
                "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile(" +
                "'" + driver.Replace("'", "''") + "',[ref]$t,[ref]$e);" +
                "if($e -and $e.Count){$e|%{Write-Output ('SYNTAXERR ' + $_.Extent.StartLineNumber + ': ' + $_.Message)};exit 1}else{Write-Output 'SYNTAXOK';exit 0}",
                new UTF8Encoding(true));
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = PowerShellPath();
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + syntaxScript + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            using (Process p = Process.Start(psi))
            {
                string o = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                say("  语法检查: " + o.Trim());
                if (o.IndexOf("SYNTAXOK", StringComparison.Ordinal) < 0) { problems++; }
            }

            // 找 bootanim.efi
            string[] cands = new string[]
            {
                Path.Combine(projRoot, "dist", "bootanim.efi"),
                Path.Combine(exeDir, "dist", "bootanim.efi"),
                Path.Combine(exeDir, "bootanim.efi")
            };
            bool found = false;
            foreach (string c in cands)
            {
                if (File.Exists(c)) { say("  [OK] 找到 bootanim.efi: " + c); found = true; break; }
            }
            if (!found) { say("  [--] 没找到 dist\\bootanim.efi（不影响自检，只影响「安装接管」）"); }
        }
        catch (Exception ex)
        {
            problems++;
            say("  [X] 异常: " + ex.GetType().Name + ": " + ex.Message);
        }

        say("");
        say(problems == 0 ? "自检结果: OK" : ("自检结果: 有 " + problems + " 个问题"));

        // 直接写控制台；宿主没有控制台时忽略
        try { Console.WriteLine(sb.ToString()); } catch { }
        SafeDeleteDir(tempDir);
        return problems == 0 ? 0 : 1;
    }

    private static string SafeProcessName()
    {
        try { return Process.GetCurrentProcess().ProcessName; }
        catch { return "(未知)"; }
    }
}
