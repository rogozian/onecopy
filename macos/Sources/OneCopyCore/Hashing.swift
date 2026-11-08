import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum FileHashing {
    public static let chunkBytes = 1024 * 1024

    // Cheap prefilter, NOT proof of equality. Two slices are checked; the final
    // results are also SHA-256 hashed and compared byte-by-byte.
    public static func quickFingerprint(_ url: URL, bytes: Int64,
                                        cancelled: () -> Bool = { false }) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let window = 64 * 1024
        let first = try file.read(upToCount: min(window, Int(bytes))) ?? Data()
        var hash: UInt64 = 14695981039346656037
        for byte in first { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        if bytes > Int64(window) {
            if cancelled() { throw ScanProblem.cancelled }
            try file.seek(toOffset: UInt64(bytes - Int64(window)))
            let last = try file.read(upToCount: window) ?? Data()
            for byte in last { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        }
        return String(format: "%016llx", hash)
    }

    public static func sha256(_ url: URL,
                              cancelled: () -> Bool = { false }) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        #if canImport(CryptoKit)
        var hasher = SHA256()
        #else
        var hasher = PortableSHA256()
        #endif
        while true {
            if cancelled() { throw ScanProblem.cancelled }
            let data = try file.read(upToCount: chunkBytes) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Definitive content comparison; names, extensions and hash equality are irrelevant.
    public static func byteEqual(_ first: URL, _ second: URL,
                                 cancelled: () -> Bool = { false }) throws -> Bool {
        let lhs = try FileHandle(forReadingFrom: first)
        defer { try? lhs.close() }
        let rhs = try FileHandle(forReadingFrom: second)
        defer { try? rhs.close() }
        while true {
            if cancelled() { throw ScanProblem.cancelled }
            let a = try lhs.read(upToCount: chunkBytes) ?? Data()
            let b = try rhs.read(upToCount: chunkBytes) ?? Data()
            if a != b { return false }
            if a.isEmpty { return true }
        }
    }
}

// Fallback for compiling and unit-testing the shared engine on Linux.
// On macOS the application uses Apple's optimized CryptoKit implementation.
#if !canImport(CryptoKit)
struct PortableSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    private var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    private var remainder = [UInt8]()
    private var count: UInt64 = 0
    private static func rot(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    mutating func update(data: Data) {
        count &+= UInt64(data.count)
        remainder.append(contentsOf: data)
        var offset = 0
        while remainder.count - offset >= 64 {
            process(Array(remainder[offset..<(offset+64)]))
            offset += 64
        }
        if offset > 0 { remainder.removeFirst(offset) }
    }

    private mutating func process(_ data: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = UInt32(data[j]) << 24 | UInt32(data[j+1]) << 16 | UInt32(data[j+2]) << 8 | UInt32(data[j+3])
        }
        for i in 16..<64 {
            let a = Self.rot(w[i-15],7) ^ Self.rot(w[i-15],18) ^ (w[i-15] >> 3)
            let b = Self.rot(w[i-2],17) ^ Self.rot(w[i-2],19) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ a &+ w[i-7] &+ b
        }
        var a=state[0], b=state[1], c=state[2], d=state[3]
        var e=state[4], f=state[5], g=state[6], h=state[7]
        for i in 0..<64 {
            let s1 = Self.rot(e,6) ^ Self.rot(e,11) ^ Self.rot(e,25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ choice &+ Self.constants[i] &+ w[i]
            let s0 = Self.rot(a,2) ^ Self.rot(a,13) ^ Self.rot(a,22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    mutating func finalize() -> [UInt8] {
        let bits = count &* 8
        var tail = remainder
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8((bits >> UInt64(shift)) & 0xff))
        }
        for i in stride(from: 0, to: tail.count, by: 64) { process(Array(tail[i..<(i+64)])) }
        return state.flatMap { n in [UInt8((n>>24)&0xff),UInt8((n>>16)&0xff),UInt8((n>>8)&0xff),UInt8(n&0xff)] }
    }
}
#endif
