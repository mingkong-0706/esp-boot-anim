// =====================================================================
//  BootAnimSetup.cs -- BootAnim 安装程序（单文件 exe）
//
//  它是怎么工作的：
//    1. 整个"应用负载"（BootAnimGUI.exe、安装脚本、许可证、文档、
//       bootanim.efi、可选的 ffmpeg）都以**内嵌资源**的形式带在这个 exe 里，
//       配一份 payload.manifest 记录"资源名 -> 解包后的相对路径"
//    2. 运行时先把负载解到 %TEMP%\BootAnimSetup_<版本>\，保持和源码仓库
//       一样的目录结构（gui\ install\ dist\ ...）
//    3. 然后调用解出来的 install\Install-App.ps1 去真正安装
//       （这样安装逻辑只有一份，改脚本不用改这个 exe）
//    4. 子进程的输出用 UTF-8 解码后实时显示在窗口里
//
//  为什么不把安装逻辑用 C# 重写一遍：那样就有两份实现，迟早不一致。
//
//  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
// =====================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal static class BootAnimSetup
{
    private const string Version = "1.1.0";
    private const string AppName = "BootAnim";

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    private static Form form;
    private static TextBox txtLog;
    private static TextBox txtDir;
    private static CheckBox chkDesktop;
    private static CheckBox chkStartMenu;
    private static CheckBox chkFFmpeg;
    private static Button btnInstall;
    private static Button btnUninstall;
    private static Button btnBrowse;
    private static Button btnAdmin;
    private static Button btnClose;
    private static Label lblState;

    private static string payloadDir;
    private static bool hasFFmpeg;
    private static bool busy;

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();

        bool silent = false;
        string silentDir = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "--silent", StringComparison.OrdinalIgnoreCase)) { silent = true; }
            else if (string.Equals(args[i], "--dir", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) { silentDir = args[++i]; }
        }

        try
        {
            payloadDir = ExtractPayload();
        }
        catch (Exception ex)
        {
            MessageBox.Show("解包失败：\n\n" + ex.Message, AppName + " 安装程序",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        hasFFmpeg = File.Exists(Path.Combine(payloadDir, "ffmpeg-src", "ffmpeg.exe"));

        if (silent)
        {
            string dir = silentDir ?? DefaultInstallDir();
            return RunInstaller(dir, true, true, hasFFmpeg, false);
        }

        return RunGui();
    }

    private static string DefaultInstallDir()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                            @"Programs\BootAnim");
    }

    // -----------------------------------------------------------------
    //  界面
    // -----------------------------------------------------------------
    private static int RunGui()
    {
        form = new Form();
        form.Text = AppName + " 安装程序  v" + Version;
        form.ClientSize = new Size(620, 480);
        form.StartPosition = FormStartPosition.CenterScreen;
        form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.MaximizeBox = false;
        try { form.Font = new Font("Microsoft YaHei UI", 9f); }
        catch { try { form.Font = new Font("Microsoft YaHei", 9f); } catch { } }

        Label lblTitle = new Label();
        lblTitle.Text = "把 BootAnim 安装到这台电脑";
        lblTitle.Font = new Font(form.Font.FontFamily, 12f, FontStyle.Bold);
        lblTitle.Location = new Point(16, 14);
        lblTitle.Size = new Size(580, 26);
        form.Controls.Add(lblTitle);

        Label lblSub = new Label();
        lblSub.Text = "ESP 开机动画管理工具 —— Windows 无法设置开机动画的替代方案";
        lblSub.ForeColor = Color.DimGray;
        lblSub.Location = new Point(18, 42);
        lblSub.Size = new Size(580, 18);
        form.Controls.Add(lblSub);

        // ---- 安装位置 ----
        Label lblDir = new Label();
        lblDir.Text = "安装到：";
        lblDir.Location = new Point(18, 76);
        lblDir.Size = new Size(60, 20);
        form.Controls.Add(lblDir);

        txtDir = new TextBox();
        txtDir.Text = DefaultInstallDir();
        txtDir.Location = new Point(82, 73);
        txtDir.Size = new Size(400, 24);
        form.Controls.Add(txtDir);

        btnBrowse = new Button();
        btnBrowse.Text = "浏览…";
        btnBrowse.Location = new Point(490, 72);
        btnBrowse.Size = new Size(108, 26);
        btnBrowse.Click += delegate { Browse(); };
        form.Controls.Add(btnBrowse);

        Label lblHint = new Label();
        lblHint.Text = "默认装到当前用户目录，不需要管理员权限。装到 Program Files 才需要。";
        lblHint.ForeColor = Color.DimGray;
        lblHint.Location = new Point(82, 99);
        lblHint.Size = new Size(520, 18);
        form.Controls.Add(lblHint);

        // ---- 选项 ----
        GroupBox grp = new GroupBox();
        grp.Text = "选项";
        grp.Location = new Point(16, 124);
        grp.Size = new Size(588, 96);
        form.Controls.Add(grp);

        chkStartMenu = new CheckBox();
        chkStartMenu.Text = "创建开始菜单快捷方式（可以从开始菜单搜到）";
        chkStartMenu.Checked = true;
        chkStartMenu.Location = new Point(14, 24);
        chkStartMenu.Size = new Size(400, 22);
        grp.Controls.Add(chkStartMenu);

        chkDesktop = new CheckBox();
        chkDesktop.Text = "创建桌面快捷方式";
        chkDesktop.Checked = true;
        chkDesktop.Location = new Point(14, 48);
        chkDesktop.Size = new Size(400, 22);
        grp.Controls.Add(chkDesktop);

        chkFFmpeg = new CheckBox();
        chkFFmpeg.Location = new Point(14, 72);
        chkFFmpeg.Size = new Size(560, 22);
        if (hasFFmpeg)
        {
            chkFFmpeg.Text = "一起安装 ffmpeg（用于把 MP4 等视频拆成动画帧，约 100 MB）";
            chkFFmpeg.Checked = true;
            chkFFmpeg.Enabled = true;
        }
        else
        {
            chkFFmpeg.Text = "（本安装包没内置 ffmpeg；装好后把 ffmpeg.exe 放进安装目录即可）";
            chkFFmpeg.Checked = false;
            chkFFmpeg.Enabled = false;
        }
        grp.Controls.Add(chkFFmpeg);

        // ---- 按钮 ----
        btnInstall = new Button();
        btnInstall.Text = "开始安装";
        btnInstall.Location = new Point(16, 232);
        btnInstall.Size = new Size(140, 34);
        btnInstall.Font = new Font(form.Font, FontStyle.Bold);
        btnInstall.Click += delegate { DoInstall(); };
        form.Controls.Add(btnInstall);

        btnUninstall = new Button();
        btnUninstall.Text = "卸载";
        btnUninstall.Location = new Point(166, 232);
        btnUninstall.Size = new Size(100, 34);
        btnUninstall.Click += delegate { DoUninstall(); };
        form.Controls.Add(btnUninstall);

        btnAdmin = new Button();
        btnAdmin.Text = "以管理员身份重启";
        btnAdmin.Location = new Point(276, 232);
        btnAdmin.Size = new Size(150, 34);
        btnAdmin.Click += delegate { RelaunchElevated(); };
        form.Controls.Add(btnAdmin);

        btnClose = new Button();
        btnClose.Text = "关闭";
        btnClose.Location = new Point(504, 232);
        btnClose.Size = new Size(100, 34);
        btnClose.Click += delegate { form.Close(); };
        form.Controls.Add(btnClose);

        // ---- 日志 ----
        Label lblLog = new Label();
        lblLog.Text = "过程记录";
        lblLog.Location = new Point(18, 276);
        lblLog.Size = new Size(200, 18);
        form.Controls.Add(lblLog);

        txtLog = new TextBox();
        txtLog.Multiline = true;
        txtLog.ReadOnly = true;
        txtLog.ScrollBars = ScrollBars.Both;
        txtLog.WordWrap = false;
        txtLog.BackColor = Color.FromArgb(250, 250, 250);
        txtLog.Location = new Point(16, 296);
        txtLog.Size = new Size(588, 140);
        txtLog.Font = new Font("Consolas", 8.5f);
        form.Controls.Add(txtLog);

        lblState = new Label();
        lblState.Text = "准备就绪";
        lblState.Location = new Point(18, 444);
        lblState.Size = new Size(580, 20);
        lblState.ForeColor = Color.SteelBlue;
        form.Controls.Add(lblState);

        Log("安装包已解包到：" + payloadDir);
        Log("内置 ffmpeg：" + (hasFFmpeg ? "有" : "没有"));
        Log("");
        Log("点「开始安装」继续。程序运行时会自己弹 UAC（要读写 EFI 系统分区）。");

        Application.Run(form);
        return 0;
    }

    private static void Log(string line)
    {
        if (txtLog == null) return;
        txtLog.AppendText(line + "\r\n");
        txtLog.SelectionStart = txtLog.TextLength;
        txtLog.ScrollToCaret();
        Application.DoEvents();
    }

    private static void SetBusy(bool b)
    {
        busy = b;
        btnInstall.Enabled = !b;
        btnUninstall.Enabled = !b;
        btnBrowse.Enabled = !b;
        btnAdmin.Enabled = !b;
        // 注意：不能写 Cursor = ... —— System.Windows.Forms.Cursor 是类型名，
        // 在静态类里会被解析成类型而不是窗体的属性
        if (form != null) { form.Cursor = b ? Cursors.WaitCursor : Cursors.Default; }
    }

    private static void Browse()
    {
        FolderBrowserDialog d = new FolderBrowserDialog();
        d.Description = "选择安装位置";
        if (d.ShowDialog() == DialogResult.OK)
        {
            // 让用户选的是"父目录"，安装进 BootAnim 子目录
            string p = d.SelectedPath;
            if (!string.Equals(Path.GetFileName(p), AppName, StringComparison.OrdinalIgnoreCase))
            {
                p = Path.Combine(p, AppName);
            }
            txtDir.Text = p;
        }
    }

    private static void DoInstall()
    {
        string dir = txtDir.Text.Trim();
        if (dir.Length == 0) { MessageBox.Show("请先填安装位置。", AppName); return; }
        try { dir = Path.GetFullPath(dir); } catch { MessageBox.Show("安装位置不是合法路径。", AppName); return; }

        SetBusy(true);
        lblState.Text = "正在安装…";
        Log("");
        Log("=====================================================");
        Log("开始安装到 " + dir);
        Log("=====================================================");

        int rc = RunInstaller(dir, chkStartMenu.Checked, chkDesktop.Checked, chkFFmpeg.Checked, true);
        SetBusy(false);

        if (rc == 0)
        {
            lblState.Text = "安装完成";
            lblState.ForeColor = Color.Green;
            DialogResult r = MessageBox.Show(
                "安装完成。\n\n安装位置：\n" + dir + "\n\n要现在打开吗？",
                AppName + " 安装程序", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r == DialogResult.Yes)
            {
                string exe = Path.Combine(dir, "BootAnimGUI.exe");
                if (File.Exists(exe))
                {
                    try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, WorkingDirectory = dir }); }
                    catch (Exception ex) { MessageBox.Show("打不开：" + ex.Message, AppName); }
                }
            }
        }
        else if (rc == 4)
        {
            lblState.Text = "需要管理员权限";
            lblState.ForeColor = Color.OrangeRed;
            DialogResult r = MessageBox.Show(
                "装到 Program Files 需要管理员权限。\n\n要以管理员身份重新启动安装程序吗？",
                AppName + " 安装程序", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r == DialogResult.Yes) { RelaunchElevated(); }
        }
        else
        {
            lblState.Text = "安装失败（退出码 " + rc + "）";
            lblState.ForeColor = Color.Red;
            MessageBox.Show("安装没有完成，退出码 " + rc + "。\n详细原因看窗口里的过程记录。",
                            AppName + " 安装程序", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void DoUninstall()
    {
        DialogResult r = MessageBox.Show(
            "要卸载 BootAnim 管理工具吗？\n\n" +
            "注意：这只卸载工具本身，不会动你 ESP 上的开机动画。\n" +
            "想取消引导接管，请在程序界面里点「卸载（还原原版引导）」。",
            AppName + " 卸载", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (r != DialogResult.Yes) return;

        SetBusy(true);
        lblState.Text = "正在卸载…";
        Log("");
        Log("=====================================================");
        Log("开始卸载");
        Log("=====================================================");

        string script = Path.Combine(payloadDir, "install", "Uninstall-App.ps1");
        int rc = RunPowerShellScript(script, "-InstallDir " + PsQuote(txtDir.Text.Trim()));
        SetBusy(false);

        lblState.Text = (rc == 0) ? "卸载完成" : ("卸载失败（退出码 " + rc + "）");
        lblState.ForeColor = (rc == 0) ? Color.Green : Color.Red;
    }

    private static void RelaunchElevated()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName);
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            psi.Arguments = "--dir " + PsQuote(txtDir.Text.Trim());
            Process.Start(psi);
            if (form != null) form.Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show("提权被取消或失败：\n\n" + ex.Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private static int RunInstaller(string dir, bool startMenu, bool desktop, bool withFFmpeg, bool log)
    {
        StringBuilder a = new StringBuilder();
        a.Append("-InstallDir ").Append(PsQuote(dir));
        if (!startMenu) { a.Append(" -NoStartMenu"); }
        if (!desktop) { a.Append(" -NoDesktopShortcut"); }
        if (withFFmpeg) { a.Append(" -WithFFmpeg"); }
        return RunPowerShellScript(Path.Combine(payloadDir, "install", "Install-App.ps1"), a.ToString());
    }

    // -----------------------------------------------------------------
    //  跑 PowerShell 脚本并把输出实时打进日志
    // -----------------------------------------------------------------
    private static string PsQuote(string s)
    {
        return "'" + s.Replace("'", "''") + "'";
    }

    private static int RunPowerShellScript(string script, string scriptArgs)
    {
        if (!File.Exists(script))
        {
            Log("[错误] 找不到脚本：" + script);
            return 1;
        }

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                 @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) { ps = "powershell.exe"; }

        // 用 -Command 而不是 -File：这样可以在调用脚本之前先把输出编码设成
        // UTF-8，中文才不会在重定向里变成乱码。
        string cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " +
                     "$ErrorActionPreference='Continue'; " +
                     "& " + PsQuote(script) + " " + scriptArgs + "; exit $LASTEXITCODE";

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = ps;
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + cmd.Replace("\"", "\\\"") + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        psi.WorkingDirectory = payloadDir;

        try
        {
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) Log(e.Data); };
                p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) Log(e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Log("[错误] 启动 PowerShell 失败：" + ex.Message);
            return 1;
        }
    }

    // -----------------------------------------------------------------
    //  解包
    // -----------------------------------------------------------------
    private static string ExtractPayload()
    {
        string dir = Path.Combine(Path.GetTempPath(), "BootAnimSetup_" + Version);
        Assembly asm = Assembly.GetExecutingAssembly();

        string manifest = null;
        using (Stream s = asm.GetManifestResourceStream("payload.manifest"))
        {
            if (s == null) throw new InvalidOperationException("安装包里没有 payload.manifest（打包时出错了）");
            using (StreamReader r = new StreamReader(s, Encoding.UTF8, true)) { manifest = r.ReadToEnd(); }
        }

        int n = 0;
        foreach (string rawLine in manifest.Split('\n'))
        {
            string line = rawLine.Trim().TrimEnd('\r');
            if (line.Length == 0 || line.StartsWith("#")) continue;
            int bar = line.IndexOf('|');
            if (bar <= 0) continue;
            string resName = line.Substring(0, bar);
            string rel = line.Substring(bar + 1).Replace('/', Path.DirectorySeparatorChar);

            string target = Path.Combine(dir, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(target));

            using (Stream s = asm.GetManifestResourceStream(resName))
            {
                if (s == null) throw new InvalidOperationException("内嵌资源缺失: " + resName);
                using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write))
                {
                    byte[] buf = new byte[128 * 1024];
                    int got;
                    while ((got = s.Read(buf, 0, buf.Length)) > 0) { fs.Write(buf, 0, got); }
                }
            }
            n++;
        }
        return dir;
    }
}
