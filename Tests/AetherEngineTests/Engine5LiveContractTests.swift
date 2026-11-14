import Foundation
import Testing
@testable import AetherEngine

struct Engine5LiveContractTests {
    private func provider(cache: SegmentCache, budget: Int = 0, cadence: LiveCadencePolicy? = nil) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: [], codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil, resolution: (1920, 1080), videoRange: .sdr,
            frameRate: 25, hdcpLevel: nil, sourceBitrate: 6_000_000, isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5,
                                               dvrWindowSeconds: nil, retentionBudgetBytes: budget),
            liveCadencePolicy: cadence
        )
    }

    private func target(_ text: String) -> Int? {
        text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
    }

    @Test func partialFragmentCannotSealTheFirstFullGOP() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        subject.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.5)
        _ = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: subject)
        #expect(subject.sealedLiveTargetDurationSeconds == nil)
        subject.appendLiveSegment(index: 1, startSeconds: 0.5, durationSeconds: 2.369)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        #expect(target(playlist) == 3)
        #expect(target(HLSLocalServer.buildMediaPlaylistText(provider: subject)) == 3)
    }

    @Test func laterGOPCannotEnterThePublishedPlaylist() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        for index in 0..<4 {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 0.9,
                                      durationSeconds: 0.9)
        }
        let first = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        subject.appendLiveSegment(index: 4, startSeconds: 3.6, durationSeconds: 2.369)
        let next = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        #expect(target(first) == 1)
        #expect(target(next) == 1)
        #expect(next.contains("#EXTINF:2.369") == false)
        #expect(subject.waitForLiveSegment(index: 4, timeout: 0) == false)
    }

    @Test(arguments: [(37, 2, 3), (73, 38, 39)])
    func windowRetainsTheNextUnfetchedSegment(sample: (Int, Int, Int)) {
        let (total, consumer, nextNeeded) = sample
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        cache.declareTarget(consumer)
        for index in 0..<total {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        let snapshot = subject.notePlaylistBuild()
        #expect(snapshot.firstVisible <= nextNeeded)
        #expect(snapshot.visibleCount - snapshot.firstVisible <= LiveWindowSizing.maxWindowSegments)
    }
    @Test func cadenceChangeUsesANewProviderAndKeepsTheOldTailValid() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        for index in 0..<4 {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 0.9,
                                      durationSeconds: 0.9)
        }
        let old = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        subject.appendLiveSegment(index: 4, startSeconds: 3.6, durationSeconds: 2.369)
        let successor = try #require(subject.liveSuccessorIfNeeded())
        let fresh = HLSLocalServer.buildMediaPlaylistText(provider: successor)
        #expect(target(fresh) == 3)
        #expect(fresh.contains("#EXTINF:2.369"))
        let retired = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        #expect(target(retired) == target(old))
        #expect(retired.contains("#EXTINF:2.369") == false)
        #expect(subject.notePlaylistBuild().visibleCount == 4)
        #expect(subject.liveSuccessorIfNeeded() == nil)
    }

    @Test func hardPlaylistCapRequiresRejoinBeforeWithdrawingTheConsumer() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        cache.declareTarget(2)
        for index in 0..<(LiveWindowSizing.maxWindowSegments - 1) {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        #expect(subject.notePlaylistBuild().firstVisible <= 3)
        #expect(subject.liveSuccessorIfNeeded(now: 0) == nil)
        subject.appendLiveSegment(index: 899, startSeconds: 1798, durationSeconds: 2)
        #expect(subject.liveSuccessorIfNeeded(now: 0) == nil)
        let successor = try #require(subject.liveSuccessorIfNeeded(
            now: VideoSegmentProvider.liveCapacityStallSeconds))
        let snapshot = successor.notePlaylistBuild()
        #expect(snapshot.visibleCount - snapshot.firstVisible <= LiveWindowSizing.maxWindowSegments)
        #expect(snapshot.firstVisible > 3)
        #expect(subject.notePlaylistBuild().firstVisible <= 3)
    }

    @Test func diskAllowanceTriggersRejoinBeforeThePlaylistCap() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10,
                                 retentionBudgetBytes: 8_000)
        defer { cache.close() }
        let subject = provider(cache: cache, budget: 8_000)
        cache.declareTarget(2)
        for index in 0..<8 {
            cache.store(index: index, data: Data(repeating: 0, count: 1_000))
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        #expect(cache.totalBytes <= 8_000)
        #expect(subject.liveResidentParkCap() == 8)
        #expect(subject.liveSuccessorIfNeeded(now: 0) == nil)
        let successor = try #require(subject.liveSuccessorIfNeeded(
            now: VideoSegmentProvider.liveCapacityStallSeconds))
        let snapshot = successor.notePlaylistBuild()
        #expect(snapshot.visibleCount - snapshot.firstVisible <= 8)
        #expect(snapshot.visibleCount - snapshot.firstVisible <= 4)
        cache.declareTarget(snapshot.firstVisible + 1)
        successor.completeLiveHandoff()
        #expect(cache.count <= 4)
        #expect(successor.liveSuccessorIfNeeded() == nil)
        #expect(subject.notePlaylistBuild().firstVisible <= 3)
    }

    @Test func laterArrivalCadenceGetsAFreshPlaylistIdentity() throws {
        let measured = AtomicDouble(0.9)
        let cadence = LiveCadencePolicy(
            observe: { measured.get() }, cutTargetSeconds: 0.5,
            observeSealEvidence: { LiveCadenceEvidence(
                closedCadenceSeconds: measured.get(), servedSegmentDurationSeconds: nil) },
            clock: { 0 })
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache, cadence: cadence)
        for index in 0..<4 {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 0.9,
                                      durationSeconds: 0.9)
        }
        let oldServer = HLSLocalServer(provider: subject)
        try oldServer.start()
        defer { oldServer.stop() }
        #expect(target(HLSLocalServer.buildMediaPlaylistText(provider: subject)) == 1)
        measured.set(3.1)
        subject.appendLiveSegment(index: 4, startSeconds: 3.6, durationSeconds: 0.9)
        let successor = try #require(subject.liveSuccessorIfNeeded())
        let freshServer = HLSLocalServer(provider: successor)
        try freshServer.start()
        defer { freshServer.stop() }
        #expect(freshServer.mediaPlaylistURL != oldServer.mediaPlaylistURL)
        #expect(target(HLSLocalServer.buildMediaPlaylistText(provider: subject)) == 1)
        #expect(target(HLSLocalServer.buildMediaPlaylistText(provider: successor)) == 3)
    }

    @Test func targetDurationRolloverKeepsTheRenderedGOPAndManifestPlacement() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 20,
                                 retentionBudgetBytes: 1 << 20)
        defer { cache.close() }
        let subject = provider(cache: cache, budget: 1 << 20)
        for index in 0..<40 {
            cache.store(index: index, data: Data(repeating: 0, count: 1_000))
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        cache.declareTarget(12)
        subject.noteLivePlayhead(atOutputSeconds: 14.5)
        let before = subject.notePlaylistBuild()
        #expect(before.firstVisible <= 6)
        _ = HLSLocalServer.buildMediaPlaylistText(provider: subject)
        subject.appendLiveSegment(index: 40, startSeconds: 80, durationSeconds: 4)
        let successor = try #require(subject.liveSuccessorIfNeeded())
        successor.armLiveRejoinStart(atOutputSeconds: 14.5)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: successor)
        #expect(target(playlist) == 4)
        #expect(playlist.contains("#EXT-X-START:TIME-OFFSET=2.500,PRECISE=YES"))
        #expect(cache.peekURL(index: 7) != nil)
    }

    @Test func fullCacheReclaimsFetchedPrefixWithoutReplacingAHealthyItem() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10,
                                 retentionBudgetBytes: 8_000)
        defer { cache.close() }
        let subject = provider(cache: cache, budget: 8_000)
        for index in 0..<8 {
            cache.store(index: index, data: Data(repeating: 0, count: 1_000))
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        cache.declareTarget(6)
        subject.noteLivePlayhead(atOutputSeconds: 10)
        #expect(subject.liveSuccessorIfNeeded() == nil)
        #expect(cache.count <= 6)
        #expect(subject.notePlaylistBuild().firstVisible <= 4)
        #expect(cache.peekURL(index: 5) != nil)
    }

    /// tvOS live start: the provider hands over ~40 segments at once against a 24 MiB allowance.
    /// The consumer drains them in real time; the item must keep its URL the whole way.
    @Test func startBurstDrainsOnTheSameItemWithinTheAllowance() {
        let budget = 24 << 20
        let segmentBytes = 1 << 20
        let burst = 40
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10, retentionBudgetBytes: budget)
        defer { cache.close() }
        let subject = provider(cache: cache, budget: budget)
        var produced = 0
        func produce() {
            while produced < burst, cache.count < subject.liveResidentParkCap() {
                cache.store(index: produced, data: Data(repeating: 0, count: segmentBytes))
                subject.appendLiveSegment(index: produced, startSeconds: Double(produced),
                                          durationSeconds: 1)
                produced += 1
            }
        }
        produce()
        var rotations = 0
        var lostSegments: [Int] = []
        var peakBytes = cache.totalBytes
        for consumer in 0..<burst {
            #expect(consumer < produced)
            if cache.peekURL(index: consumer) == nil { lostSegments.append(consumer) }
            cache.declareTarget(consumer)
            subject.noteLivePlayhead(atOutputSeconds: Double(consumer) + 0.5)
            let snapshot = subject.notePlaylistBuild()
            #expect(snapshot.firstVisible <= consumer)
            if subject.liveSuccessorIfNeeded() != nil { rotations += 1 }
            produce()
            peakBytes = max(peakBytes, cache.totalBytes)
        }
        #expect(produced == burst)
        #expect(rotations == 0)
        #expect(lostSegments.isEmpty)
        #expect(peakBytes <= budget)
    }

    @Test func fullCacheBehindAStoppedConsumerStillRejoins() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10,
                                 retentionBudgetBytes: 8_000)
        defer { cache.close() }
        let subject = provider(cache: cache, budget: 8_000)
        cache.declareTarget(2)
        for index in 0..<8 {
            cache.store(index: index, data: Data(repeating: 0, count: 1_000))
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 2,
                                      durationSeconds: 2)
        }
        #expect(subject.liveSuccessorIfNeeded(now: 100) == nil)
        #expect(subject.liveSuccessorIfNeeded(now: 100 + VideoSegmentProvider.liveCapacityStallSeconds - 1) == nil)
        _ = try #require(subject.liveSuccessorIfNeeded(now: 100 + VideoSegmentProvider.liveCapacityStallSeconds))
    }

    /// A pump parked on a full cache finalizes nothing; that must not read as the source going quiet
    /// (AE#446 would close the window with ENDLIST and swap the item, a rebuffer on a healthy channel).
    @Test func headroomParkDoesNotReadAsASourceOutage() {
        let now = Date()
        func provider(parkedFor park: TimeInterval?) -> (VideoSegmentProvider, SegmentCache) {
            let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
            let subject = self.provider(cache: cache)
            for index in 0..<4 {
                subject.appendLiveSegment(index: index, startSeconds: Double(index) * 0.9, durationSeconds: 0.9,
                                          finalizedAt: now.addingTimeInterval(-10))
            }
            cache.declareTarget(1)
            if let park { subject.noteLiveHeadroomPark(true, at: now.addingTimeInterval(-park)) }
            _ = HLSLocalServer.buildMediaPlaylistText(provider: subject)
            return (subject, cache)
        }
        let (quiet, quietCache) = provider(parkedFor: nil)
        defer { quietCache.close() }
        #expect(quiet.liveDeliveryStalled)

        let (parked, parkedCache) = provider(parkedFor: 9.5)
        defer { parkedCache.close() }
        #expect(parked.liveDeliveryStalled == false)
        #expect(parked.liveOutageEndlist == false)
        parked.noteLiveHeadroomPark(false, at: now)
        #expect(parked.liveDeliveryStalled == false)
        #expect(parked.liveOutageEndlist == false)
    }

    /// AVPlayer sends no segment request while a blocking reload is held, so holding one for the head
    /// while the producer is parked on a full cache starves a consumer with segments resident ahead.
    @Test func blockingReloadIsNotHeldWhileTheProducerIsParked() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let subject = provider(cache: cache)
        for index in 0..<4 {
            subject.appendLiveSegment(index: index, startSeconds: Double(index) * 0.9, durationSeconds: 0.9)
        }
        subject.noteLiveHeadroomPark(true)
        let started = Date()
        #expect(subject.waitForLiveSegment(index: 4, timeout: 3) == false)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

}
