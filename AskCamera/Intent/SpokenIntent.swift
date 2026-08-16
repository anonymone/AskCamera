import Foundation

/// 一句口语对应的相机动作：规则快路径或端模型理解后的统一出口。
enum SpokenIntent: Equatable {
    case capture(CaptureCommand)
    case query(DetectionQuery)
}
