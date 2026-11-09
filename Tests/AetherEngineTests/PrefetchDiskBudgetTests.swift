// Tests/AetherEngineTests/PrefetchDiskBudgetTests.swift
// Opt-in whole-source prefetch (#207): a host that offers "buffer without limit" passes a large
// LoadOptions.forwardBufferSegments. The hard prune window is never evicted (see SegmentRetentionTests),
// so a window that spans the whole film makes the retention budget, the only guard against filling a
// nearly full volume, unreachable. Two pieces keep that honest: the budget drops its 2 GiB default cap
// for opt-in windows (the quarter-of-free-space clamp stays), and the producer parks once its race-ahead
// reaches the budget instead of writing past it.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Opt-in prefetch budget sizing")
struct PrefetchBudgetSizingTests {

    @Test("Opt-in windows drop the 2 GiB cap and keep a quarter of free space")
    func optInDropsTheDefaultCap() {
        #expect(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 100 << 30,
                                                       capRelaxed: true) == 25 << 30)
    }

    @Test("Opt-in budget still clamps to a quarter of a tight volume")
    func optInStillClampsToQuarterOfFreeDisk() {
        #expect(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 4 << 30,
                                                       capRelaxed: true) == 1 << 30)
    }

    @Test("Opt-in budget keeps the conservative cap when capacity is unknown")
    func optInUnknownCapacityFallsBackToTheCap() {
        #expect(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: nil,
                                                       capRelaxed: true) == 2 << 30)
    }

    @Test("The cap relaxes only above the historical window ceiling")
    func capRelaxesOnlyForOptInWindows() {
        #expect(HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: 10) == false)
        #expect(HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: 150) == false)
        #expect(HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: 151) == true)
        #expect(HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: 2700) == true)
    }
}

@Suite("Prefetch disk-budget backpressure decision")
struct PrefetchDiskBudgetDecisionTests {

    @Test("A session without a retention budget never parks (live keeps window-only pruning)")
    func noBudgetNeverParks() {
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 5_000, budgetBytes: 0,
                                              head: 100, consumerTarget: 0) == false)
    }

    @Test("A race-ahead that fits the budget never parks (every pre-207 session)")
    func raceAheadUnderBudgetNeverParks() {
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 999, budgetBytes: 1_000,
                                              head: 100, consumerTarget: 0) == false)
    }

    @Test("A race-ahead at the budget parks while the consumer has a safe lead")
    func raceAheadAtBudgetParks() {
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 1_000, budgetBytes: 1_000,
                                              head: 100, consumerTarget: 80) == true)
    }

    @Test("The park never starves the consumer: a short lead keeps producing")
    func shortLeadKeepsProducing() {
        // AVPlayer is within `minAheadSegments` of the write head: bounding disk here would stall
        // playback.
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 5_000, budgetBytes: 1_000,
                                              head: 100, consumerTarget: 99) == false)
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 5_000, budgetBytes: 1_000,
                                              head: 100, consumerTarget: 98) == true)
    }

    /// DevTV 2026-11-08: a 4K remux (~30-50 MB a segment) with ~130 MB free. A default session's
    /// race-ahead is the 10-segment forward window, so a park that needed a 10-segment lead never held
    /// and the producer wrote until a segment write failed with ENOSPC.
    @Test("A default-window session parks before its forward window fills a tight volume")
    func defaultWindowParksOnATightVolume() {
        let segment = 40 << 20
        let budget = HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 600 << 20)
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 4 * segment, budgetBytes: budget,
                                              head: 104, consumerTarget: 100) == true)
        #expect(PrefetchDiskBudget.shouldPark(forwardBytes: 4 * segment, budgetBytes: 2 << 30,
                                              head: 104, consumerTarget: 100) == false)
    }
}

@Suite("SegmentCache prefetch footprint")
struct SegmentCachePrefetchFootprintTests {

    private func makeData(_ n: Int) -> Data { Data(repeating: 0xAA, count: n) }

    /// Bytes behind the playhead are either the small backward window or budget-evictable extras, so
    /// only what sits at or above the consumer's target can grow the footprint without bound.
    @Test("Forward bytes count only what sits at or above the consumer target")
    func forwardBytesExcludeHistory() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 1_000_000)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.forwardBytes == 10)
        #expect(c.totalBytes == 110)
    }

    /// The #207 shape: the producer races a whole-source window ahead of a consumer that has barely
    /// moved, so every segment it writes lands inside the exempt span and the budget evicts nothing.
    @Test("A whole-source prefetch keeps every raced segment resident past the budget")
    func wholeSourcePrefetchOutgrowsTheBudget() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 50)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.forwardBytes == 110)
        #expect(c.totalBytes == 110)   // 2.2x the budget: the window is exempt from it
    }

    @Test("Headroom is immediate while the race-ahead fits the budget")
    func headroomImmediateUnderBudget() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 1_000)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 1_000, timeout: 0.05) == true)
    }

    @Test("Headroom is withheld once the race-ahead fills the budget")
    func headroomWithheldOverBudget() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 50)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.05) == false)
    }

    @Test("Headroom is granted regardless of the budget while the consumer is close behind")
    func headroomGrantedForACloseConsumer() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 50)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.awaitPrefetchDiskHeadroom(head: 1, budgetBytes: 50, timeout: 0.05) == true)
    }

    @Test("A session without a budget never withholds headroom")
    func headroomGrantedWithoutBudget() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 0)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 0, timeout: 0.05) == true)
    }

    @Test("Headroom returns once the playhead advances into the buffered span")
    func headroomReturnsAsPlaybackAdvances() {
        let c = SegmentCache(forwardWindow: 1_000, backwardWindow: 2, retentionBudgetBytes: 50)
        defer { c.close() }
        c.declareTarget(0)
        for i in 0...10 { c.store(index: i, data: makeData(10)) }
        #expect(c.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.05) == false)
        c.declareTarget(9)   // playback marched on: only segments 9 and 10 are still ahead of it
        #expect(c.awaitPrefetchDiskHeadroom(head: 11, budgetBytes: 50, timeout: 0.05) == true)
    }

    /// Regression guard for the standard path: a long session fills the retention budget with retained
    /// history, which the extras eviction already bounds. Counting it as prefetch would throttle a
    /// producer whose actual race-ahead is a handful of segments.
    @Test("Retained history behind the playhead never withholds headroom")
    func retainedHistoryDoesNotWithholdHeadroom() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 2, retentionBudgetBytes: 50)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.totalBytes == 50)   // budget full of retained history
        #expect(c.awaitPrefetchDiskHeadroom(head: 30, budgetBytes: 50, timeout: 0.05) == true)
    }
}

/// DevTV 2026-11-08: tvOS reported 672 MiB free and a segment write still failed with ENOSPC at 208 MiB
/// resident, so the session gives back half of its footprint after each full-volume failure.
@Suite("Disk budget after a full volume")
struct FullVolumeBudgetTests {

    @Test("A full volume halves what was resident")
    func halvesTheResidentFootprint() {
        #expect(HLSVideoEngine.budgetAfterFullVolume(currentBudgetBytes: 168 << 20,
                                                     residentBytes: 208 << 20) == 84 << 20)
        #expect(HLSVideoEngine.budgetAfterFullVolume(currentBudgetBytes: 168 << 20,
                                                     residentBytes: 100 << 20) == 50 << 20)
    }

    @Test("The budget stops shrinking at its floor")
    func stopsAtTheFloor() {
        let floor = HLSVideoEngine.minimumFullVolumeBudgetBytes
        #expect(HLSVideoEngine.budgetAfterFullVolume(currentBudgetBytes: 1 << 30,
                                                     residentBytes: 2 * floor) == floor)
        #expect(HLSVideoEngine.budgetAfterFullVolume(currentBudgetBytes: 1 << 30,
                                                     residentBytes: 2 * floor - 2) == nil)
    }

    @Test("Lowering the cache budget evicts retained history at once")
    func cacheEvictsToTheLoweredBudget() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 1_000)
        defer { c.close() }
        for i in 0...20 { c.declareTarget(i); c.store(index: i, data: Data(repeating: 0xAA, count: 10)) }
        #expect(c.totalBytes == 210)
        c.lowerRetentionBudget(to: 50)
        #expect(c.totalBytes == 50)
        #expect(c.peek(index: 20) != nil)
        #expect(c.peek(index: 15) == nil)
    }
}
