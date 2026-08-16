import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 目标词翻译：ASR 输出中文，CLIP 文本编码器只认英文。
/// 三级策略（全部端侧）：
/// 1. 内置词典（常见物体，零延迟）
/// 2. Foundation Models 端侧大模型翻译（Apple Intelligence 机型）
/// 3. 原样返回（英文输入或以上都不可用）
enum TargetTranslator {

    /// 常见物体中→英词典。
    private static let dictionary: [String: String] = [
        "苹果": "apple", "香蕉": "banana", "橙子": "orange", "橘子": "orange",
        "西红柿": "tomato", "番茄": "tomato", "西兰花": "broccoli", "胡萝卜": "carrot",
        "披萨": "pizza", "蛋糕": "cake", "甜甜圈": "donut", "三明治": "sandwich", "热狗": "hot dog",
        "人": "person", "人脸": "face", "脸": "face", "男人": "man", "女人": "woman",
        "孩子": "child", "小孩": "child", "婴儿": "baby", "手": "hand",
        "猫": "cat", "猫咪": "cat", "狗": "dog", "小狗": "dog", "鸟": "bird",
        "马": "horse", "羊": "sheep", "牛": "cow", "大象": "elephant", "熊": "bear",
        "斑马": "zebra", "长颈鹿": "giraffe", "兔子": "rabbit", "鱼": "fish",
        "杯子": "cup", "水杯": "cup", "马克杯": "mug", "玻璃杯": "glass", "瓶子": "bottle",
        "碗": "bowl", "盘子": "plate", "勺子": "spoon", "叉子": "fork", "刀": "knife",
        "筷子": "chopsticks", "锅": "pot", "水壶": "kettle",
        "手机": "phone", "电话": "phone", "电脑": "laptop", "笔记本电脑": "laptop",
        "键盘": "keyboard", "鼠标": "mouse", "显示器": "monitor", "屏幕": "screen",
        "电视": "tv", "遥控器": "remote", "耳机": "headphones", "音箱": "speaker",
        "相机": "camera", "手表": "watch", "平板": "tablet", "充电器": "charger",
        "书": "book", "笔": "pen", "铅笔": "pencil", "剪刀": "scissors", "纸": "paper",
        "眼镜": "glasses", "帽子": "hat", "鞋": "shoe", "鞋子": "shoe", "衣服": "clothes",
        "包": "bag", "背包": "backpack", "雨伞": "umbrella", "钥匙": "key", "钱包": "wallet",
        "领带": "tie", "口罩": "mask",
        "椅子": "chair", "桌子": "table", "沙发": "sofa", "床": "bed", "枕头": "pillow",
        "台灯": "lamp", "灯": "light", "门": "door", "窗户": "window", "窗": "window",
        "镜子": "mirror", "时钟": "clock", "钟": "clock", "花瓶": "vase", "画": "painting",
        "植物": "plant", "花": "flower", "树": "tree", "盆栽": "potted plant",
        "马桶": "toilet", "水槽": "sink", "毛巾": "towel", "牙刷": "toothbrush",
        "冰箱": "refrigerator", "微波炉": "microwave", "烤箱": "oven", "洗衣机": "washing machine",
        "车": "car", "汽车": "car", "自行车": "bicycle", "单车": "bicycle",
        "摩托车": "motorcycle", "公交车": "bus", "卡车": "truck", "飞机": "airplane",
        "船": "boat", "火车": "train", "红绿灯": "traffic light",
        "玩偶": "doll", "泰迪熊": "teddy bear", "玩具": "toy", "气球": "balloon",
        "球": "ball", "足球": "soccer ball", "篮球": "basketball",
        "山": "mountain", "云": "cloud", "月亮": "moon", "太阳": "sun",
    ]

    /// 拼音 → 英文映射（懒构建）。
    /// ASR 同音字错误（"苹果"→"平果"）导致词典精确匹配失效，退化到拼音层再查一次。
    private static let pinyinIndex: [String: String] = {
        var index: [String: String] = [:]
        for (chinese, english) in dictionary {
            // 先到先得：同音碰撞时保留任意一个（词典内碰撞极少且多为同义）
            index[ChineseText.pinyin(of: chinese)] = english
        }
        return index
    }()

    /// 中文物体词，供 ASR 词汇偏置使用。
    static var chineseVocabulary: [String] {
        Array(dictionary.keys)
    }

    /// 中文颜色词。
    static var chineseColorWords: [String] {
        colorWords.compactMap { word, _ in
            word.allSatisfy(\.isASCII) ? nil : word
        }
    }

    /// 目标短语末尾的方位虚词，ASR 常没被正则剥掉。
    private static let trailingLocatives = ["上面", "那里", "这里", "那边", "这边", "上", "里"]

    /// 同步词典/拼音/模糊查找（不含端模型）。命中则返回英文小写名词。
    static func lookup(_ target: String) -> String? {
        let trimmed = stripTrailingLocatives(target.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy(\.isASCII) {
            return trimmed.lowercased()
        }
        if let hit = dictionary[trimmed] {
            return hit
        }
        // 单字拼音误伤太多：「到」与「刀」同音 dao，半句「对焦到」会变成 knife
        guard trimmed.count >= 2 else { return nil }
        let pinyin = ChineseText.pinyin(of: trimmed)
        if let hit = pinyinIndex[pinyin] {
            return hit
        }
        return fuzzyLookup(trimmed, pinyin: pinyin)
    }

    /// ASR 纠错后给 UI 的规范中文名（「平果」→「苹果」）。
    static func canonicalChinese(for target: String) -> String? {
        let trimmed = stripTrailingLocatives(target.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty, !trimmed.allSatisfy(\.isASCII) else { return nil }
        if dictionary[trimmed] != nil { return trimmed }
        guard trimmed.count >= 2 else { return nil }
        let pinyin = ChineseText.pinyin(of: trimmed)
        if let chinese = dictionary.first(where: { ChineseText.pinyin(of: $0.key) == pinyin })?.key {
            return chinese
        }
        if let english = fuzzyLookup(trimmed, pinyin: pinyin),
           let chinese = dictionary.first(where: { $0.value == english && abs($0.key.count - trimmed.count) <= 1 })?.key {
            return chinese
        }
        return nil
    }

    private static func stripTrailingLocatives(_ raw: String) -> String {
        var target = raw
        for locative in trailingLocatives where target.hasSuffix(locative) && target.count > locative.count {
            target = String(target.dropLast(locative.count)).trimmingCharacters(in: .whitespaces)
        }
        return target
    }

    /// 三字及以上才做编辑距离：两字词（杯子/被子）差一个字就会误伤。
    private static func fuzzyLookup(_ trimmed: String, pinyin: String) -> String? {
        guard trimmed.count >= 3, pinyin.count >= 6 else { return nil }
        var bestEnglish: String?
        var bestDistance = Int.max
        for (chinese, english) in dictionary {
            guard abs(chinese.count - trimmed.count) <= 1 else { continue }
            let distance = ChineseText.levenshtein(ChineseText.pinyin(of: chinese), pinyin)
            if distance <= 1, distance < bestDistance {
                bestDistance = distance
                bestEnglish = english
            }
        }
        return bestEnglish
    }

    /// 带颜色/「的」等修饰的短语应走查询理解，不能只取词典里的光杆名词。
    static func isAttributedPhrase(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if isColorOnly(trimmed) { return false }
        if trimmed.contains("的") { return true }
        return colorEnglish(in: trimmed) != nil
    }

    /// 「白色」「黑色的」只有颜色、还没有物体名词。
    static func isColorOnly(_ target: String) -> Bool {
        let stripped = target.replacingOccurrences(of: "的", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return false }
        return colorEnglish(in: stripped) != nil && lastDictionaryNoun(in: stripped) == nil
    }

    /// 从连读目标里只留下最后一个「(颜色的)?物体」，避免「白色的鼠标…键盘」把颜色套到后一个词上。
    static func collapseToLastObject(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard let noun = lastDictionaryNoun(in: trimmed) else { return nil }

        var before = String(trimmed[..<noun.range.lowerBound])
        if let prev = lastDictionaryNoun(in: before) {
            before = String(before[prev.range.upperBound...])
        }
        while before.hasPrefix("的") {
            before = String(before.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        before = before.trimmingCharacters(in: .whitespaces)
        if before.hasSuffix("的") {
            before = String(before.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        if isColorOnly(before) || (colorEnglish(in: before) != nil && before.count <= 4) {
            return "\(before)的\(noun.cn)"
        }
        return noun.cn
    }

    /// 「白色的鼠标」→ prompts ["white mouse", "mouse"]，端模型不可用时的规则回退。
    static func attributedFallback(from target: String) -> (prompts: [String], displayName: String)? {
        let collapsed = collapseToLastObject(target) ?? target.trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }

        var nounCN: String?
        var nounEN: String?
        for (chinese, english) in dictionary {
            if collapsed.hasSuffix(chinese), chinese.count >= 1 {
                if nounCN == nil || chinese.count > nounCN!.count {
                    nounCN = chinese
                    nounEN = english
                }
            }
        }
        guard let nounCN, let nounEN else { return nil }

        var prompts = [nounEN]
        let prefix = String(collapsed.dropLast(nounCN.count))
        if let color = colorEnglish(in: prefix) {
            prompts.insert("\(color) \(nounEN)", at: 0)
        }
        return (prompts, collapsed)
    }

    private struct NounHit {
        let cn: String
        let en: String
        let range: Range<String.Index>
    }

    private static func lastDictionaryNoun(in text: String) -> NounHit? {
        var best: NounHit?
        considerNounHits(in: text, updating: &best, exactCharacters: true)
        // ASR 把「苹果」写成「平果」时字面匹配失败，按同音窗口再找一次。
        considerNounHits(in: text, updating: &best, exactCharacters: false)
        return best
    }

    private static func considerNounHits(in text: String, updating best: inout NounHit?, exactCharacters: Bool) {
        for (chinese, english) in dictionary {
            guard chinese.count >= 2 else {
                if exactCharacters {
                    considerExactOccurrences(of: chinese, english: english, in: text, updating: &best)
                }
                continue
            }
            if exactCharacters {
                considerExactOccurrences(of: chinese, english: english, in: text, updating: &best)
                continue
            }
            let expectedPinyin = ChineseText.pinyin(of: chinese)
            var searchFrom = text.startIndex
            while searchFrom < text.endIndex,
                  let end = text.index(searchFrom, offsetBy: chinese.count, limitedBy: text.endIndex) {
                let range = searchFrom..<end
                let window = String(text[range])
                if window != chinese, ChineseText.pinyin(of: window) == expectedPinyin {
                    adoptHit(NounHit(cn: chinese, en: english, range: range), updating: &best)
                }
                searchFrom = text.index(after: searchFrom)
            }
        }
    }

    private static func considerExactOccurrences(of chinese: String, english: String, in text: String, updating best: inout NounHit?) {
        var searchFrom = text.startIndex
        while let range = text.range(of: chinese, range: searchFrom..<text.endIndex) {
            adoptHit(NounHit(cn: chinese, en: english, range: range), updating: &best)
            searchFrom = range.upperBound
        }
    }

    private static func adoptHit(_ hit: NounHit, updating best: inout NounHit?) {
        let later = best.map { hit.range.lowerBound > $0.range.lowerBound } ?? true
        let longerSameStart = best.map {
            hit.range.lowerBound == $0.range.lowerBound && hit.cn.count > $0.cn.count
        } ?? false
        if later || longerSameStart {
            best = hit
        }
    }

    private static let colorWords: [(String, String)] = [
        ("白色", "white"), ("黑色", "black"), ("红色", "red"), ("蓝色", "blue"),
        ("绿色", "green"), ("黄色", "yellow"), ("灰色", "gray"), ("粉色", "pink"),
        ("紫色", "purple"), ("棕色", "brown"), ("橙色", "orange"), ("透明", "transparent"),
        ("white", "white"), ("black", "black"), ("red", "red"), ("blue", "blue"),
        ("green", "green"), ("yellow", "yellow"),
    ]

    private static func colorEnglish(in text: String) -> String? {
        let lowered = text.lowercased()
        for (word, english) in colorWords {
            if lowered.contains(word.lowercased()) { return english }
        }
        // 「百色」vs「白色」等同音错字
        let pinyin = ChineseText.pinyin(of: lowered)
        for (word, english) in colorWords where !word.allSatisfy(\.isASCII) {
            if pinyin.contains(ChineseText.pinyin(of: word)) { return english }
        }
        return nil
    }

    /// 翻译目标词为 CLIP 可用的英文。全程端侧。
    static func translate(_ target: String) async -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)

        if let hit = lookup(trimmed) {
            return hit
        }

        // Foundation Models 端侧翻译（Apple Intelligence 机型）
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                do {
                    let session = LanguageModelSession(instructions:
                        "你是翻译器。把用户给出的中文物体名称翻译成英文小写名词短语，只输出翻译结果，不要任何解释。")
                    let response = try await session.respond(to: trimmed)
                    let translated = response.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !translated.isEmpty, translated.count < 50 {
                        print("[TargetTranslator] route=foundation-models-string \(trimmed) → \(translated)")
                        return translated
                    }
                } catch {
                    print("[TargetTranslator] 端侧模型翻译失败: \(error)")
                }
            }
        }
        #endif

        // 兜底：原样返回（CLIP 对中文效果差，但不至于崩溃）
        print("[TargetTranslator] route=passthrough \(trimmed)")
        return trimmed
    }
}
