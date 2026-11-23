# 影择

**为摄影师整理照片而做的 macOS 选片工具。**

影择把同名的 RAW、JPG、HEIC 和 XMP 整理成照片组，方便你在 Mac 上浏览、比较、评分和筛选，再把需要的照片复制到本机或已挂载的 NAS，继续修图或归档。

[下载最新版](https://github.com/BBin17/yingze/releases/latest) · [使用说明书](docs/使用说明.md) · [反馈问题](https://github.com/BBin17/yingze/issues) · [参与贡献](CONTRIBUTING.md) · [支持项目 ☕](docs/donate.md)

## 影择能做什么

- **整理照片组**：扫描照片文件夹，将同名成片、RAW 和 XMP 配对；只有 RAW 或成片的照片也可以选片。
- **浏览与比较**：在网格、单张、双图和多图视图间切换，使用快捷键加快筛选。
- **标记与筛选**：标记精选或废片，添加 0–5 星评分和颜色标签，并按条件筛选。
- **导出到本机或 NAS**：按精选、未淘汰照片、筛选结果或临时多选导出，复制后进行 SHA-256 校验。
- **保存工作进度**：在本机保存项目与选片记录；导出时为照片组写入包含评分和颜色标签的 XMP 文件。

影择目前采用人工选片，不包含自动选图功能或 AI 模型。

## 下载与安装

需要 **Apple Silicon Mac** 和 **macOS 14 或更高版本**。

1. 前往 [最新版下载页面](https://github.com/BBin17/yingze/releases/latest)，下载名称以 `arm64.dmg` 结尾的安装包。
2. 打开 DMG，将“影择”拖入“应用程序”文件夹。
3. 更新时，将新版拖入同一位置并选择替换，然后从“应用程序”打开。

影择会在启动时检查 GitHub，也可在 macOS 菜单栏选择「影择 → 检查更新…」。下载并校验新版 DMG 后，可以选择「安装并重启」。

如果在 0.25.2 或 0.25.3 中遇到「更新未完成」，请先退出所有影择窗口，用 0.25.4 的 DMG 手动替换「应用程序」里的影择。已有的项目、评分和选片标记会保留。

当前发布包尚未经过 Apple Developer 签名和公证，首次打开可能出现 macOS 安全提示。请确认安装包来自本项目的 GitHub Releases。详细步骤和常见问题见[使用说明书](docs/使用说明.md)。

## 快速开始

1. 打开影择，点击 **打开照片文件夹**，选择照片所在的文件夹并创建项目。
2. 在照片浏览界面查看、比较照片，标记精选、废片、星级或颜色。
3. 点击 **导出**，选择导出范围和保存位置，确认后开始复制。
4. 在导出结果中检查成功及失败项，确认文件完整后再进行后续处理。

选片和导出不会移动源照片；废片只是影择里的分类，不会因此删除原文件。处理重要照片前，请始终保留独立备份。

## 开发

使用支持 Swift 6 的完整 Xcode 打开 `影择.xcodeproj`，选择“影择”方案。也可在 Apple Silicon Mac 上运行：

```sh
swift build --arch arm64
swift test --arch arm64
zsh ./Scripts/build-app.sh
zsh ./Scripts/build-dmg.sh
```

构建产物分别位于 `dist/影择.app` 和 `dist/影择-arm64.dmg`。脚本使用本机临时签名；面向其他用户分发通常需要 Apple Developer 签名和公证。

## 支持项目

如果影择对你有帮助，欢迎请我喝杯咖啡 ☕。你的支持会鼓励我继续开发和维护项目，谢谢！

| 微信支付 | 支付宝 |
| :---: | :---: |
| <img src="docs/images/donate/wechat-card.png" alt="微信支付收款码" width="320"> | <img src="docs/images/donate/alipay-card.png" alt="支付宝收款码" width="320"> |

## 许可与贡献

欢迎通过 [Issues](https://github.com/BBin17/yingze/issues) 反馈问题和建议；提交代码前请阅读[贡献指南](CONTRIBUTING.md)。项目采用 [MIT License](LICENSE)，应用图标由项目作者使用 AI 生成。
