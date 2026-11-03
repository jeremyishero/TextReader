# 听书朗读（TextReader）

一个 iOS 应用：导入 txt / Word(.docx) / PDF，自动提取文本，一键「整体解析」识别书中人物（合并姓名/称谓/代词/描述词为同一角色、多角度判定性别）、识别情绪（喜怒哀乐），并用地图式离线语音按角色分声朗读；旁白用中性声，语速与声音可调节。

## 功能
- **导入**：从「文件」App 或系统分享导入 txt / .docx / .pdf（`.doc` 旧格式不支持，请另存为 .docx）。
- **文本提取**：txt 自动编码探测（UTF-8 / GBK 等）；docx 通过 ZIPFoundation 解析；pdf 通过 PDFKit。
- **整体解析**（角色/情绪分析）：
  - 识别人物，将「林风 / 林兄 / 那少年 / 他」等合并为同一角色 ID；
  - 多角度投票判定性别（名字用字 + 称谓 + 关系词 + 代词），无法判定则为中性声；
  - 识别每段对话情绪（喜/怒/哀/乐），朗读时通过语速/音高表达；
  - 旁白保持中性声。
- **朗读控制**：播放 / 暂停 / 停止、语速滑块、角色分声开关；可在设置中选择默认声音。
- **朗读进度记忆**：关闭 App / 返回列表后再进入，顶部提示「上次读到第 N 段」，一键断点续读（进度节流持久化）。
- **简繁 / 中英混读切声**：设置中分别选择简体中文 / 繁体中文 / 英文声音；开启「自动切声」后按每段文字的语言自动切换对应声音（判定引擎在 CoreLogic，含单元测试）。
- **云端 TTS 备选通道**：设置中配置 OpenAI 兼容 `/v1/audio/speech` 端点 + Key + 音色，开启后优先云端合成（更自然），失败或离线自动回退本地语音。
- **扫描版 PDF OCR**：导入 PDF 时逐页检测文本层，无文本层的页自动用 Vision（约 300 DPI 渲染，zh-Hans/zh-Hant/en-US）识别文字，文档标记「已 OCR」。
- **可选云端 LLM 解析**：开启并在设置填写 API Key 后，「整体解析」可调用 OpenAI 兼容接口获得更高准确度（失败自动回退本地引擎）。

## 本地构建（Mac 上仅需一步）
1. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
2. 在工程目录执行：`xcodegen generate`
3. 打开生成的 `TextReader.xcodeproj`，选择模拟器或真机，`⌘R` 运行。

> 工程由 `project.yml` 描述；`Packages/CoreLogic` 为纯逻辑 SwiftPM 包（含单元测试）。

## 真机安装（需 Apple ID，仅此一步手动）
iOS 不允许第三方无证签名安装。在 Xcode 中：
1. 用你的 Apple ID 登录 Xcode → Settings → Accounts；
2. 选中 TextReader target → Signing & Capabilities，Team 选你的个人账户；
3. 连接 iPhone，`⌘R` 即可安装运行（免费开发者账号支持）。

## 云端编译验证（GitHub Actions）
仓库已包含 `.github/workflows/ci.yml`：在 macOS runner 上 `xcodegen generate` → `xcodebuild` 模拟器编译 → `swift test` 运行 CoreLogic 单元测试（覆盖性别判定、指代合并、情绪识别、docx 提取）。推送 `main` 分支或手动 `workflow_dispatch` 即触发。

## 已知限制
- `.doc` 二进制格式不支持（请另存为 .docx）；OCR 对模糊扫描件 / 手写体识别率有限。
- 离线角色/情绪分析为启发式，复杂长篇或第一人称视角代词回指可能误判；可开启云端 LLM 或后续手动校正。
- 离线 TTS 音色偏机械，情绪仅能以 rate/pitch/volume 表达。
- 最终真机安装需用户 Apple ID 签名（Apple 账号限制，无法由他人代做）。

## 目录结构
```
TextReader/
├── project.yml                 # XcodeGen 工程描述
├── TextReaderApp.swift         # 入口 + 音频会话
├── Models/                    # DocumentItem / AppSettings / TTSPlayer
├── Services/DocumentStore.swift
├── Views/                     # 文档列表 / 阅读 / 解析结果 / 播放条 / 设置
├── Info.plist
├── Packages/CoreLogic/        # 纯逻辑包（可 swift test）
│   ├── Sources/CoreLogic/     # GenderLexicon / EmotionLexicon / CharacterAnalyzer /
│   │                          #   DocxParser / TextExtractor / TextChunker /
│   │                          #   CloudAnalyzer / LanguageRouter
│   └── Tests/
└── .github/workflows/ci.yml
```
