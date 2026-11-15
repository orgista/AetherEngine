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

/// The cut above acts after the picture has frozen; walk 26 still had 7 of 38 DevTV starts wait. The early
/// window keeps AVPlayer's stall avoidance off instead, so no evaluation starts. Pinned here: when it may
/// stay off.
@Suite("Stall avoidance held off early over a deep live buffer")
struct EarlyStallAvoidanceWindowTests {
    private func hold(since: Double = 0.3, wantsToPlay: Bool = true, first: Bool = true,
                      ahead: Double = 5.75) -> Bool {
        NativeAVPlayerHost.shouldHoldStallAvoidanceOff(
            secondsSinceFirstRoll: since, hostWantsToPlay: wantsToPlay, isFirstReading: first,
            bufferedAheadSeconds: ahead)
    }

    @Test("the DevTV rolls keep it off: just rolled, 2 to 6 s ahead")
    func deepBufferAtTheRollHoldsItOff() {
        #expect(hold(ahead: 5.75))
        #expect(hold(ahead: 2.94))
        #expect(hold(ahead: 2.0))
    }

    @Test("the first reading needs a segment of depth; later readings hand back only below the join floor")
    func floorsHaveHysteresis() {
        #expect(!hold(first: true, ahead: 1.99))
        #expect(hold(first: false, ahead: 1.5))
        #expect(!hold(first: false, ahead: 1.49))
    }

    @Test("AVPlayer's policy comes back after the window, on an unknown buffer, and when the host pauses")
    func policyComesBack() {
        #expect(!hold(since: 10.01))
        #expect(!hold(ahead: .nan))
        #expect(!hold(wantsToPlay: false))
    }
}
