import Testing
@testable import AetherEngine

/// A live item that has rolled can stop again within seconds while AVPlayer re-estimates its buffering
/// rate, over a buffer already 4 to 6 s deep. Pinned here: when the engine may cut that wait short.
@Suite("Early rate evaluation over a deep live buffer")
struct EarlyRateEvaluationCutTests {
    private func decide(armed: Bool = true, wantsToPlay: Bool = true, evaluating: Bool = true,
                        since: Double? = 2, cuts: Int = 0, empty: Bool = false, ahead: Double = 4.5) -> Bool {
        NativeAVPlayerHost.shouldCutEarlyRateEvaluation(
            armed: armed, hostWantsToPlay: wantsToPlay, isEvaluatingBufferingRate: evaluating,
            secondsSinceFirstRoll: since, cutsSoFar: cuts, playbackBufferEmpty: empty,
            bufferedAheadSeconds: ahead)
    }

    @Test("the walk-24 shape is cut short: evaluating, early, 4 to 6 s ahead")
    func deepEarlyEvaluationIsCut() {
        #expect(decide(ahead: 4.1))
        #expect(decide(since: 9.9, ahead: 5.9))
    }

    @Test("a thin buffer keeps AVPlayer's own policy")
    func thinBufferIsLeftAlone() {
        #expect(!decide(ahead: 2.99))
        #expect(!decide(empty: true, ahead: 5))
        #expect(!decide(ahead: .nan))
    }

    @Test("only the evaluation reason, only after the roll and inside the window, only a few times")
    func boundsHold() {
        #expect(!decide(evaluating: false))
        #expect(!decide(since: nil))
        #expect(!decide(since: 10.1))
        #expect(!decide(cuts: NativeAVPlayerHost.maximumEarlyRateEvaluationCuts))
        #expect(!decide(armed: false))
        #expect(!decide(wantsToPlay: false))
    }
}
