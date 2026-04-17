# WYTools

面向 macOS 的轻量工具箱应用，使用 SwiftUI 与侧边栏导航，默认深色界面。所有数据处理均在本地完成（图片压缩除外，需自行配置 Tinify API）。

## 功能一览

| 模块 | 说明 |
|------|------|
| **JSON 格式化** | 粘贴或编辑 JSON，支持缩进选项（2 空格 / 4 空格 / Tab）与语法高亮展示。 |
| **图片压缩（Tinify）** | 通过 [Tinify](https://tinypng.com/developers)（与 TinyPNG 同源）压缩图片；支持队列、多 API Key 轮换、拖放与导出。需在界面中填写从 tinypng.com 获取的 API Key。 |
| **文本行对比** | 将两段文本按行拆分，对比仅出现在 A、仅出现在 B 以及两侧共有的行，可选忽略大小写与空行。 |
| **Lottie 预览** | 拖入 `lottie.json` 或 `.lottie` 文件预览；支持播放/暂停、帧跳转与进度条、画布背景色、当前帧导出 PNG；内置 DEMO。 |

侧边栏工具顺序支持拖拽调整，并会持久化到本机 `UserDefaults`。

## 环境要求

- **macOS**：与工程及依赖一致即可（建议当前主流版本）。
- **Xcode**：26.x（工程 `LastUpgradeCheck = 2630`）；需支持 Swift Package Manager。

## 依赖

- **[Lottie](https://github.com/airbnb/lottie-spm)**（XCFramework，当前锁定 **4.6.0**），通过 Xcode Swift Package 引入，用于 Lottie 预览模块。

仓库根目录存在空的 `Podfile` 模板，**当前工程不依赖 CocoaPods**，以 Xcode 内 SPM 为准。

## 如何运行

1. 用 Xcode 打开 `WYTools.xcodeproj`。
2. 等待 Swift Package 解析完成（首次会自动拉取 Lottie）。
3. 选择 Scheme **WYTools**，运行目标为 **My Mac**。

命令行编译示例：

```bash
cd /path/to/WYTools
xcodebuild -scheme WYTools -destination 'platform=macOS' build
```

## 项目结构

```
WYTools/
├── WYToolsApp.swift          # App 入口
├── ContentView.swift         # 主导航与侧边栏
├── DiffToolTheme.swift       # 通用主题色
├── JSONFormatToolView.swift
├── ImageCompressToolView.swift
├── TinifyClient.swift        # Tinify HTTP 客户端
├── LineDiffToolView.swift
└── LottieToolView.swift      # Lottie 预览（AppKit 宿主 + SwiftUI）
WYTools.xcodeproj/            # Xcode 工程
```

## 隐私与网络

- **JSON 格式化 / 文本行对比 / Lottie 预览**：不主动上传数据；Lottie 若使用外链图片需资源已内嵌（界面内有说明）。
- **图片压缩**：仅在你点击开始压缩时，将图片数据发送至 Tinify 官方接口；API Key 可保存在本机（见应用内选项）。

## 许可证

若未单独提供 `LICENSE` 文件，则以仓库所有者声明为准。
