import Foundation

/// 离线中英名词表：词典外的可检测物体（订书机、八音盒等）。
/// 只用于物体槽解析，不写入 ASR 偏置，避免听写把小众名吸成常见词。
enum NounLexicon {

    private static let extra: [String: String] = {
        var merged = seed
        for (chinese, english) in load() {
            merged[chinese] = english
        }
        return merged
    }()

    /// 无 bundle 资源时仍能解析的开放词样本（完整表见 `zh_en_nouns.json`）。
    private static let seed: [String: String] = [
        "订书机": "stapler",
        "八音盒": "music box",
        "音乐盒": "music box",
        "牌照": "license plate",
        "车牌": "license plate",
    ]

    private static let extraPinyinToEnglish: [String: String] = {
        var index: [String: String] = [:]
        for (chinese, english) in extra {
            let pinyin = ChineseText.pinyin(of: chinese)
            if index[pinyin] == nil {
                index[pinyin] = english
            }
        }
        return index
    }()

    private static let extraPinyinToChinese: [String: String] = {
        var index: [String: String] = [:]
        for chinese in extra.keys {
            let pinyin = ChineseText.pinyin(of: chinese)
            if index[pinyin] == nil {
                index[pinyin] = chinese
            }
        }
        return index
    }()

    static var exactPairs: [(String, String)] {
        extra.map { ($0.key, $0.value) }
    }

    static func english(exact chinese: String) -> String? {
        extra[chinese]
    }

    static func english(pinyin: String) -> String? {
        extraPinyinToEnglish[pinyin]
    }

    static func canonicalChinese(pinyin: String) -> String? {
        extraPinyinToChinese[pinyin]
    }

    private static func load() -> [String: String] {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "zh_en_nouns", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                return decoded.mapValues { $0.lowercased() }
            }
        }
        print("[NounLexicon] 未找到 zh_en_nouns.json，词典外物体只能走端模型")
        return [:]
    }

    private final class BundleToken {}
}
