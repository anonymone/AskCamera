import AVFoundation
import Foundation

/// 倒计时提示音：短促高频「滴」，避免念数字被语音识别再次当成指令。
final class CountdownBeeper {
    private var player: AVAudioPlayer?

    init() {
        do {
            let player = try AVAudioPlayer(data: Self.makeBeepWav())
            player.volume = 1
            player.prepareToPlay()
            self.player = player
        } catch {
            print("[CountdownBeeper] 无法创建提示音: \(error)")
        }
    }

    func play() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    func stop() {
        player?.stop()
    }

    /// 单反自拍倒计时节奏：剩余越少，这一秒内的滴声越多。
    static func beepCount(remaining: Int) -> Int {
        switch remaining {
        case ...1: return 8
        case 2: return 5
        case 3: return 3
        case 4: return 2
        default: return 1
        }
    }

    private static func makeBeepWav() -> Data {
        let sampleRate = 44100
        let duration = 0.05
        let frequency = 2100.0
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let attack = 0.003
            let release = 0.01
            let envelope: Double
            if t < attack {
                envelope = t / attack
            } else if t > duration - release {
                envelope = max(0, (duration - t) / release)
            } else {
                envelope = 1
            }
            let value = sin(2 * .pi * frequency * t) * envelope * 0.7
            samples[i] = Int16(clamping: Int(value * Double(Int16.max)))
        }

        let dataSize = sampleCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
