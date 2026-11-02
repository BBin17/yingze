# 影择

影择是一款运行在 macOS 的摄影选片工具。它将同名 JPG、HEIC、RAW 和 XMP 配对成照片组，帮助摄影师筛选、标记和导出照片。

## 功能

- 扫描照片文件夹，配对同名照片与 XMP 文件
- 使用网格、单张、双图或多图视图，支持快捷键、评分、颜色标签和筛选
- 使用“选片 / 废片”分类，支持撤回和恢复
- 将选中的照片组复制到指定位置，包括已挂载的 NAS 目录，并进行 SHA-256 校验
- 保存本地项目和选片记录，在导出中使用 Adobe 兼容的 XMP 评分和颜色标签

当前开源准备版本不包含自动选图功能或 AI 模型。

## 系统要求

- Apple Silicon Mac，macOS 14 或更新版本
- 构建需要完整 Xcode 和支持 Swift 6 的工具链

## 构建与测试

用 Xcode 打开 `影择.xcodeproj`，选择“影择”方案运行或测试。也可以在项目目录运行：

```sh
swift build --arch arm64
swift test --arch arm64
./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

应用和磁盘映像分别生成在 `dist/影择.app` 和 `dist/影择-arm64.dmg`。打包脚本使用本机临时签名，适合本机开发测试；面向其他用户分发通常需要配置 Apple Developer 签名和公证。

## 照片和项目数据

选片时不会移动源文件；导出会复制照片组。项目索引和会话保存在本机的 `~/Library/Application Support/CameraCull/`。请在处理重要照片前保留备份。

## 参与贡献

参见 [贡献指南](CONTRIBUTING.md)。

## 许可证

本项目使用 [MIT License](LICENSE)。应用图标由项目作者使用 AI 生成。
