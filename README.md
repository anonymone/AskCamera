# AskCamera

语音控制对焦的 iOS 相机应用。对着手机说"对焦到苹果上"，镜头焦点自动落在苹果上。

**所有 AI 处理均在设备端完成**：语音、图像不出设备，无网络依赖。

## 架构

感知 → 决策 → 执行 闭环：

```
麦克风 ──► SpeechAnalyzer (iOS 26 端侧流式 ASR)
              │ 定稿文本
              ▼
        FocusIntentParser (规则快路径，提取目标词 + 方位修饰)
              │ FocusIntent(target: "苹果", spatialHint: .left)
              ▼
        TargetTranslator (中→英：词典 / Foundation Models，端侧)
              │ "apple"
              ▼
相机帧 ──► YOLO-World V2 (Core ML 开放词汇检测，任意目标词)
              │ 候选框列表（未随包分发模型时降级为 Vision 显著性检测）
              ▼
        方位选择 → 坐标转换 (Vision → 预览层 → 设备坐标)
              ▼
        AVCaptureDevice.focusPointOfInterest (驱动镜头对焦)
```

### 开放词汇检测

YOLO-World 拆分为两个 Core ML 模型，词汇不固化：

- `yoloworld_detector`（25MB）：检测主干，接受图像 + 文本 embedding
- `clip_text_encoder`（117MB）：CLIP ViT-B/32 文本编码器，目标词变化时运行一次（约 10ms），结果缓存

模型来自 [john-rocky/CoreML-Models](https://github.com/john-rocky/CoreML-Models)（YOLO-World 权重为 GPL-3.0 协议）。

### 模块

| 目录 | 职责 |
|---|---|
| `AskCamera/Camera` | `AVCaptureSession` 采集、预览、对焦、拍照（PhotoOutput）、录像（MovieFileOutput） |
| `AskCamera/Capture` | 拍照/录像语音指令解析、倒计时与定时停止调度 |
| `AskCamera/Speech` | 基于 iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` 的端侧流式语音识别 |
| `AskCamera/Intent` | 规则式指令解析（中英文句式、方位修饰）+ 目标词端侧翻译 |
| `AskCamera/Detection` | YOLO-World 开放词汇检测（CLIP 分词/编码 + 检测 + NMS）、Vision 显著性兜底 |
| `AskCamera/App` | SwiftUI 界面与流水线协调（`AskCameraViewModel`） |

## 路线图

- [x] 阶段一：相机预览 + 点击对焦 + 语音链路（ASR → 意图 → 显著物体对焦）
- [x] 阶段二：YOLO-World V2 开放词汇检测（Core ML，任意目标词匹配 + 方位修饰选择）
- [x] 阶段三：`VNTrackObjectRequest` 焦点跟随移动目标（节流对焦、跟丢自动复位）
- [ ] 阶段四：Foundation Models 复杂指令解析（"封面蓝色的那本书"）
- [ ] 阶段五：FastVLM 指代消歧、LiDAR 深度辅助

## 构建

要求：Xcode 26+，iOS 26+ 真机（相机与语音功能模拟器不可用）。

```bash
brew install xcodegen        # 如未安装
./scripts/download_models.sh # 下载 YOLO-World 模型（约 150MB，不入 git）
xcodegen generate
open AskCamera.xcodeproj
```

选择你的开发者签名后在真机上运行。首次开启麦克风时系统会自动下载中文语音模型（一次性下载，之后完全离线）。

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
- 点击麦克风按钮后说：
  - 对焦："对焦到苹果上" / "焦点切到左边的水杯" / "focus on the cup"
  - 拍照："拍照" / "5 秒后拍照"
  - 录像："开始录像" / "3 秒后开始录 15 秒视频" / "停止录像"
  - 取消倒计时："取消" / "取消倒计时"（不停止已在进行的录像）
  - 同类多个物体时支持方位修饰："左边的" / "右边的" / "上面的" / "下面的"
  - 只说"对焦"（无目标词）会对焦到画面中最显著的物体
- 对焦成功后焦点自动跟随目标移动；说"取消对焦"/"停止跟踪"或点击画面可打断
- 录像开始时会暂停语音识别（麦克风留给影片音轨），结束后若此前在听写则自动恢复
- 扬声器开关：开启后对焦/拍摄成功有语音播报（`AVSpeechSynthesizer`，端侧）
