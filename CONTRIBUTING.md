// SPDX-License-Identifier: GPL-3.0-or-later
# 贡献指南 / Contributing

感谢愿意帮忙。这个项目动的是**系统引导路径**，所以规矩比一般小工具严一些 ——
下面的每一条基本都是踩过坑之后定下来的。

---

## 一、最重要的三条

### 1. 不要改 `install/`、`gui/` 里脚本的编码和行尾

| 文件 | 要求 | 为什么 |
|---|---|---|
| `.bat` / `.cmd` | **纯 ASCII + CRLF** | cmd.exe 按 OEM 代码页逐行解析。UTF-8 中文被误读时，字节里会冒出 `\|` 或 `&`，后半行会被当命令执行；裸 LF 会让 `goto :label` 和 `(...)` 块解析出错 |
| `.ps1` | **UTF-8 带 BOM** | 没有 BOM 时 Windows PowerShell 5.1 按系统 ANSI 代码页读，中文注释会乱码甚至破坏语法 |
| `.c` / `.h` / `.cs` | **UTF-8 带 BOM** | MSVC 和 csc 默认按系统代码页读无 BOM 的源文件 |
| `.inf` / `.dsc` / `.dec` | **纯 ASCII** | EDK2 的构建工具是 Python 写的，在非 UTF-8 locale 下会解码失败 |

改完跑一下这个，它会逐条检查：

```powershell
powershell -ExecutionPolicy Bypass -File tools\check-textfiles.ps1
```

不想手动改就跑"自动修复"版（补 BOM、规范行尾）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fix-textfiles.ps1
```

`.gitattributes` 和 `.editorconfig` 已经帮你把大部分设置好了，用支持的编辑器就不会写错。

### 2. 交了代码就请顺手跑一遍测试

```powershell
# .baa 格式的参考实现自测（不需要编译器）
python tools\selftest.py

# C 源码的静态一致性（不需要编译器）
python tools\check_c.py src tools\hosttest

# 文本文件编码/行尾
powershell -ExecutionPolicy Bypass -File tools\check-textfiles.ps1

# GUI 相关（用系统自带的 csc.exe，不需要装东西）
powershell -ExecutionPolicy Bypass -File tools\test-gui-build.ps1     # 不显示窗口构造整个窗体
powershell -ExecutionPolicy Bypass -File tools\test-gui-packer.ps1    # 打包内核 <-> Python 参考实现逐像素比对
powershell -ExecutionPolicy Bypass -File tools\test-gui-cfg.ps1       # 配置读写、.baa 头解析
powershell -ExecutionPolicy Bypass -File tools\test-gui-video.ps1     # 视频拆帧接线（用桩 ffmpeg）
powershell -ExecutionPolicy Bypass -File tools\test-gui-mp4real.ps1   # 真实 ffmpeg + 真实视频（需自备）
```

后两个没有 ffmpeg / 视频时会**优雅跳过**，不算失败。

### 3. 别提交这些

已经在 `.gitignore` 里了，但请确认一下：

- `ffmpeg-*/`、`ffmpeg.exe` —— 100 MB 的第三方二进制。许可证上本项目是 GPL 所以
  提交它并不违规，但没必要让仓库膨胀。需要的人按
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 自己下载
- `gui/BootAnimGUI.exe`、`install/BootAnimSetup.exe` —— 构建产物
- `dist/*.baa`、`dist/bootanim.efi` —— 构建产物
- `tools/_testdata/` —— `selftest.py` 生成

---

## 二、开发环境

### 只用 Python 就能做的部分

`.baa` 格式的**权威实现**是 `tools/baanim.py`，它同时是：
参考解码器、编码器、以及自测套件。

```bash
pip install pillow
python tools/selftest.py          # 期望: 887 passed, 0 failed
```

`src/` 里的 C 代码**可以完全不用编译器就检查一部分正确性** ——
`tools/check_c.py` 会解析源码，检查结构体字段、常量、函数签名、
以及跨文件的调用是否一致（比如 `BaAlloc` 的返回值有没有判空）。
它比编译器宽松，但不需要工具链，适合快速迭代。

### 构建 UEFI 程序

需要 EDK2。三条路都行，详见 [编译说明.md](编译说明.md)：

| 方式 | 环境 | 工具链 |
|---|---|---|
| A | Windows + Visual Studio | `VS2022` |
| B | Linux / WSL2 | `GCC` |
| C | MSYS2 | `GNU` + gnu-efi |

一键脚本：`build/edk2/build-edk2.bat`（Windows）或 `build/edk2/build-edk2.sh`（Linux/WSL）。
它们会**自动探测** `Conf/tools_def.txt` 里实际存在的工具链名 ——
注意新版 EDK2 里叫 `GCC` 而不是 `GCC5`，写错了会报 `Not available [GCC5] not defined`。

> ⚠️ 生成的 `bootanim.efi` 请**不要**提交，它是构建产物。

### 打包 Windows 图形界面

```powershell
powershell -ExecutionPolicy Bypass -File gui\build-gui-exe.ps1      # 主程序
powershell -ExecutionPolicy Bypass -File install\build-setup-exe.ps1 # 安装程序
```

两者都用**系统自带的 `csc.exe`**（`%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`），
不需要 .NET SDK、不需要 Visual Studio、不需要联网。

> 改了 `gui\*.ps1` 或 `install\Install-App.ps1` 之后，**必须重新打包**才会反映到 exe 里 ——
> exe 内嵌的是打包时的脚本副本。

---

## 三、代码风格

### C（`src/`）

* **C89 风格声明**：变量在块首声明。EDK2 的编译参数比较严
* **不用标准库**：没有 `memcpy`/`malloc`/`printf`，用 `BaMemCopy`/`BaAlloc`/`BaPrint`
  （UEFI 环境没有 C 运行时）
* **所有 `Ba*` 前缀**，避免和 EDK2 的符号撞名
* **中文注释没问题**，但文件必须带 UTF-8 BOM
* 分配内存后**必须判空**；`tools/check_c.py` 会检查这一点
* 涉及固件数据的地方要**防御性编程**：任何从磁盘读来的长度/偏移都要先验证，
  再使用。这是这个项目最重要的设计原则，见 README 的「可靠性设计」一节

### PowerShell（`gui/`、`install/`、`tools/`）

* 文件必须带 UTF-8 BOM（见上文）
* 用 `Set-StrictMode -Off`（GUI 里故意关掉，避免访问未定义属性时炸）
* 错误处理：关键路径（写 ESP、复制文件）必须 `$ErrorActionPreference='Stop'` + `try/catch`，
  不能让失败被静默吞掉
* **调用原生程序（ffmpeg 等）时注意**：它们的 stderr 输出在
  `$ErrorActionPreference='Stop'` 下会被 PowerShell 当成**终止错误**。
  捕获输出前临时放宽到 `Continue`，否则"成功但打了警告"会被误判为失败

### 注释

注释请写**为什么**，不要复述代码在做什么。这个项目里最有价值的注释是
「为什么不能用看起来更自然的那个写法」—— 例如：

```c
/* 必须先把每个 byte 转成 uint32 再移位：PowerShell 的 -shl 会保留左操作数
   的类型，而 $bytes[$i] 是 Byte，于是 [byte]7 -shl 8 会被截断成 0 */
```

---

## 四、提交规范

### Commit message

```
<类型>: <一句话说明>

<可选：为什么这么改，以及验证方式>
```

类型：`feat` / `fix` / `docs` / `test` / `build` / `refactor` / `chore`

例子：

```
fix: 修正 GUI 状态栏把 1920x1080 显示成 128x56

PowerShell 的 -shl 会保留左操作数类型，$bytes[$i] 是 Byte，
[byte]7 -shl 8 被截断成 0。改成先转 [uint32] 再移位。
验证：tools/test-gui-cfg.ps1 新增 .baa 头解析用例
```

### Pull Request

请说明：

- [ ] 改了什么、为什么
- [ ] 跑了哪些测试，结果如何
- [ ] 如果改了 `src/`，贴出编译输出（至少要能编过）
- [ ] 如果改了界面脚本，确认 `gui\build-gui-exe.ps1` 还能打包成功
- [ ] 确认没有把 ffmpeg / exe / .baa 之类的东西提交进来

---

## 五、特别欢迎的贡献

* **在更多机器上验证兼容性** —— 尤其是不同主板固件（GOP 像素格式差异）、
  不同 ESP 布局、Secure Boot 开启的情况。这类报告比代码还珍贵
* **性能数据** —— `DEBUG=1` 时的 `avg frame ms`，在什么分辨率/帧数下
* **新的像素格式支持**（`src/BaGfx.c`）
* **文档翻译**（英文 README 目前只有一段摘要）
* **`.baa` 格式的工具链** —— 现在有 Python 参考实现和 C# 打包器，欢迎更多语言

## 六、请先开 issue 再动手的情况

* 改动 `.baa` 文件格式（会影响兼容性）
* 改动配置文件的键名或语义
* 改动引导接管的实现方式（风险最高的部分）
* 任何会让旧版本 `.baa` 无法播放的改动

---

## 七、行为准则

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
简单说：**就事论事，别针对人。**

---

## 八、许可证与贡献条款

本项目以 **GPL-3.0-or-later** 发布（见 [LICENSE](LICENSE)），
第三方组件的声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

### 你提交的代码会以什么条款授权

> **提交即表示你同意把你的贡献以 `GPL-3.0-or-later` 授权给本项目。**

也就是常说的 inbound = outbound。**本项目不要求签 CLA**，你保留自己贡献的版权，
只是把授权给出去。这意味着：

- 你的贡献会和项目一起以 GPL 发布
- 维护者**不能**把包含你贡献的代码单方面改成 MIT 之类的宽松许可证 ——
  除非拿到你的明确同意

### 请不要提交来源不明的代码

GPL 是强著佐权，混进许可证不兼容的代码会很麻烦。提交前请确认：

- 是你自己写的，**或者**
- 来自与 GPLv3 兼容的许可证（MIT / BSD / Apache-2.0 都可以并入 GPLv3），
  **并且**你在 PR 描述里写明了来源和许可证

**不要**从网上直接拷代码片段进来（尤其是不清楚来源和许可证的）。
不确定就先开个 issue 问，比事后返工省事。
