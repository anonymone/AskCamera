import Foundation

/// 汉字拼音与编辑距离，供 ASR 纠错与词典模糊匹配共用。
enum ChineseText {

    /// 无声调、无空格拼音。系统 `CFStringTransform`，无第三方依赖。
    static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).replacingOccurrences(of: " ", with: "")
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let s = Array(a)
        let t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(prev[j] + 1, current[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &current)
        }
        return prev[t.count]
    }
}
