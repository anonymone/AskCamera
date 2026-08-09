# AskCamera

语音控制对焦的 iOS 相机应用。对着手机说"对焦到苹果上"，镜头焦点自动落在苹果上。

**所有 AI 处理均在设备端完成**：语音、图像不出设备，无网络依赖。

## 架构

感知 → 决策 → 执行 闭环：

```
麦克风 ──► SpeechAnalyzer (iOS 26 端侧流式 ASR)
              │ 定稿文本
              ▼
        FocusIntentParser (规则快路径，提取目标词)
              │ FocusIntent(target: "苹果")
              ▼
相机帧 ──► ObjectDetecting (视觉检测，输出目标 bounding box)
              │ 坐标转换 (Vision → 预览层 → 设备坐标)
              ▼
        AVCaptureDevice.focusPointOfInterest (驱动镜头对焦)
```

### 模块

| 目录 | 职责 |
|---|---|
| `AskCamera/Camera` | `AVCaptureSession` 采集、预览、点击对焦、`focusPointOfInterest` 控制 |
| `AskCamera/Speech` | 基于 iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` 的端侧流式语音识别 |
| `AskCamera/Intent` | 规则式对焦指令解析（中英文句式） |
| `AskCamera/Detection` | 检测协议 + 实现。当前为 Vision 显著性检测，YOLO-World 接入中 |
| `AskCamera/App` | SwiftUI 界面与流水线协调（`AskCameraViewModel`） |

## 路线图

- [x] 阶段一：相机预览 + 点击对焦 + 语音链路（ASR → 意图 → 显著物体对焦）
- [ ] 阶段二：YOLO-World V2 开放词汇检测（Core ML，任意目标词匹配）
- [ ] 阶段三：`VNTrackObjectRequest` 焦点跟随移动目标
- [ ] 阶段四：Foundation Models 复杂指令解析（"封面蓝色的那本书"）
- [ ] 阶段五：FastVLM 指代消歧、LiDAR 深度辅助

## 构建

要求：Xcode 26+，iOS 26+ 真机（相机与语音功能模拟器不可用）。

```bash
brew install xcodegen   # 如未安装
xcodegen generate
open AskCamera.xcodeproj
```

选择你的开发者签名后在真机上运行。首次开启麦克风时系统会自动下载中文语音模型（约一次性下载，之后完全离线）。

## 使用

- 点击画面任意位置：手动对焦
- 点击麦克风按钮后说：
  - "对焦到苹果上" / "焦点切到左边的水杯" / "focus on the cup"
  - 当前阶段（显著性检测）会对焦到画面中最显著的物体；开放词汇匹配随阶段二上线
- 扬声器开关：开启后对焦成功有语音播报
