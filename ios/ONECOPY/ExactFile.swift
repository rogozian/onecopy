import Foundation
import CryptoKit

/// Reads files in bounded memory. No automatic modifications or network requests.
enum ExactFile {
    private static let chunk = 1_048_576

    static func hash(_ url: URL) throws -> (size: Int64, digest: String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var h = SHA256()
        var count: Int64 = 0
        while true {
            let data = try file.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            h.update(data: data)
            count += Int64(data.count)
        }
        return (count, h.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func equals(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let a = try FileHandle(forReadingFrom: lhs)
        defer { try? a.close() }
        let b = try FileHandle(forReadingFrom: rhs)
        defer { try? b.close() }
        while true {
            let x = try a.read(upToCount: chunk) ?? Data()
            let y = try b.read(upToCount: chunk) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }
}
