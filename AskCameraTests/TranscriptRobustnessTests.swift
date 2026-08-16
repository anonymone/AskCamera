import XCTest
@testable import AskCamera

final class TranscriptRobustnessTests: XCTestCase {

    func testNormalizesFocusHomophones() {
        XCTAssertEqual(TranscriptNormalizer.normalize("对角到苹果"), "对焦到苹果")
        XCTAssertEqual(TranscriptNormalizer.normalize("对交到杯子"), "对焦到杯子")
        XCTAssertEqual(TranscriptNormalizer.normalize("对脚到鼠标"), "对焦到鼠标")
    }

    func testNormalizesCaptureHomophones() {
        XCTAssertEqual(TranscriptNormalizer.normalize("怕照"), "拍照")
        XCTAssertEqual(TranscriptNormalizer.normalize("拍召"), "拍照")
        XCTAssertEqual(TranscriptNormalizer.normalize("录象"), "录像")
        XCTAssertEqual(TranscriptNormalizer.normalize("录相"), "录像")
        XCTAssertEqual(TranscriptNormalizer.normalize("对焦到牌照"), "对焦到牌照")
    }

    func testConvertsSpokenNumbersBeforeSeconds() {
        XCTAssertEqual(TranscriptNormalizer.normalize("五秒后拍照"), "5秒后拍照")
        XCTAssertEqual(TranscriptNormalizer.normalize("十五秒后开始录像"), "15秒后开始录像")
        XCTAssertEqual(TranscriptNormalizer.normalize("二十秒"), "20秒")
        XCTAssertEqual(TranscriptNormalizer.normalize("两秒后拍照"), "2秒后拍照")
        XCTAssertEqual(TranscriptNormalizer.normalize("对焦到一个苹果"), "对焦到一个苹果")
    }

    func testParseFocusWithASRTypos() {
        let command = FocusIntentParser.parseCommand("对角到平果")
        guard case .focus(let intent) = command else {
            return XCTFail("expected focus command")
        }
        XCTAssertEqual(intent.target, "平果")
        XCTAssertEqual(TargetTranslator.lookup("平果"), "apple")
        XCTAssertEqual(TargetTranslator.canonicalChinese(for: "平果"), "苹果")
    }

    func testParseCaptureWithASRTyposAndSpokenDelay() {
        XCTAssertEqual(CaptureCommandParser.parse("怕照"), .photo(delaySeconds: 0))
        XCTAssertEqual(CaptureCommandParser.parse("五秒后拍照"), .photo(delaySeconds: 5))
        XCTAssertEqual(CaptureCommandParser.parse("录象"), .startVideo(
            delaySeconds: 0,
            durationSeconds: CaptureCommand.defaultVideoDurationSeconds
        ))
    }

    func testAttributedFallbackRecoversHomophoneNoun() {
        let fallback = TargetTranslator.attributedFallback(from: "白色的平果")
        XCTAssertEqual(fallback?.prompts, ["white apple", "apple"])
        XCTAssertEqual(fallback?.displayName, "白色的苹果")
    }

    func testMouseHomophoneLookup() {
        XCTAssertEqual(TargetTranslator.lookup("数标"), "mouse")
        XCTAssertEqual(TargetTranslator.canonicalChinese(for: "数标"), "鼠标")
    }

    func testIncompleteColorStillWaits() {
        XCTAssertTrue(FocusIntentParser.isIncompleteTarget("白色的"))
        XCTAssertTrue(FocusIntentParser.isIncompleteTarget("百色的"))
        XCTAssertNil(FocusIntentParser.parseCommand("对焦到白色的"))
    }

    func testQueryUnderstandingRecoversTyposWithoutLanguageModel() async {
        let query = await QueryUnderstanding.resolve("对角到平果", allowLanguageModel: false)
        XCTAssertEqual(query?.action, .focus)
        XCTAssertEqual(query?.yoloPrompts, ["apple"])
        XCTAssertEqual(query?.displayName, "苹果")
        XCTAssertEqual(query?.useSaliency, false)
    }
}
