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
            index[pinyin(of: chinese)] = english
        }
        return index
    }()

    /// 汉字 → 无声调拼音（系统内置转换，无第三方依赖）。
    private static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).replacingOccurrences(of: " ", with: "")
    }

    /// 翻译目标词为 CLIP 可用的英文。全程端侧。
    static func translate(_ target: String) async -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)

        // 已经是 ASCII（英文输入）：原样返回
        if trimmed.allSatisfy({ $0.isASCII }) {
            return trimmed.lowercased()
        }

        // 词典精确命中
        if let hit = dictionary[trimmed] {
            return hit
        }

        // 拼音层命中（容忍同音字误识别，如"平果"→"苹果"→apple）
        if let hit = pinyinIndex[pinyin(of: trimmed)] {
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
                        return translated
                    }
                } catch {
                    print("[TargetTranslator] 端侧模型翻译失败: \(error)")
                }
            }
        }
        #endif

        // 兜底：原样返回（CLIP 对中文效果差，但不至于崩溃）
        return trimmed
    }
}
