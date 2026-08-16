# AskCamera

语音控制对焦的 iOS 相机应用。对着手机说「对焦到苹果上」，镜头焦点自动落在苹果上；也可以说「拍照」「5 秒后录像」。

**所有 AI 处理均在设备端完成**：语音、图像不出设备，无网络依赖。Foundation Models 仅在本机 Apple Intelligence 可用时参与查询理解，不可用时走词典与规则回退。

## 架构

感知 → 决策 → 执行 闭环：

```
麦克风 ──► SpeechAnalyzer + 领域偏置
              │ DictationTranscriber（短指令优先；否则 SpeechTranscriber）
              │ contextualStrings + 自定义命令 LM + n-best 候选
              │ volatile 部分结果 + final 定稿
              ▼
         TranscriptNormalizer（同音/拼音改写 + 中文数字）
              ▼
         leftover 切句（只解析尚未执行的新句子；最后一条指令优先）
              │
              ├─► CaptureCommandParser（拍照 / 录像 / 倒计时，规则快路径）
              └─► QueryUnderstanding（对焦）
                    │ 规则快筛（触发词 / 取消 / 半句丢弃）
                    │ 简单名词：词典/拼音/模糊匹配 → DetectionQuery
                    │ 颜色等修饰：Foundation Models @Generable
                    │   不可用时 → 规则 attributed-fallback（如 white mouse + mouse）
                    │ DetectionQuery(yoloPrompts, spatialHint, displayName, …)
                    ▼
相机帧 ──► YOLO-World V2（Core ML，多英文 prompt 槽位）
              │ 未随包分发模型时降级为 Vision 显著性检测
              ▼
        方位选择 → 坐标转换（Vision → 预览层 → 设备坐标）
              ▼
        AVCaptureDevice.focusPointOfInterest
              │
              └─► 命中后 VNTrackObjectRequest 跟随；跟丢则复位
```

未定稿文本解析出完整指令并稳定约 400ms 即执行（词典快路径，不跑端模型）；定稿到达时按 prompts + 方位去重。倒计时与录像期间暂停听写，避免滴声或影片音轨再进 ASR。

### 查询理解

`QueryUnderstanding` 把一句话变成 `DetectionQuery`：给 YOLO-World 的短英文 prompt、给 UI 的中文名、以及左右上下等空间选择（空间关系不写入 YOLO，由选择层消费）。

| 例子 | 路由 | 结果 |
|---|---|---|
| 对焦到鼠标 | `dictionary` | prompts `["mouse"]` |
| 对焦到左边的鼠标 | `dictionary` | `mouse` + `spatial=left` |
| 对焦到白色的鼠标 | `foundation-models` 或 `attributed-fallback` | `["white mouse", "mouse"]` |
| 对焦 | 显著性 | Vision 显著物体 |
| 取消对焦 | `reset` | 停止跟踪，回到画面中心 |

连读或 ASR 把前后句拼在同一段里时：采集指令与对焦指令都只看尚未消费的新句子；目标短语只保留最后一个「(颜色的)?物体」，避免「白色的鼠标…键盘」把颜色套到后一个词上。半句（「对焦到」「白色的」）不会当成裸「对焦」去打显著性。

### 语音识别容错

短指令缺上下文，端侧听写容易把「对焦 / 拍照 / 苹果」写成同音错字，规则解析一旦对不上就整句失败。本应用保持**全部端侧、无网络**，用两层兜底而不是换云端 ASR：

| 层 | 做法 | 解决什么 |
|---|---|---|
| 识别偏置 | `AnalysisContext.contextualStrings`（命令 + 常见物体，最多 100 条）；后台编译 `SFCustomLanguageModelData` 命令模板，下次听写经 `customizedLanguage` 生效 | 从源头减少「对角 / 平果」 |
| n-best | `alternativeTranscriptions`，最优转写解析失败时按序再试候选 | 同音句系统其实认出了正确词，只是没排第一 |
| 文本归一化 | `TranscriptNormalizer`：近音表 + 拼音滑动窗口改写触发词；「五秒后拍照」→ `5秒后拍照` | 「对角到…」「怕照」「十五秒后录像」 |
| 词典容错 | 物体名拼音精确匹配；三字及以上拼音编辑距离 1；颜色/名词同音窗口（「白色的平果」→ apple） | 目标词错字不再让 YOLO prompt 对空 |

不采用的方案：云端 Whisper / 大模型纠错（违反端侧约束）；把听写引擎换成 `SpeechTranscriber` 长文本模块（短指令更慢，且不吃 contextualStrings）。

### 开放词汇检测

YOLO-World 拆分为两个 Core ML 模型，词汇不固化：

- `yoloworld_detector`（25MB）：检测主干，接受图像 + 文本 embedding
- `clip_text_encoder`（117MB）：CLIP ViT-B/32 文本编码器，目标词变化时运行一次（约 10ms），结果缓存

模型来自 [john-rocky/CoreML-Models](https://github.com/john-rocky/CoreML-Models)（YOLO-World 权重为 GPL-3.0 协议）。

### 模块

| 目录 | 职责 |
|---|---|
| `AskCamera/Camera` | `AVCaptureSession` 采集、预览、对焦、拍照（PhotoOutput）、录像（MovieFileOutput）、倒计时手电筒 |
| `AskCamera/Capture` | 拍照/录像语音指令、倒计时调度、滴声提示（`CountdownBeeper`） |
| `AskCamera/Speech` | iOS 26 `SpeechAnalyzer`：优先 `DictationTranscriber`，词汇偏置 + n-best，回退 `SpeechTranscriber` |
| `AskCamera/Intent` | 转写归一化 + 规则快筛 + 词典/拼音/模糊匹配 + Foundation Models `@Generable` + 颜色短语回退 |
| `AskCamera/Detection` | YOLO-World 开放词汇检测（CLIP 分词/编码 + 检测 + NMS）、Vision 显著性兜底、焦点跟踪 |
| `AskCamera/App` | SwiftUI 界面与流水线协调（`AskCameraViewModel`） |

## 路线图

- [x] 阶段一：相机预览 + 点击对焦 + 语音链路（ASR → 意图 → 显著物体对焦）
- [x] 阶段二：YOLO-World V2 开放词汇检测（Core ML，任意目标词匹配 + 方位修饰选择）
- [x] 阶段三：`VNTrackObjectRequest` 焦点跟随移动目标（节流对焦、跟丢自动复位）
- [x] 阶段四：Foundation Models 查询理解（结构化 `DetectionQuery` → YOLO prompts；简单路径仍走词典；端模型不可用时规则回退）
- [x] 拍照 / 录像 / 语音倒计时（滴声 + 可选闪光，采集指令优先于对焦）
- [x] 语音识别容错（领域偏置 + 拼音/同音纠错 + n-best，错字仍可执行）
- [ ] 阶段五：FastVLM 指代消歧、LiDAR 深度辅助

## 构建

要求：Xcode 26+，iOS 26+ 真机（相机与语音功能模拟器不可用）。

```bash
brew install xcodegen        # 如未安装
./scripts/download_models.sh # 下载 YOLO-World 模型（约 150MB，不入 git）
xcodegen generate
open AskCamera.xcodeproj
```

转写容错的单元测试（不需要真机麦克风）：

```bash
xcodegen generate
xcodebuild test -scheme AskCamera -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AskCameraTests
```

选择你的开发者签名后在真机上运行。首次开启麦克风时系统会自动下载中文语音模型（一次性下载，之后完全离线）。带颜色/复杂指代的查询理解需要本机 Apple Intelligence；没有时仍可用词典与 `attributed-fallback`。

## CI：PR 自动构建 IPA

每个 Pull Request（打开 / 更新）会触发 GitHub Actions workflow `Build IPA`（`macos-26` + Xcode 26.6），自动：

1. 下载 Core ML 模型
2. `xcodegen generate`
3. 编译并上传 `.ipa` 到该次 run 的 Artifacts（保留 14 天）

也可在 Actions 页手动 `workflow_dispatch` 触发。

### 签名配置（导出可安装包）

未配置签名时，CI 仍会产出 `AskCamera-unsigned.ipa`（仅验证编译，**不能**直接装到真机）。

要导出可安装 IPA，在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret | 说明 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | 导出的 `.p12` 证书，`base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | `.p12` 密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision`，同样 base64 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串密码（任意足够长的随机串） |
| `APPLE_TEAM_ID` | Apple Developer Team ID（10 位） |

可选 Repository variables：

| Variable | 默认 | 说明 |
|---|---|---|
| `EXPORT_METHOD` | `development` | `development` / `ad-hoc` / `app-store` |
| `CODE_SIGN_IDENTITY` | 按 method 自动选择 | 例如 `Apple Development` |

本地可用同一脚本（需 macOS + Xcode）：

```bash
./scripts/download_models.sh
xcodegen generate
./scripts/ci_build_ipa.sh   # 产物在 build/ipa/
```

## 使用

- 点击画面任意位置：手动对焦
- 底部快门拍照；红色按钮开始/停止录像（未指定时长时默认录 15 秒）
- 点击麦克风后，底部字幕显示未定稿（灰色）与已定稿转写；说：
  - 对焦：「对焦到苹果上」/「focus on the cup」
  - 方位：「对焦到左边的鼠标」/「焦点切到右边的水杯」（同类多个时选左/右/上/下）
  - 颜色：「对焦到白色的鼠标」（YOLO 同时试 `white mouse` 与 `mouse`）
  - 拍照：「拍照」/「拍一张」/「5 秒后拍照」
  - 录像：「开始录像」/「录 15 秒」/「3 秒后开始录 15 秒视频」/「停止录像」
  - 取消倒计时：「取消」/「取消倒计时」（不停止已在进行的录像）
  - 只说「对焦」（无目标词）会对焦到画面中最显著的物体
- 对焦成功后焦点自动跟随目标移动；说「取消对焦」/「停止跟踪」或点击画面可打断
- 倒计时用滴声提示（越接近结束越密），不念数字，以免再次被识别成指令；手电筒按钮可打开后置灯 + 屏幕闪白
- 录像开始时会暂停语音识别（麦克风留给影片音轨），结束后若此前在听写则自动恢复
- 扬声器开关：开启后对焦/拍摄成功有语音播报（`AVSpeechSynthesizer`，端侧）
- 虫子按钮：调试模式，叠加所有检测候选框与耗时
- 照片与视频保存到系统相册
