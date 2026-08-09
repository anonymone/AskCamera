import Foundation

/// CLIP BPE 分词器（纯 Swift 实现）。
/// 从 clip_vocab.json 加载词表与合并规则，输出与 CLIP 文本编码器
/// Core ML 模型兼容的 token 序列。
/// 参考 john-rocky/CoreML-Models YOLOWorldDemo 示例实现。
final class CLIPTokenizer {

    private let encoder: [String: Int]
    private let bpeRanks: [String: Int]
    private let bosToken: Int
    private let eosToken: Int
    let contextLength: Int

    private var cache: [String: [Int]] = [:]
    private let cacheLock = NSLock()

    init(vocabularyURL: URL) throws {
        let data = try Data(contentsOf: vocabularyURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoderDict = json["encoder"] as? [String: Int],
              let mergesList = json["merges"] as? [String] else {
            throw NSError(domain: "CLIPTokenizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "词表 JSON 格式无效"])
        }

        self.encoder = encoderDict
        self.bpeRanks = Dictionary(uniqueKeysWithValues:
            mergesList.enumerated().compactMap { offset, line -> (String, Int)? in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (line, offset)
            }
        )

        let bosStr = json["bos_token"] as? String ?? "<|startoftext|>"
        let eosStr = json["eos_token"] as? String ?? "<|endoftext|>"
        self.bosToken = encoderDict[bosStr] ?? 49406
        self.eosToken = encoderDict[eosStr] ?? 49407
        self.contextLength = json["context_length"] as? Int ?? 77
    }

    /// 文本 → 定长 token 序列（长度 = contextLength，尾部补 0）。
    func tokenize(_ text: String) -> [Int] {
        cacheLock.lock()
        if let cached = cache[text] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").map { String($0) }

        var tokens: [Int] = [bosToken]
        for word in words {
            let encoded = byteEncode(word + "</w>")
            for token in bpe(encoded) {
                if let id = encoder[token] {
                    tokens.append(id)
                }
            }
        }
        tokens.append(eosToken)

        if tokens.count > contextLength {
            tokens = Array(tokens.prefix(contextLength - 1)) + [eosToken]
        }
        while tokens.count < contextLength {
            tokens.append(0)
        }

        cacheLock.lock()
        cache[text] = tokens
        cacheLock.unlock()
        return tokens
    }

    // MARK: - BPE

    private func byteEncode(_ text: String) -> [String] {
        text.utf8.map { byteToUnicode($0) }
    }

    /// GPT-2 风格的字节→可打印 Unicode 映射。
    private func byteToUnicode(_ byte: UInt8) -> String {
        let b = Int(byte)
        if (33...126).contains(b) || (161...172).contains(b) || (174...255).contains(b) {
            return String(Unicode.Scalar(b)!)
        }
        return String(Unicode.Scalar(256 + b)!)
    }

    private func bpe(_ tokens: [String]) -> [String] {
        if tokens.count <= 1 { return tokens }

        var word = tokens
        while true {
            var bestPair: (String, String)?
            var bestRank = Int.max

            for i in 0..<(word.count - 1) {
                let pair = word[i] + " " + word[i + 1]
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestPair = (word[i], word[i + 1])
                }
            }
            guard let (first, second) = bestPair else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
        }
        return word
    }
}
