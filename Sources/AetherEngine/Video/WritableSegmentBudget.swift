import Darwin
import Foundation

enum WritableSegmentBudget {
    static func probe(in directory: URL, limit: Int = 256 << 20) -> Int {
        let path = directory.appendingPathComponent("writable-probe-" + UUID().uuidString)
        let fd = open(path.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { return 0 }
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: path)
        }
        let chunk = [UInt8](repeating: 0xA7, count: 1 << 20)
        var total = 0
        chunk.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while total < limit {
                let n = write(fd, base, min(chunk.count, limit - total))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                total += n
            }
        }
        guard fsync(fd) == 0 else { return 0 }
        return total
    }
}
