import Foundation

/// Disk bound for an opt-in whole-source prefetch (#207).
///
/// `SegmentCache.pruneOutsideWindow` never evicts the hard window, so the retention budget bounds only
/// what lives outside it. That is correct for the historical windows (10 segments ~ 100 MB, the 150
/// ceiling ~ 1.5 GB), which fit under the budget by construction. A host that opts into buffering a
/// whole film (`LoadOptions.forwardBufferSegments`) makes the window itself the dominant footprint, and
/// nothing would stop it from filling the volume: a failed segment write degrades to a cache miss and
/// stalls playback, which is the exact failure the option exists to prevent.
///
/// So the producer parks once the window's own bytes reach the budget. Eviction of the extras behind
/// the playhead frees room as playback advances, which releases the park, so the prefetch tracks the
/// budget instead of the source length. Sessions that never opt in never reach the condition.
enum PrefetchDiskBudget {

    /// Segments the producer may always run ahead of the consumer, budget or not. The consumer's target
    /// is AVPlayer's newest fetch, so this lead sits on top of what AVPlayer already buffered. It used to
    /// be the historical forward window (10), which made the park unreachable for every default session:
    /// a 4K remux at ~30-50 MB a segment then wrote ~500 MB ahead on a volume with ~130 MB free, a
    /// segment write failed with ENOSPC and the session died (DevTV, 2026-11-08). Two keeps one segment
    /// in production while the next waits, so one slow segment never reaches the player.
    static let minAheadSegments = 2

    /// - Parameters:
    ///   - forwardBytes: on-disk bytes at or above the consumer's target (`SegmentCache.forwardBytes`),
    ///     i.e. what the producer's race-ahead owns. History behind the playhead is excluded: the
    ///     extras eviction already bounds it, and counting it would throttle a standard session.
    ///   - budgetBytes: the session retention budget; 0 (live) never parks.
    ///   - head: segment index the producer is about to write.
    ///   - consumerTarget: the consumer's last declared fetch index (`SegmentCache.targetIndex`).
    static func shouldPark(forwardBytes: Int,
                           budgetBytes: Int,
                           head: Int,
                           consumerTarget: Int,
                           minAheadSegments: Int = minAheadSegments) -> Bool {
        guard budgetBytes > 0, forwardBytes >= budgetBytes else { return false }
        return head - consumerTarget >= minAheadSegments
    }
}
