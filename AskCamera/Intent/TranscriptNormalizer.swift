import Foundation

/// ASR 定稿/未定稿文本的命令向归一化。
///
/// 短指令缺上下文，端侧听写常把「对焦 / 拍照 / 录像」写成同音错字；
/// 精确字符串匹配会直接判成「未识别为指令」。这里在解析前先纠错：
/// 1. 已知同音替换（含近音，拼音不完全相同的情况）
/// 2. 同音滑动窗口：把与命令词拼音相同的字串改成规范写法
/// 3. 「五秒 / 十五秒」等中文数字在「秒」前转成阿拉伯数字，供倒计时正则使用
enum TranscriptNormalizer {

    /// 近音但拼音不完全相同，滑动窗口覆盖不到。
    private static let homophoneCorrections: [(String, String)] = [
        // 对焦 / 聚焦 / 焦点 / 对准
        ("对交", "对焦"), ("对角", "对焦"), ("对教", "对焦"), ("对叫", "对焦"),
        ("对娇", "对焦"), ("兑焦", "对焦"), ("队焦", "对焦"), ("对搅", "对焦"),
        ("对脚", "对焦"), ("对胶", "对焦"), ("对骄", "对焦"), ("对浇", "对焦"),
        ("巨焦", "聚焦"), ("据焦", "聚焦"), ("剧焦", "聚焦"), ("橘焦", "聚焦"), ("菊焦", "聚焦"),
        ("交点", "焦点"), ("教点", "焦点"), ("胶点", "焦点"),
        ("对住", "对准"), ("对撞", "对准"),
        // 拍照 / 录像
        ("怕照", "拍照"), ("拍召", "拍照"), ("拍兆", "拍照"), ("排照", "拍照"),
        ("拍找", "拍照"),
        ("录象", "录像"), ("录相", "录像"), ("路像", "录像"), ("陆像", "录像"),
        ("照像", "照相"),
    ]

    /// 按字数从长到短，避免「拍一张」被拆成更短词。
    private static let pinyinCanonicals: [String] = [
        "拍一张", "取消对焦", "停止跟踪", "停止对焦", "开始录像", "停止录像",
        "取消倒计时", "录视频", "左边的", "右边的", "上面的", "下面的",
        "左侧的", "右侧的", "对焦", "对准", "聚焦", "焦点",
        "拍照", "照相", "拍摄", "录像", "录制", "取消",
    ].sorted { $0.count > $1.count }

    static func normalize(_ rawText: String) -> String {
        var text = rawText
        for (wrong, right) in homophoneCorrections {
            text = text.replacingOccurrences(of: wrong, with: right)
        }
        text = rewriteHomophoneWindows(text)
        text = convertSpokenNumbersBeforeSeconds(text)
        return text
    }

    /// 任意同音错字（「平果」不在此列，由词典拼音层处理）只要与命令词拼音相同即改写。
    private static func rewriteHomophoneWindows(_ text: String) -> String {
        var chars = Array(text)
        var index = 0
        while index < chars.count {
            var replaced = false
            for canonical in pinyinCanonicals {
                let length = canonical.count
                guard index + length <= chars.count else { continue }
                let window = String(chars[index..<(index + length)])
                if window == canonical { continue }
                if isLikelyObjectPosition(chars: chars, index: index) { continue }
                if ChineseText.pinyin(of: window) == ChineseText.pinyin(of: canonical) {
                    chars.replaceSubrange(index..<(index + length), with: Array(canonical))
                    index += length
                    replaced = true
                    break
                }
            }
            if !replaced {
                index += 1
            }
        }
        return String(chars)
    }

    /// 「对焦到牌照」里的「牌照」与「拍照」同音，不能改写成命令词。
    private static func isLikelyObjectPosition(chars: [Character], index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = chars[index - 1]
        return previous == "到" || previous == "在" || previous == "的" || previous == "至" || previous == "向"
    }

    /// 只在「秒」前转换，避免把「一个苹果」里的「一」改掉。
    static func convertSpokenNumbersBeforeSeconds(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if let parsed = parseChineseInt(chars, at: index),
               index + parsed.length < chars.count,
               chars[index + parsed.length] == "秒" {
                result += String(parsed.value)
                index += parsed.length
                continue
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    private static func parseChineseInt(_ chars: [Character], at index: Int) -> (value: Int, length: Int)? {
        let char = chars[index]
        if char == "十" {
            if index + 1 < chars.count, let ones = chineseDigits[chars[index + 1]], ones > 0 {
                return (10 + ones, 2)
            }
            return (10, 1)
        }
        if let tens = chineseDigits[char], tens >= 2,
           index + 1 < chars.count, chars[index + 1] == "十" {
            if index + 2 < chars.count, let ones = chineseDigits[chars[index + 2]], ones > 0 {
                return (tens * 10 + ones, 3)
            }
            return (tens * 10, 2)
        }
        if let digit = chineseDigits[char] {
            return (digit, 1)
        }
        return nil
    }
}
