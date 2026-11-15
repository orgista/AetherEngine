import Testing
import Foundation
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// A PGS track keeps `find_stream_info` reading until its first display set decodes. On DevPlus that
/// was 0.6-1.2 s of every 4K remux start (compare3, 2026-11-14): the trace showed the playback open
/// at `containerOpened` while the pass read 34-52 MB looking for the subtitle's size.
@Suite("Identified subtitle tracks and the stream-info probe")
struct IdentifiedSubtitleProbeTests {

    @Test("a subtitle track the container named needs no probe")
    func identifiedSubtitle() {
        #expect(Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE,
                                             codecType: AVMEDIA_TYPE_SUBTITLE))
        #expect(Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_SUBRIP,
                                             codecType: AVMEDIA_TYPE_SUBTITLE))
    }

    @Test("an unidentified subtitle track stays in the probe that would identify it")
    func unidentifiedSubtitle() {
        #expect(!Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_NONE,
                                              codecType: AVMEDIA_TYPE_SUBTITLE))
    }

    @Test("audio and video are out of scope", arguments: [AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO])
    func otherTypes(_ type: AVMediaType) {
        #expect(!Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecType: type))
    }

    /// Same file with and without a PGS track whose first display set comes after the audio. Before
    /// the park, the PGS file was read to its end (the size never resolves from junk) and the plain
    /// one stopped after the first cluster.
    @Test("a late PGS track costs the probe nothing")
    func latePGSDoesNotExtendTheProbe() throws {
        let plain = try reach(SparsePGSMatroska.make(seconds: 20, withPGS: false))
        let file = SparsePGSMatroska.make(seconds: 20, withPGS: true)
        #expect(file.count > 3_000_000)
        let withPGS = try reach(file)
        #expect(withPGS <= plain)
        #expect(withPGS < 1_000_000)
    }

    @Test("the parked PGS track is still listed as a subtitle")
    func parkedTrackIsListed() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: CountingReader(data: SparsePGSMatroska.make(seconds: 20, withPGS: true)),
                         formatHint: "matroska", profile: .playback)
        defer { demuxer.close() }
        let subtitle = try #require(demuxer.stream(at: 1)?.pointee.codecpar)
        #expect(subtitle.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE)
        #expect(subtitle.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
        #expect(demuxer.subtitleTrackInfos().map(\.id) == [1])
        #expect(demuxer.subtitleStreamIndices() == [1])
        let audio = try #require(demuxer.stream(at: 0)?.pointee.codecpar)
        #expect(audio.pointee.sample_rate == 48_000)
        #expect(audio.pointee.ch_layout.nb_channels == 2)
    }

    private func reach(_ data: Data) throws -> Int {
        let reader = CountingReader(data: data)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska", profile: .playback)
        defer { demuxer.close() }
        #expect(demuxer.audioStreamIndex == 0)
        return reader.highWaterMark
    }
}

/// Matroska with 16-bit stereo PCM in 100 ms clusters and, optionally, a PGS track whose only block
/// (junk, so its size never resolves) sits after all the audio. Sizes are 8-byte EBML vints, as in
/// `MatroskaSubtitleFixture`.
private enum SparsePGSMatroska {

    static func make(seconds: Int, withPGS: Bool) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3],
                             element([0x42, 0x82], string("matroska")) +
                             element([0x42, 0x87], uint(4)) +
                             element([0x42, 0x85], uint(2)))
        let info = element([0x15, 0x49, 0xA9, 0x66],
                           element([0x2A, 0xD7, 0xB1], uint(1_000_000)) +       // TimestampScale: 1 ms
                           element([0x44, 0x89], float64(Double(seconds * 1000))))

        let audio = element([0xAE],
                            element([0xD7], uint(1)) +                           // TrackNumber
                            element([0x73, 0xC5], uint(1)) +                     // TrackUID
                            element([0x83], uint(2)) +                           // TrackType: audio
                            element([0x86], string("A_PCM/INT/LIT")) +
                            element([0xE1],
                                    element([0xB5], float64(48_000)) +           // SamplingFrequency
                                    element([0x9F], uint(2)) +                   // Channels
                                    element([0x62, 0x64], uint(16))))            // BitDepth
        let pgs = element([0xAE],
                          element([0xD7], uint(2)) +
                          element([0x73, 0xC5], uint(2)) +
                          element([0x83], uint(0x11)) +                          // TrackType: subtitle
                          element([0x86], string("S_HDMV/PGS")))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], audio + (withPGS ? pgs : []))

        let pcm = [UInt8](repeating: 0, count: 48_000 / 10 * 4)
        var clusters: [UInt8] = []
        for ms in stride(from: 0, to: seconds * 1000, by: 100) {
            clusters += element([0x1F, 0x43, 0xB6, 0x75],
                                element([0xE7], uint(ms)) +
                                element([0xA3], [0x81, 0x00, 0x00, 0x80] + pcm))  // SimpleBlock, keyframe
        }
        if withPGS {
            clusters += element([0x1F, 0x43, 0xB6, 0x75],
                                element([0xE7], uint(seconds * 1000)) +
                                element([0xA3], [0x82, 0x00, 0x00, 0x80, 0x16, 0x00, 0x01, 0x00]))
        }
        return Data(header + element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters))
    }

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        var size: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8((payload.count >> shift) & 0xFF)) }
        return id + size + payload
    }

    private static func uint(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = v
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return bytes
    }

    private static func float64(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) }
    }

    private static func string(_ s: String) -> [UInt8] { Array(s.utf8) }
}
