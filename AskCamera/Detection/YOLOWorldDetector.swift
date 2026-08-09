import Accelerate
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// YOLO-World V2 开放词汇检测器（Core ML，端侧）。
///
/// 两个模型分工：
/// - CLIP 文本编码器：目标词变化时运行一次（约 10ms），结果缓存
/// - 检测主干：接受图像 + 文本 embedding，输出 8400 个候选框
enum YOLOWorldError: LocalizedError {
    case preprocessFailed
    case predictionFailed

    var errorDescription: String? {
        switch self {
        case .preprocessFailed: return "图像预处理失败"
        case .predictionFailed: return "模型推理失败"
        }
    }
}

/// actor 隔离保证文本缓存与复用的图像张量串行访问。
actor YOLOWorldDetector: ObjectDetecting {

    private let visualModel: MLModel
    private let textEncoder: MLModel
    private let tokenizer: CLIPTokenizer
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let inputSize = 640
    private let maxClasses = 80
    private let embeddingDim = 512
    var confidenceThreshold: Float = 0.15
    private let nmsIoUThreshold: Float = 0.45

    private var cachedPromptKey: String?
    private var cachedTxtFeats: MLMultiArray?
    private var cachedPromptCount: Int = 0
    /// 双缓冲：ANE 可能仍持有上一轮输入，原地改同一 MLMultiArray 会导致后续推理逐渐偏移。
    private var imageSlots: [MLMultiArray?] = [nil, nil]
    private var imageSlotIndex = 0

    // MARK: - 加载

    /// 从 App Bundle 加载模型。模型缺失（未随包分发）时返回 nil，上层降级到显著性检测。
    static func loadFromBundle() -> YOLOWorldDetector? {
        guard let detectorURL = Bundle.main.url(forResource: "yoloworld_detector", withExtension: "mlmodelc"),
              let encoderURL = Bundle.main.url(forResource: "clip_text_encoder", withExtension: "mlmodelc"),
              let vocabURL = Bundle.main.url(forResource: "clip_vocab", withExtension: "json") else {
            print("[YOLOWorldDetector] Bundle 中未找到模型资源")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let visual = try MLModel(contentsOf: detectorURL, configuration: config)
            let text = try MLModel(contentsOf: encoderURL, configuration: config)
            let tokenizer = try CLIPTokenizer(vocabularyURL: vocabURL)
            return YOLOWorldDetector(visualModel: visual, textEncoder: text, tokenizer: tokenizer)
        } catch {
            print("[YOLOWorldDetector] 模型加载失败: \(error)")
            return nil
        }
    }

    private init(visualModel: MLModel, textEncoder: MLModel, tokenizer: CLIPTokenizer) {
        self.visualModel = visualModel
        self.textEncoder = textEncoder
        self.tokenizer = tokenizer
    }

    // MARK: - 预热

    /// 启动时做一次假推理，触发 Core ML 的 ANE 图编译，
    /// 避免首次语音对焦时吃掉数秒的冷启动延迟。
    func warmUp() async {
        do {
            let txtFeats = try encodeTextIfNeeded(["object"])
            let image = try nextImageTensor()
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": image,
                "txt_feats": txtFeats,
            ])
            _ = try await visualModel.prediction(from: input)
        } catch {
            print("[YOLOWorldDetector] 预热失败: \(error)")
        }
    }

    // MARK: - ObjectDetecting

    /// 返回按置信度降序的候选框（Vision 归一化坐标，左下原点）。
    func detect(target: String?, in pixelBuffer: CVPixelBuffer) async throws -> [DetectionResult] {
        guard let target, !target.isEmpty else { return [] }
        return try await detect(prompts: [target], label: target, in: pixelBuffer)
    }

    /// 使用多个英文 prompt（写入不同类别槽位，锚点取 max score）。
    func detect(prompts: [String], label: String, in pixelBuffer: CVPixelBuffer) async throws -> [DetectionResult] {
        let cleaned = prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        let txtFeats = try encodeTextIfNeeded(cleaned)
        let (tensor, imgW, imgH, padX, padY, scale) = try preprocess(pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": tensor,
            "txt_feats": txtFeats,
        ])
        let output = try await visualModel.prediction(from: input)

        guard let boxesMA = output.featureValue(for: "boxes")?.multiArrayValue,
              let scoresMA = output.featureValue(for: "scores")?.multiArrayValue else {
            throw YOLOWorldError.predictionFailed
        }

        return decode(boxes: boxesMA, scores: scoresMA, label: label,
                      promptCount: min(cleaned.count, maxClasses),
                      imgW: imgW, imgH: imgH, padX: padX, padY: padY, scale: scale)
    }

    // MARK: - 文本编码（带缓存）

    /// 多个 prompt 写入 CLIP token 矩阵不同行，一次前向得到全部 embedding。
    private func encodeTextIfNeeded(_ prompts: [String]) throws -> MLMultiArray {
        let key = prompts.joined(separator: "\u{1f}")
        if key == cachedPromptKey, let cached = cachedTxtFeats {
            return cached
        }

        let promptCount = min(prompts.count, maxClasses)
        let tokenArray = try MLMultiArray(shape: [maxClasses as NSNumber, tokenizer.contextLength as NSNumber],
                                          dataType: .int32)
        let tokenPtr = tokenArray.dataPointer.bindMemory(to: Int32.self,
                                                         capacity: maxClasses * tokenizer.contextLength)
        memset(tokenPtr, 0, maxClasses * tokenizer.contextLength * MemoryLayout<Int32>.size)

        for i in 0..<promptCount {
            let tokens = tokenizer.tokenize(prompts[i])
            let row = tokenPtr + i * tokenizer.contextLength
            for j in 0..<tokenizer.contextLength {
                row[j] = Int32(tokens[j])
            }
        }

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: ["text_tokens": tokenArray])
        let encoderOutput = try textEncoder.prediction(from: encoderInput)
        guard let embeddings = encoderOutput.featureValue(for: "text_embeddings")?.multiArrayValue else {
            throw YOLOWorldError.predictionFailed
        }

        let embPtr = embeddings.dataPointer.bindMemory(to: Float32.self, capacity: embeddings.count)
        let txtFeats = try MLMultiArray(shape: [1, maxClasses as NSNumber, embeddingDim as NSNumber],
                                        dataType: .float32)
        let featPtr = txtFeats.dataPointer.bindMemory(to: Float32.self, capacity: maxClasses * embeddingDim)
        memset(featPtr, 0, maxClasses * embeddingDim * MemoryLayout<Float32>.size)

        var embedding = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<promptCount {
            let src = embPtr + i * embeddingDim
            for j in 0..<embeddingDim {
                embedding[j] = src[j]
            }
            var norm: Float = 0
            vDSP_svesq(embedding, 1, &norm, vDSP_Length(embeddingDim))
            norm = sqrt(norm)
            if norm > 1e-8 {
                var s = 1.0 / norm
                vDSP_vsmul(embedding, 1, &s, &embedding, 1, vDSP_Length(embeddingDim))
            }
            let dst = featPtr + i * embeddingDim
            for j in 0..<embeddingDim {
                dst[j] = embedding[j]
            }
        }

        cachedPromptKey = key
        cachedTxtFeats = txtFeats
        cachedPromptCount = promptCount
        return txtFeats
    }

    // MARK: - 图像预处理（letterbox 到 640×640，RGB 0~1，CHW）

    private func preprocess(_ pixelBuffer: CVPixelBuffer) throws
        -> (MLMultiArray, Int, Int, Float, Float, Float) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw YOLOWorldError.preprocessFailed
        }

        let imgW = cgImage.width
        let imgH = cgImage.height
        let scale = Float(inputSize) / Float(max(imgW, imgH))
        let scaledW = Int(Float(imgW) * scale)
        let scaledH = Int(Float(imgH) * scale)
        let padX = (inputSize - scaledW) / 2
        let padY = (inputSize - scaledH) / 2

        guard let ctx = CGContext(data: nil, width: inputSize, height: inputSize,
                                  bitsPerComponent: 8, bytesPerRow: inputSize * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw YOLOWorldError.preprocessFailed
        }
        // iOS 位图上下文内存首行就是画面顶部，与 CVPixelBuffer / YOLO 一致。
        // 不要再 translate+scale(1,-1)：那会把图上下颠倒送进模型，
        // 上方物体的检出框会被画到屏幕底部。
        ctx.setFillColor(gray: 0.5, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        ctx.draw(cgImage, in: CGRect(x: padX, y: padY, width: scaledW, height: scaledH))

        guard let pixels = ctx.data else {
            throw YOLOWorldError.preprocessFailed
        }

        let imageArray = try nextImageTensor()
        // vDSP 向量化：RGBX 交错 UInt8 → 平面 Float CHW，0~1。
        // 逐像素 Swift 循环在 Debug 构建下慢一个数量级，这里改为跨步批量转换。
        let dst = imageArray.dataPointer.bindMemory(to: Float32.self, capacity: 3 * inputSize * inputSize)
        let src = pixels.bindMemory(to: UInt8.self, capacity: inputSize * inputSize * 4)
        let hw = inputSize * inputSize
        var inv: Float = 1.0 / 255.0
        for channel in 0..<3 {
            let plane = dst + channel * hw
            vDSP_vfltu8(src + channel, 4, plane, 1, vDSP_Length(hw))
            vDSP_vsmul(plane, 1, &inv, plane, 1, vDSP_Length(hw))
        }

        return (imageArray, imgW, imgH, Float(padX), Float(padY), scale)
    }

    private func nextImageTensor() throws -> MLMultiArray {
        imageSlotIndex = 1 - imageSlotIndex
        if let existing = imageSlots[imageSlotIndex] {
            return existing
        }
        let created = try MLMultiArray(shape: [1, 3, inputSize as NSNumber, inputSize as NSNumber],
                                       dataType: .float32)
        imageSlots[imageSlotIndex] = created
        return created
    }

    // MARK: - 解码 + NMS

    private func decode(boxes boxesMA: MLMultiArray, scores scoresMA: MLMultiArray,
                        label: String, promptCount: Int,
                        imgW: Int, imgH: Int, padX: Float, padY: Float, scale: Float) -> [DetectionResult] {
        let boxes = boxesMA.dataPointer.bindMemory(to: Float32.self, capacity: boxesMA.count)
        let scores = scoresMA.dataPointer.bindMemory(to: Float32.self, capacity: scoresMA.count)
        let shape = scoresMA.shape.map { $0.intValue }
        // scores 布局：[1, numClasses, numAnchors] 或 [numClasses, numAnchors]
        let numAnchors: Int
        let numClasses: Int
        if shape.count >= 3 {
            numClasses = shape[shape.count - 2]
            numAnchors = shape[shape.count - 1]
        } else if shape.count == 2 {
            numClasses = shape[0]
            numAnchors = shape[1]
        } else {
            numClasses = max(1, promptCount)
            numAnchors = 8400
        }
        let activeClasses = max(1, min(promptCount, numClasses,
                                       cachedPromptCount > 0 ? cachedPromptCount : promptCount))

        var candidates: [(CGRect, Float)] = []
        for a in 0..<numAnchors {
            var bestScore: Float = 0
            for c in 0..<activeClasses {
                let score = scores[c * numAnchors + a]
                if score > bestScore { bestScore = score }
            }
            guard bestScore >= confidenceThreshold else { continue }

            let cx = boxes[0 * numAnchors + a]
            let cy = boxes[1 * numAnchors + a]
            let bw = boxes[2 * numAnchors + a]
            let bh = boxes[3 * numAnchors + a]

            // 去 letterbox，归一化到原图坐标（左上原点）
            let nx = (cx - bw / 2 - padX) / (Float(imgW) * scale)
            let ny = (cy - bh / 2 - padY) / (Float(imgH) * scale)
            let nw = bw / (Float(imgW) * scale)
            let nh = bh / (Float(imgH) * scale)

            let rect = CGRect(x: CGFloat(max(0, min(1, nx))),
                              y: CGFloat(max(0, min(1, ny))),
                              width: CGFloat(max(0, min(1, nw))),
                              height: CGFloat(max(0, min(1, nh))))
            candidates.append((rect, bestScore))
        }

        // NMS：保留互不重叠的候选，支持画面中同类多实例（配合方位修饰选择）
        candidates.sort { $0.1 > $1.1 }
        var kept: [(CGRect, Float)] = []
        for candidate in candidates {
            let overlapping = kept.contains { iou(candidate.0, $0.0) > nmsIoUThreshold }
            if !overlapping {
                kept.append(candidate)
            }
            if kept.count >= 10 { break }
        }

        // 转 Vision 坐标（左下原点），与 ObjectDetecting 协议约定一致
        return kept.map { rect, score in
            let visionRect = CGRect(x: rect.origin.x,
                                    y: 1 - rect.origin.y - rect.height,
                                    width: rect.width,
                                    height: rect.height)
            return DetectionResult(boundingBox: visionRect, label: label, confidence: score)
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let interX = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let interY = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = Float(interX * interY)
        let union = Float(a.width * a.height) + Float(b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }
}
