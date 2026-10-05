# =====================================================================
#  BootAnimPacker.ps1 -- 图像打包内核（运行期用 Add-Type 编译的 C#）
#
#  被 BootAnimGUI.ps1 点源加载，提供：
#     [BootAnimGui.Packer]::Pack(...)       图片序列 -> .baa
#     [BootAnimGui.Packer]::GetInfo(path)   读取 .baa 头
#     [BootAnimGui.Demo]::Generate(...)     程序化生成一段转圈动画
#
#  为什么用 C# 而不是纯 PowerShell：
#     1920x1080 一帧有 200 万像素，60 帧就是 1.2 亿次像素操作。
#     PowerShell 的循环做这个要几十分钟，而 Add-Type 会用 Windows 自带的
#     C# 编译器（csc.exe，.NET Framework 的一部分）在内存里编出一份原生代码，
#     整个过程只要一两秒。不需要安装任何 SDK。
#
#  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
# =====================================================================

$script:BootAnimPackerSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace BootAnimGui
{
    public static class Packer
    {
        public const int HeaderSize = 64;

        // 复用的编码缓冲（单线程调用，不做并发保护）
        static byte[] sBuf = new byte[1 << 20];
        static int sLen;

        static void Ensure(int extra)
        {
            if (sLen + extra <= sBuf.Length) return;
            int n = sBuf.Length;
            while (n < sLen + extra) n *= 2;
            Array.Resize(ref sBuf, n);
        }

        static void PByte(byte b) { Ensure(1); sBuf[sLen++] = b; }

        static void PPix(uint v)
        {
            Ensure(4);
            sBuf[sLen++] = (byte)(v & 0xFF);
            sBuf[sLen++] = (byte)((v >> 8) & 0xFF);
            sBuf[sLen++] = (byte)((v >> 16) & 0xFF);
            sBuf[sLen++] = (byte)((v >> 24) & 0xFF);
        }

        static void WriteU32(byte[] a, int off, uint v)
        {
            a[off] = (byte)(v & 0xFF);
            a[off + 1] = (byte)((v >> 8) & 0xFF);
            a[off + 2] = (byte)((v >> 16) & 0xFF);
            a[off + 3] = (byte)((v >> 24) & 0xFF);
        }

        public static uint ReadU32(byte[] a, int off)
        {
            return (uint)(a[off] | (a[off + 1] << 8) | (a[off + 2] << 16) | (a[off + 3] << 24));
        }

        // 从 i 开始有多少个连续相同像素（上限 129，与 Python 参考实现一致）
        static int RunLen(uint[] px, int i, int n)
        {
            uint c = px[i];
            int r = 1;
            while (i + r < n && r < 129 && px[i + r] == c) r++;
            return r;
        }

        // RLE 编码，写进 sBuf；与 tools/baanim.py 的 rle_encode 逐字节等价
        static void EncFrame(uint[] px, int n)
        {
            int i = 0;
            while (i < n)
            {
                int run = RunLen(px, i, n);
                if (run >= 3)
                {
                    PByte((byte)(0x80 + (run - 2)));
                    PPix(px[i]);
                    i += run;
                    continue;
                }
                int start = i;
                while (i < n && (i - start) < 128)
                {
                    if (RunLen(px, i, n) >= 3) break;
                    i++;
                }
                if (i == start) i++;
                int cnt = i - start;
                PByte((byte)(cnt - 1));
                for (int k = start; k < i; k++) PPix(px[k]);
            }
        }

        // 按 fit 模式把一张图缩放进 w x h 的画布
        static Bitmap Prepare(string file, int w, int h, string fit, Color bg)
        {
            using (Image src = Image.FromFile(file))
            {
                Bitmap dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                using (Graphics g = Graphics.FromImage(dst))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.Clear(bg);

                    Rectangle r;
                    if (src.Width == w && src.Height == h)
                    {
                        // 尺寸已经一致：直通复制，绝不让重采样引入任何偏差
                        g.InterpolationMode = InterpolationMode.NearestNeighbor;
                        g.PixelOffsetMode = PixelOffsetMode.Half;
                        r = new Rectangle(0, 0, w, h);
                    }
                    else if (fit == "stretch")
                    {
                        r = new Rectangle(0, 0, w, h);
                    }
                    else if (fit == "none")
                    {
                        throw new Exception("图片尺寸是 " + src.Width + "x" + src.Height +
                                            "，与设定的 " + w + "x" + h + " 不一致：" +
                                            Path.GetFileName(file));
                    }
                    else
                    {
                        double sw = (double)w / src.Width;
                        double sh = (double)h / src.Height;
                        double s = (fit == "cover") ? Math.Max(sw, sh) : Math.Min(sw, sh);
                        int dw = Math.Max(1, (int)Math.Round(src.Width * s));
                        int dh = Math.Max(1, (int)Math.Round(src.Height * s));
                        r = new Rectangle((w - dw) / 2, (h - dh) / 2, dw, dh);
                    }
                    // 目标矩形超出画布的部分会被自动裁剪，cover 正好靠这个实现
                    g.DrawImage(src, r);
                }
                return dst;
            }
        }

        static uint[] ToPixels(Bitmap bmp)
        {
            int w = bmp.Width, h = bmp.Height;
            uint[] px = new uint[w * h];
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h),
                                        ImageLockMode.ReadOnly,
                                        PixelFormat.Format32bppArgb);
            try
            {
                int stride = d.Stride;
                int abs = stride < 0 ? -stride : stride;
                byte[] row = new byte[abs];
                for (int y = 0; y < h; y++)
                {
                    IntPtr p = stride < 0 ? IntPtr.Add(d.Scan0, (h - 1 - y) * abs)
                                          : IntPtr.Add(d.Scan0, y * abs);
                    Marshal.Copy(p, row, 0, abs);
                    Buffer.BlockCopy(row, 0, px, y * w * 4, w * 4);
                }
            }
            finally
            {
                bmp.UnlockBits(d);
            }
            return px;
        }

        // files: 图片路径数组；fit: contain|cover|stretch|none；rle: 是否压缩
        public static string Pack(string[] files, int w, int h, int fps, string fit,
                                  int bgR, int bgG, int bgB, bool rle, string outPath,
                                  Action<int, string> progress)
        {
            if (files == null || files.Length == 0) throw new Exception("没有选择任何图片");
            if (w <= 0 || h <= 0 || (long)w * h > 8192L * 8192L)
                throw new Exception("分辨率不合法：" + w + "x" + h);
            if (fps <= 0 || fps > 1000) throw new Exception("帧率不合法：" + fps);
            if (files.Length > 100000) throw new Exception("帧数太多");

            Color bg = Color.FromArgb(255, bgR, bgG, bgB);
            long[] offs = new long[files.Length];
            int[] sizes = new int[files.Length];

            using (FileStream fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
            {
                byte[] hdr = new byte[HeaderSize];
                byte[] magic = System.Text.Encoding.ASCII.GetBytes("BAANIM01");
                Array.Copy(magic, hdr, 8);
                WriteU32(hdr, 8, HeaderSize);
                WriteU32(hdr, 12, (uint)files.Length);
                WriteU32(hdr, 16, (uint)w);
                WriteU32(hdr, 20, (uint)h);
                WriteU32(hdr, 24, (uint)fps);
                WriteU32(hdr, 28, rle ? 1u : 0u);
                fs.Write(hdr, 0, HeaderSize);

                byte[] reserve = new byte[files.Length * 8];
                fs.Write(reserve, 0, reserve.Length);

                for (int i = 0; i < files.Length; i++)
                {
                    using (Bitmap bmp = Prepare(files[i], w, h, fit, bg))
                    {
                        uint[] px = ToPixels(bmp);
                        sLen = 0;
                        if (rle)
                        {
                            EncFrame(px, px.Length);
                        }
                        else
                        {
                            Ensure(px.Length * 4);
                            for (int k = 0; k < px.Length; k++) PPix(px[k]);
                        }
                    }
                    offs[i] = fs.Position;
                    sizes[i] = sLen;
                    fs.Write(sBuf, 0, sLen);
                    int pad = (4 - (sLen & 3)) & 3;
                    for (int p = 0; p < pad; p++) fs.WriteByte(0);
                    if (progress != null)
                        progress((i + 1) * 100 / files.Length, Path.GetFileName(files[i]));
                }

                fs.Seek(HeaderSize, SeekOrigin.Begin);
                byte[] idx = new byte[files.Length * 8];
                for (int i = 0; i < files.Length; i++)
                {
                    WriteU32(idx, i * 8, (uint)offs[i]);
                    WriteU32(idx, i * 8 + 4, (uint)sizes[i]);
                }
                fs.Write(idx, 0, idx.Length);
            }
            return outPath;
        }

        // 返回 { 帧数, 宽, 高, fps, 是否RLE }；失败返回 null
        public static uint[] GetInfo(string path)
        {
            try
            {
                byte[] head = new byte[HeaderSize];
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read))
                {
                    if (fs.Length < HeaderSize) return null;
                    int got = 0;
                    while (got < HeaderSize)
                    {
                        int n = fs.Read(head, got, HeaderSize - got);
                        if (n <= 0) return null;
                        got += n;
                    }
                }
                if (System.Text.Encoding.ASCII.GetString(head, 0, 8) != "BAANIM01") return null;
                uint hs = ReadU32(head, 8);
                uint fc = ReadU32(head, 12);
                uint w = ReadU32(head, 16);
                uint h = ReadU32(head, 20);
                uint fps = ReadU32(head, 24);
                uint fl = ReadU32(head, 28);
                if (hs < 64 || fc == 0) return null;
                return new uint[] { fc, w, h, fps, (fl & 1u) };
            }
            catch
            {
                return null;
            }
        }

        // 探测一个文件里有多少帧、每帧停留多久（毫秒）。
        // 返回 { 帧数, 平均帧间隔ms }。静态图片返回 { 1, 0 }。
        //
        // 这一步是必需的：GDI+ 的 Image.FromFile 对多帧 GIF/TIFF 只会给出
        // 第一帧。如果不先探测就直接丢给 Pack()，用户选一个 300 帧的 GIF
        // 会静默地只放进去 1 帧。
        public static uint[] Probe(string path)
        {
            try
            {
                using (Image img = Image.FromFile(path))
                {
                    int n = 1;
                    try { n = img.GetFrameCount(FrameDimension.Time); }
                    catch { n = 1; }
                    if (n < 1) n = 1;

                    uint avg = 0;
                    if (n > 1)
                    {
                        try
                        {
                            PropertyItem pi = img.GetPropertyItem(0x5100); // FrameDelay
                            if (pi != null && pi.Value != null && pi.Value.Length >= n * 4)
                            {
                                // GIF 里延迟为 0 表示"用默认值"，这种帧不参与平均
                                long sum = 0;
                                int cnt = 0;
                                for (int i = 0; i < n; i++)
                                {
                                    int d = BitConverter.ToInt32(pi.Value, i * 4);
                                    if (d > 0) { sum += d; cnt++; }
                                }
                                if (cnt > 0)
                                {
                                    avg = (uint)(sum / cnt);
                                    // 单位消歧：GIF 文件里延迟原生存的是 1/100 秒，
                                    // 不同版本的 GDI+ 有的转成毫秒、有的原样返回。
                                    // 判据：换算后若超过 100fps（现实里不存在），
                                    // 那单位一定是 1/100 秒，乘 10 换成毫秒。
                                    if (avg < 10) { avg *= 10; }
                                }
                            }
                        }
                        catch { }
                        if (avg == 0) avg = 100;            // 探测不到就按 10fps 猜
                    }
                    return new uint[] { (uint)n, avg };
                }
            }
            catch
            {
                return null;
            }
        }

        // 把一个多帧 GIF/TIFF 拆成一张张 PNG，返回 PNG 路径数组。
        // 单帧文件原样返回它自己（不产生副本）。
        //
        // 注意：GIF 的每一帧可能只记录"变化的那一小块"，靠 GDI+ 的顺序播放
        // 状态来自动叠加。所以必须**从第 0 帧开始顺序** SelectActiveFrame，
        // 不能跳着取。
        public static string[] ExtractFrames(string path, string outDir, Action<int, string> progress)
        {
            int frames;
            using (Image probe = Image.FromFile(path))
            {
                try { frames = probe.GetFrameCount(FrameDimension.Time); }
                catch { frames = 1; }
            }
            if (frames <= 1)
            {
                return new string[] { path };
            }

            Directory.CreateDirectory(outDir);
            string baseName = Path.GetFileNameWithoutExtension(path);
            string[] outp = new string[frames];

            // 每次都重新 FromFile：确保从第 0 帧的干净状态开始顺序叠加
            using (Image img = Image.FromFile(path))
            {
                int w = img.Width, h = img.Height;
                for (int i = 0; i < frames; i++)
                {
                    img.SelectActiveFrame(FrameDimension.Time, i);
                    using (Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb))
                    {
                        using (Graphics g = Graphics.FromImage(b))
                        {
                            g.CompositingMode = CompositingMode.SourceCopy;
                            g.Clear(Color.Transparent);
                            g.DrawImage(img, new Rectangle(0, 0, w, h));
                        }
                        string p = Path.Combine(outDir, baseName + "_" + i.ToString("D5") + ".png");
                        b.Save(p, ImageFormat.Png);
                        outp[i] = p;
                    }
                    if (progress != null && (i % 8 == 0 || i == frames - 1))
                    {
                        progress((i + 1) * 100 / frames, "拆帧 " + (i + 1) + "/" + frames);
                    }
                }
            }
            return outp;
        }
    }

    // ------------------------------------------------------------------
    //  程序化生成一段"转圈"演示动画（等价于 C 端的内置兜底动画）
    // ------------------------------------------------------------------
    public static class Demo
    {
        static uint Blend(uint dst, uint src, int alpha)
        {
            if (alpha <= 0) return dst;
            if (alpha > 256) alpha = 256;
            int ia = 256 - alpha;
            uint b = (((src & 0xFF) * (uint)alpha + (dst & 0xFF) * (uint)ia) >> 8) & 0xFF;
            uint g = ((((src >> 8) & 0xFF) * (uint)alpha + ((dst >> 8) & 0xFF) * (uint)ia) >> 8) & 0xFF;
            uint r = ((((src >> 16) & 0xFF) * (uint)alpha + ((dst >> 16) & 0xFF) * (uint)ia) >> 8) & 0xFF;
            return b | (g << 8) | (r << 16) | 0xFF000000u;
        }

        static void FillCircle(uint[] px, int W, int H, double cx, double cy,
                               double rad, uint color, int alpha)
        {
            int x0 = (int)Math.Floor(cx - rad - 1), x1 = (int)Math.Ceiling(cx + rad + 1);
            int y0 = (int)Math.Floor(cy - rad - 1), y1 = (int)Math.Ceiling(cy + rad + 1);
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
            if (x1 > W - 1) x1 = W - 1; if (y1 > H - 1) y1 = H - 1;

            for (int y = y0; y <= y1; y++)
            {
                double dy = y - cy;
                int rowBase = y * W;
                for (int x = x0; x <= x1; x++)
                {
                    double dx = x - cx;
                    double d2 = dx * dx + dy * dy;
                    if (d2 > (rad + 0.5) * (rad + 0.5)) continue;
                    double dist = Math.Sqrt(d2);
                    double cov = rad + 0.5 - dist;
                    if (cov <= 0) continue;
                    if (cov > 1) cov = 1;
                    int a = (int)(alpha * cov);
                    px[rowBase + x] = Blend(px[rowBase + x], color, a);
                }
            }
        }

        public static string Generate(int w, int h, int frames, int fps, string outPath,
                                      Action<int, string> progress)
        {
            if (w <= 0 || h <= 0) throw new Exception("分辨率不合法");
            if (frames < 1 || frames > 100000) throw new Exception("帧数不合法");
            if (fps <= 0 || fps > 1000) throw new Exception("帧率不合法");

            uint bg = 0xFF000000u;             // 黑（BGRX 打包）
            uint dot = 0x000078D4u;            // #0078D4
            double cx = w / 2.0, cy = h / 2.0;
            double ring = Math.Max(8.0, h / 16.0);
            double baseR = Math.Max(2.5, h / 90.0);
            double period = frames * 32.0;

            long[] offs = new long[frames];
            int[] sizes = new int[frames];
            byte[] enc = null;
            int encLen = 0;

            using (FileStream fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
            {
                byte[] hdr = new byte[64];
                Array.Copy(System.Text.Encoding.ASCII.GetBytes("BAANIM01"), hdr, 8);
                WriteU32Local(hdr, 8, 64);
                WriteU32Local(hdr, 12, (uint)frames);
                WriteU32Local(hdr, 16, (uint)w);
                WriteU32Local(hdr, 20, (uint)h);
                WriteU32Local(hdr, 24, (uint)fps);
                WriteU32Local(hdr, 28, 1);      // RLE
                fs.Write(hdr, 0, 64);
                fs.Write(new byte[frames * 8], 0, frames * 8);

                uint[] px = new uint[w * h];
                for (int f = 0; f < frames; f++)
                {
                    for (int i = 0; i < px.Length; i++) px[i] = bg;

                    for (int k = 0; k < 5; k++)
                    {
                        double ph = (f * 32.0 + (period / 5.0) * (4 - k)) % period;
                        double s = Math.Sin(2.0 * Math.PI * ph / period);
                        double rad = baseR + (s + 1.0) * baseR / 2.0;
                        if (rad < 2.0) rad = 2.0;
                        int alpha = (int)(160 + (s + 1.0) * 96.0 / 2.0);
                        double ang = 2.0 * Math.PI * k / 5.0;
                        double dx = Math.Cos(ang) * ring;
                        double dy = Math.Sin(ang) * ring;
                        FillCircle(px, w, h, cx + dx, cy + dy, rad, dot, alpha);
                    }

                    enc = RleEncode(px, enc, ref encLen);
                    offs[f] = fs.Position;
                    sizes[f] = encLen;
                    fs.Write(enc, 0, encLen);
                    int pad = (4 - (encLen & 3)) & 3;
                    for (int p = 0; p < pad; p++) fs.WriteByte(0);
                    if (progress != null)
                        progress((f + 1) * 100 / frames, "第 " + (f + 1) + " 帧");
                }

                fs.Seek(64, SeekOrigin.Begin);
                byte[] idx = new byte[frames * 8];
                for (int i = 0; i < frames; i++)
                {
                    WriteU32Local(idx, i * 8, (uint)offs[i]);
                    WriteU32Local(idx, i * 8 + 4, (uint)sizes[i]);
                }
                fs.Write(idx, 0, idx.Length);
            }
            return outPath;
        }

        static void WriteU32Local(byte[] a, int off, uint v)
        {
            a[off] = (byte)(v & 0xFF);
            a[off + 1] = (byte)((v >> 8) & 0xFF);
            a[off + 2] = (byte)((v >> 16) & 0xFF);
            a[off + 3] = (byte)((v >> 24) & 0xFF);
        }

        static byte[] RleEncode(uint[] px, byte[] buf, ref int len)
        {
            int n = px.Length;
            if (buf == null) buf = new byte[1 << 20];
            len = 0;

            int i = 0;
            while (i < n)
            {
                int run = 1;
                uint c = px[i];
                while (i + run < n && run < 129 && px[i + run] == c) run++;

                if (run >= 3)
                {
                    if (len + 5 > buf.Length) Array.Resize(ref buf, buf.Length * 2);
                    buf[len++] = (byte)(0x80 + (run - 2));
                    buf[len++] = (byte)(c & 0xFF);
                    buf[len++] = (byte)((c >> 8) & 0xFF);
                    buf[len++] = (byte)((c >> 16) & 0xFF);
                    buf[len++] = (byte)((c >> 24) & 0xFF);
                    i += run;
                    continue;
                }

                int start = i;
                while (i < n && (i - start) < 128)
                {
                    int r2 = 1;
                    uint c2 = px[i];
                    while (i + r2 < n && r2 < 129 && px[i + r2] == c2) r2++;
                    if (r2 >= 3) break;
                    i++;
                }
                if (i == start) i++;
                int cnt = i - start;
                while (len + 1 + cnt * 4 > buf.Length) Array.Resize(ref buf, buf.Length * 2);
                buf[len++] = (byte)(cnt - 1);
                for (int k = start; k < i; k++)
                {
                    uint v = px[k];
                    buf[len++] = (byte)(v & 0xFF);
                    buf[len++] = (byte)((v >> 8) & 0xFF);
                    buf[len++] = (byte)((v >> 16) & 0xFF);
                    buf[len++] = (byte)((v >> 24) & 0xFF);
                }
            }
            return buf;
        }
    }
}
'@

function Initialize-BootAnimPacker {
    <#
      编译上面的 C#（只在第一次调用时真正编译，之后直接复用）。
      编译失败会把完整错误抛出来，方便定位。
    #>
    if ($script:BootAnimPackerReady) { return }
    try {
        Add-Type -TypeDefinition $script:BootAnimPackerSource `
                 -ReferencedAssemblies 'System.Drawing' `
                 -Language CSharp -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -notmatch 'already exists') { throw }
    }
    $script:BootAnimPackerReady = $true
}
