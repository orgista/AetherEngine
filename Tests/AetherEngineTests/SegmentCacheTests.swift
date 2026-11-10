import Foundation
import Testing
@testable import AetherEngine

@Suite("SegmentCache window/prune index math")
struct SegmentCacheTests {

    private func makeData(_ n: Int, fill: UInt8 = 0xAA) -> Data { Data(repeating: fill, count: n) }

    @Test("Low-storage VOD keeps one behind and parks at two ahead")
    func lowStorageWindow() {
        let cache = SegmentCache(retentionBudgetBytes: 1000, limitsHistoryForStorage: true)
        defer { cache.close() }
        for i in 0...5 { cache.declareTarget(i); cache.store(index: i, data: makeData(100)) }
        #expect(cache.peek(index: 3) == nil)
        #expect(cache.peek(index: 4) != nil)
        #expect(cache.peek(index: 5) != nil)
        #expect(!cache.awaitPrefetchDiskHeadroom(head: 7, budgetBytes: 1000, timeout: 0))
        cache.declareTarget(6)
        #expect(cache.awaitPrefetchDiskHeadroom(head: 7, budgetBytes: 1000, timeout: 0))
    }

    @Test("Pressure waits for an unlinked mapped response to release its blocks")
    func pressureAllowsMappedDeliveryToFinish() {
        let cache = SegmentCache()
        defer { cache.close() }
        cache.store(index: 0, data: makeData(100))
        let response = cache.peek(index: 0)
        cache.declareTarget(1)
        #expect(cache.reclaimForWrite(before: 1, timeout: 0))
        #expect(cache.count == 0)
        #expect(cache.reclaimForWrite(before: 1, timeout: 0))
        #expect(response == makeData(100))
    }

    @Test("Disk pressure drops delivered files, preserving mapped reader bytes")
    func pressureReclaimsConsumedSegments() {
        let cache = SegmentCache(retentionBudgetBytes: 1000)
        defer { cache.close() }
        cache.store(index: 0, data: makeData(100))
        cache.store(index: 1, data: makeData(100))
        let reader = cache.peek(index: 0)
        cache.declareTarget(1)
        #expect(cache.reclaimForWrite(before: 2))
        #expect(cache.peek(index: 0) == nil)
        #expect(reader == makeData(100))
        #expect(cache.peek(index: 1) != nil)
        #expect(cache.totalBytes == 100)
    }

    @Test("A segment that cannot fit with an empty cache reports failure")
    func pressureCannotReclaimAnEmptyCache() {
        let cache = SegmentCache()
        defer { cache.close() }
        #expect(!cache.reclaimForWrite(before: 0))
    }

    @Test("Seek discards the old segment band before new production")
    func seekReclaimsFirst() {
        let cache = SegmentCache(retentionBudgetBytes: 1000)
        defer { cache.close() }
        for i in 0...4 { cache.store(index: i, data: makeData(100)) }
        cache.discardForSeek(to: 50)
        #expect(cache.count == 0)
        #expect(cache.totalBytes == 0)
        #expect(cache.targetIndex == 50)
        cache.store(index: 50, data: makeData(100))
        #expect(cache.peek(index: 50) == makeData(100))
    }

    @Test("store then fetch round-trips; count and totalBytes track")
    func storeFetch() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { c.close() }
        c.store(index: 0, data: makeData(100))
        c.store(index: 1, data: makeData(200))
        #expect(c.count == 2)
        #expect(c.totalBytes == 300)
        #expect(c.peek(index: 0)?.count == 100)
        #expect(c.fetch(index: 1, timeout: 0.1)?.count == 200)
        #expect(c.peek(index: 99) == nil)
    }

    @Test("Overwriting an index subtracts the old byte count (not double-counted)")
    func overwriteByteAccounting() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { c.close() }
        c.store(index: 3, data: makeData(100))
        #expect(c.totalBytes == 100)
        c.store(index: 3, data: makeData(250))
        #expect(c.count == 1)
        #expect(c.totalBytes == 250)
    }

    @Test("Backward refetch does not evict already-produced forward segments")
    func backwardRefetchKeepsForward() {
        // forwardWindow small, backwardWindow wide so production never prunes the trailing end.
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.count == 11)
        // AVPlayer audio-handover refetch to seg 2: hi anchors on highestStoredIndex (10), not
        // target+forwardWindow (4), so forward seg 3..10 survive (repro: seg0..25, refetch4 stalled at 15).
        c.declareTarget(2)
        #expect(c.count == 11)
        #expect(c.peek(index: 3) != nil)
        #expect(c.peek(index: 10) != nil)
    }

    @Test("highestStoredIndex is monotonic; only reset by resetHighWaterForRestart")
    func highWaterMonotonic() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.highestStoredIndex == 10)
        c.store(index: 4, data: makeData(10))     // storing a lower index
        #expect(c.highestStoredIndex == 10)       // must not lower the high-water mark
        c.resetHighWaterForRestart()
        #expect(c.highestStoredIndex == -1)
    }

    @Test("After high-water reset, prune drops segments above target+forwardWindow")
    func pruneAfterReset() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.resetHighWaterForRestart()
        c.declareTarget(2)                        // hi = max(2+2, -1) = 4 -> seg 5..10 evicted
        #expect(c.peek(index: 5) == nil)
        #expect(c.peek(index: 4) != nil)          // inside forward window
        #expect(c.peek(index: 0) != nil)          // inside (wide) backward window
    }

    @Test("indexRange reflects only resident entries")
    func indexRangeResident() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 20)
        defer { c.close() }
        #expect(c.indexRange() == nil)
        for i in 5...8 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        let range = c.indexRange()
        #expect(range?.0 == 5)
        #expect(range?.1 == 8)
    }

    @Test("evictBelow removes segments strictly below the cutoff and adjusts totalBytes")
    func evictBelowCutoff() {
        let c = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.evictBelow(5)
        #expect(c.peek(index: 4) == nil)
        #expect(c.peek(index: 5) != nil)
        #expect(c.totalBytes == 60)   // seg 5..10 == 6 * 10 bytes
    }

    @Test("Init version resolution picks the highest fromSegment at or below the index")
    func initVersionResolution() {
        let c = SegmentCache()
        defer { c.close() }
        c.setInit(makeData(8, fill: 0))
        c.addInitVersion(makeData(8, fill: 1), fromSegment: 10)
        c.addInitVersion(makeData(8, fill: 2), fromSegment: 20)
        #expect(c.initVersionID(forSegment: 5) == 0)
        #expect(c.initVersionID(forSegment: 10) == 1)
        #expect(c.initVersionID(forSegment: 15) == 1)
        #expect(c.initVersionID(forSegment: 25) == 2)
        #expect(c.initData(versionID: 0)?.first == 0)
        #expect(c.initData(versionID: 1)?.first == 1)
        #expect(c.initData(versionID: 2)?.first == 2)
    }

    @Test("addInitVersion is idempotent on fromSegment (updates in place)")
    func initVersionIdempotent() {
        let c = SegmentCache()
        defer { c.close() }
        c.addInitVersion(makeData(8, fill: 1), fromSegment: 10)
        c.addInitVersion(makeData(8, fill: 9), fromSegment: 10)
        #expect(c.initVersionID(forSegment: 12) == 1)
        #expect(c.initData(versionID: 1)?.first == 9)
    }

    @Test("close clears all bookkeeping")
    func closeClears() {
        let c = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        c.store(index: 0, data: makeData(100))
        c.close()
        #expect(c.count == 0)
        #expect(c.totalBytes == 0)
        #expect(c.highestStoredIndex == -1)
        #expect(c.peek(index: 0) == nil)
    }

    @Test("contiguousForwardFrontier stops at the first gap ahead of target")
    func contiguousForwardFrontierStopsAtGap() {
        let c = SegmentCache(forwardWindow: 200, backwardWindow: 20)
        defer { c.close() }
        // Resident: 5,6,7,8 then a hole at 9, then 10.
        for i in [5, 6, 7, 8, 10] { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(from: 5) == 8)   // stops before the hole at 9
        #expect(c.contiguousForwardFrontier(from: 7) == 8)
        #expect(c.contiguousForwardFrontier(from: 8) == 8)
        #expect(c.contiguousForwardFrontier(from: 9) == 8)   // 9 absent -> targetIdx - 1
        #expect(c.contiguousForwardFrontier(from: 99) == 98) // fully absent -> targetIdx - 1
    }
}
