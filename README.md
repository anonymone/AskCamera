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
| `AskCamera/Camera` | `AVCaptureSession` 采集、预览、点击对焦、`focusPointOfInterest` 控制 |
| `AskCamera/Speech` | 基于 iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` 的端侧流式语音识别 |
| `AskCamera/Intent` | 规则式指令解析（中英文句式、方位修饰）+ 目标词端侧翻译 |
| `AskCamera/Detection` | YOLO-World 开放词汇检测（CLIP 分词/编码 + 检测 + NMS）、Vision 显著性兜底 |
| `AskCamera/App` | SwiftUI 界面与流水线协调（`AskCameraViewModel`） |

## 路线图

- [x] 阶段一：相机预览 + 点击对焦 + 语音链路（ASR → 意图 → 显著物体对焦）
- [x] 阶段二：YOLO-World V2 开放词汇检测（Core ML，任意目标词匹配 + 方位修饰选择）
- [ ] 阶段三：`VNTrackObjectRequest` 焦点跟随移动目标
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

## 使用

- 点击画面任意位置：手动对焦
- 点击麦克风按钮后说：
  - "对焦到苹果上" / "焦点切到左边的水杯" / "focus on the cup"
  - 同类多个物体时支持方位修饰："左边的" / "右边的" / "上面的" / "下面的"
  - 只说"对焦"（无目标词）会对焦到画面中最显著的物体
- 扬声器开关：开启后对焦成功有语音播报（`AVSpeechSynthesizer`，端侧）
