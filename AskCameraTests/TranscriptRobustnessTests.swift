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

    func testBareNounIsNotACommand() {
        XCTAssertNil(FocusIntentParser.parseCommand("鼠标"))
        XCTAssertNil(CaptureCommandParser.parse("鼠标"))
        XCTAssertEqual(CommandCandidateRanker.score("鼠标"), 0)
    }

    func testOpenVocabularyNounsFromLexicon() async {
        XCTAssertEqual(TargetTranslator.lookup("订书机"), "stapler")
        XCTAssertEqual(TargetTranslator.lookup("八音盒"), "music box")
        XCTAssertEqual(TargetTranslator.lookup("牌照"), "license plate")

        let query = await QueryUnderstanding.resolve("对焦到订书机", allowLanguageModel: false)
        XCTAssertEqual(query?.yoloPrompts, ["stapler"])
        XCTAssertEqual(query?.objectUnresolved, false)
        XCTAssertEqual(query?.useSaliency, false)
    }

    func testUnknownObjectDoesNotPassChineseToYOLO() async {
        let query = await QueryUnderstanding.resolve("对焦到量子闪闪球", allowLanguageModel: false)
        XCTAssertEqual(query?.objectUnresolved, true)
        XCTAssertTrue(query?.yoloPrompts.isEmpty ?? false)
        XCTAssertEqual(query?.useSaliency, false)
    }

    func testASRBiasIsCommandOnly() {
        let phrases = SpeechVocabulary.contextualPhrases()
        XCTAssertTrue(phrases.contains("对焦到"))
        XCTAssertTrue(phrases.contains("拍照"))
        XCTAssertFalse(phrases.contains("苹果"))
        XCTAssertFalse(phrases.contains("鼠标"))
        XCTAssertFalse(phrases.contains("订书机"))
    }

    func testNBestKeepsPrimaryFocusOverSpuriousPhoto() {
        let picked = CommandCandidateRanker.pick(
            best: "对焦到鼠标",
            alternatives: ["拍照", "开始录像"],
            leftover: { $0 }
        )
        XCTAssertEqual(picked, "对焦到鼠标")
        XCTAssertGreaterThan(CommandCandidateRanker.score("对焦到鼠标"), 0)
        XCTAssertEqual(CommandCandidateRanker.score("拍照"), 100)
    }

    func testNBestFallsBackWhenPrimaryIsNotACommand() {
        let picked = CommandCandidateRanker.pick(
            best: "嗯",
            alternatives: ["对角到平果"],
            leftover: { $0 }
        )
        XCTAssertEqual(picked, "对角到平果")
    }

    func testFocusParserKeepsCompoundObjectSpan() {
        let bicycle = FocusIntentParser.parseCommand("对焦到自行车")
        guard case .focus(let bicycleIntent) = bicycle else {
            return XCTFail("expected focus command")
        }
        XCTAssertEqual(bicycleIntent.target, "自行车")

        let train = FocusIntentParser.parseCommand("对焦到火车")
        guard case .focus(let trainIntent) = train else {
            return XCTFail("expected focus command")
        }
        XCTAssertEqual(trainIntent.target, "火车")
    }

    func testCompoundNounIsNotCollapsedToSuffix() async {
        XCTAssertEqual(TargetTranslator.collapseToLastObject("自行车"), "自行车")
        XCTAssertEqual(TargetTranslator.collapseToLastObject("火车"), "火车")
        XCTAssertEqual(TargetTranslator.collapseToLastObject("白色的鼠标键盘"), "键盘")
        XCTAssertEqual(TargetTranslator.lookup("自行车"), "bicycle")

        let query = await QueryUnderstanding.resolve("对焦到自行车", allowLanguageModel: false)
        XCTAssertEqual(query?.yoloPrompts, ["bicycle"])
        XCTAssertNotEqual(query?.yoloPrompts, ["car"])
        XCTAssertEqual(query?.displayName, "自行车")
    }

    func testQueryUnderstandingRecoversTyposWithoutLanguageModel() async {
        let query = await QueryUnderstanding.resolve("对角到平果", allowLanguageModel: false)
        XCTAssertEqual(query?.action, .focus)
        XCTAssertEqual(query?.yoloPrompts, ["apple"])
        XCTAssertEqual(query?.displayName, "苹果")
        XCTAssertEqual(query?.useSaliency, false)
    }
}
