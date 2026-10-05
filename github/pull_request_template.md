<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
## 这个 PR 做了什么

<!-- 一两句话说明白。如果修的是 issue，写 "Fixes #123" -->

## 为什么这么做

<!-- 如果有不显然的设计取舍，说清楚为什么不用看起来更直接的那个写法 -->

## 怎么验证的

<!-- 贴命令和输出。改了 src/ 的话请贴出编译输出 -->

- [ ] `python tools/selftest.py` 通过（期望 887 passed）
- [ ] `python tools/check_c.py src tools/hosttest` 通过
- [ ] `pwsh tools/check-textfiles.ps1` 通过
- [ ] 改了 GUI 脚本的话：`gui/build-gui-exe.ps1` 能打包成功
- [ ] 改了安装逻辑的话：`install/build-setup-exe.ps1` 能打包成功

## 检查清单

- [ ] 没有提交 `ffmpeg-*/`、`*.exe`、`dist/*.baa`、`dist/bootanim.efi`、`tools/_testdata/`
- [ ] 新增/修改的 `.ps1` 是 **UTF-8 带 BOM**；`.bat` / `.cmd` 是 **纯 ASCII + CRLF**
- [ ] 改了 `.baa` 格式或配置语义的话，已在上面**明确写出来**并说明兼容性影响
- [ ] 注释写的是"为什么"而不是"做了什么"

## 风险

<!--
这个项目动的是系统引导路径。请回答这三个问题：
  * 这个改动最坏情况会导致什么？能不能导致开不了机？
  * 有没有加相应的防护（判空 / 边界检查 / 超时上限 / 失败时回退）？
  * 用户如果卡住了，怎么退回去？
-->
