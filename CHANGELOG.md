# 更新日志 / Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 计划中

- 只重绘变化区域，进一步降低 1080p 长动画的渲染开销
- 英文文档
- 更多 GOP 像素格式的实测覆盖

## [1.1.0] - 2024

**核心修复：播放速度。** 1.0.0 里动画明显比设定慢，这一版是冲着这个问题来的。

### 修复

- **帧节拍不准（播放太慢）** —— 根因是 1.0.0 每渲染完一帧就无条件
  `Stall(1/FPS)`，把渲染耗时**叠加**在帧周期之上。UEFI 的 Boot Services
  没有可用的高精度时钟（`GetTime` 只到秒），所以改为：
  - 用 `RDTSC` 读 CPU 时间戳计数器
  - 在 `BaPlatInit` 末尾用 `gBS->Stall(20000)` 自校准出每毫秒的 TSC 增量
  - 校准失败则退回 `PACING=fixed` 的旧行为（不会更糟）
  - 每帧只补足**剩余**时间：`Stall(帧周期 - 已用时间)`
  - 新增配置 `PACING=auto|fixed|off`，默认 `auto`
- **GUI 状态栏把 1920×1080 显示成 128×56** —— PowerShell 的 `-shl`/`-shr`
  会**保留左操作数的类型**，而 `$bytes[$i]` 是 `Byte`，于是 `[byte]7 -shl 8`
  被截断成 `0`。改成先转 `[uint32]` 再移位
- **`ListBox.SelectionMode = 'Extended'` 抛异常** —— 正确的枚举名是
  `MultiExtended`（WPF 才叫 `Extended`，WinForms 不叫）
- **ffmpeg 的 stderr 被当成致命错误** —— 原生程序往 stderr 写东西时，
  `$ErrorActionPreference='Stop'` 会把 PowerShell 的输出重定向变成终止错误，
  导致"解码成功但打了条警告"被误判为失败、**丢弃已经拆好的帧**。
  捕获前临时放宽为 `Continue`
- **ffmpeg 启动失败会把异常甩给用户** —— 现在失败就回退到下一条路线
- **安装程序在快捷方式/注册表写入失败时会中断**，留下"文件拷了、注册项没写"
  的半残状态。改成容错 + 汇总报告
- **`.cmd` 文件用 UTF-8 存中文会被 cmd.exe 执行出乱命令** ——
  cmd.exe 按 OEM 代码页解析批处理，UTF-8 中文字节里会冒出 `|`/`&`，
  后半行被当作命令。所有 `.bat`/`.cmd` 改为**纯 ASCII + CRLF**
- **`MediaClip.GetThumbnailAsync` 不存在** —— 那个方法在 `MediaComposition` 上；
  而 `MediaComposition.Clips` 是 WinRT 的 `IVector<MediaClip>`，
  PowerShell 5.1 只能拿到裸 `__ComObject`，加不进元素。这条路放弃，
  改用 ffmpeg

### 新增

- **`ENABLED` 配置开关** —— 保留安装但临时禁用动画，改一行配置即可，
  开机速度和没装一样。不用卸载再装
- **图形界面管理工具**（`gui\BootAnimGUI.exe`）
  - 换图片、设分辨率/帧率/适配方式/背景色
  - 启用/禁用动画
  - 安装/卸载引导接管，带确认框和状态显示
  - 实时显示「N 张 → 多少秒 → 估多大」，超过 32/90 MiB 会警告
  - 一键生成示例动画（没有素材也能先跑起来）
  - **GIF / 多帧 TIFF 自动拆帧**，并读取原始帧间隔建议帧率
  - **视频拆帧**（MP4/MOV/MKV/AVI/WMV/WEBM），走 ffmpeg
  - **零依赖**：界面用系统自带 WinForms，图像用 GDI+，
    打包内核用 `Add-Type` 在内存里调 `csc.exe` 编译。
    不需要 Python、不需要 .NET SDK、不需要任何编译器
- **单文件安装程序**（`install\BootAnimSetup.exe`）——
  图形化安装向导，可注册到「应用和功能」，支持 `--silent` 静默安装
- **若干测试与检查脚本**
  - `tools/selftest.py` —— `.baa` 格式的 887 项自测（含 3000 次损坏注入模糊测试）
  - `tools/check_c.py` —— C 源码静态一致性检查（不需要编译器）
  - `tools/check-textfiles.ps1` —— 文本文件编码/行尾检查
  - `tools/test-gui-*.ps1` —— GUI 的窗体构造、打包内核、配置逻辑、
    视频接线、真实 MP4 端到端

### 变更

- **性能**：`.baa` 整个文件 ≤ 32 MiB 时一次性读进内存，播放时零磁盘访问
- **性能**：帧数据行拷贝改用 `gBS->CopyMem`
- **性能**：RLE 的重复包（repeat packet）改为整字写入（`D32[K] = Px`），
  不再逐字节
- **性能**：`BaGfxClear` 用指数倍增的行填充，不再一行行画
- GUI 打包内核的 1:1 路径改为直通复制（不重采样），保证与原图逐像素一致
- 界面脚本全部改用 UTF-8 **带 BOM** 保存
- 文档重写：新增配置参考、恢复与排错、可靠性设计与已验证范围、
  图形界面、视频支持说明、许可证

### 移除

- 放弃了"用 Windows 自带 Media Foundation 拆视频帧"的路线 ——
  实测在 PowerShell 里走不通（原因见上面「修复」一节的最后一条）

## [1.0.0] - 2024

首个可用版本。

### 新增

- UEFI 应用程序，作为 ESP 上的 `bootmgfw.efi` 替身，
  播放完动画后链式加载原版引导程序（思路同 HackBGRT）
- `.baa` 帧容器格式（BAANIM01）：64 字节头 + 帧索引 + 4 字节对齐的 RLE 数据
- RLE 解码与 BMP 解码（1/4/8/16/24/32bpp，`BI_RGB` / `BI_BITFIELDS`）
- GOP 像素格式支持：BGRX/RGBX 32bpp 快速路径、PixelBitMask 16/24/32
  （8 位查找表）、PixelBltOnly（走 `Blt`）
- 配置文件 `bootanim.cfg` 与完整解析器（不认识的键会被忽略，保证向前兼容）
- 程序化兜底动画（`.baa` 加载失败时不会黑屏）
- 图形缩放（native / fit / fill / stretch）与像素滤波（nearest / bilinear）
- 安装/卸载脚本，带原版引导备份与内嵌标记校验
- ESP 挂载工具（自动找盘符、用完释放）
- Python 参考实现（`tools/baanim.py`）与打包工具（`pack_anim.py`）

### 设计原则（从第一版就定下来的）

> 配置写错、素材损坏、固件异常 —— 任何情况都**不能导致机器开不了机**。
>
> 具体体现：备份失败就中止安装、装完校验标记、配置文件出错只退化、
> 动画有超时上限、帧数据损坏只跳过而不会越界写。

---

[未发布]: ../../compare/v1.1.0...HEAD
[1.1.0]: ../../compare/v1.0.0...v1.1.0
[1.0.0]: ../../releases/tag/v1.0.0
