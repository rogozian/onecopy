import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum ScanProblem: LocalizedError {
    case cancelled
    case unsafeFolder(String)
    case fileChanged(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Проверка остановлена. Файлы не изменены."
        case .unsafeFolder(let path): return "Системная или защищённая папка: \(path)"
        case .fileChanged(let path): return "Файл изменился с момента сканирования: \(path)"
        }
    }
}

public struct FileRecord: Identifiable, Hashable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date
    public let physicalIdentity: String?
    public let linkCount: UInt64
    public let changeStamp: String
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var folder: String { url.deletingLastPathComponent().path }

    public static func snapshot(_ url: URL) throws -> FileRecord? {
        // lstat does NOT dereference a symlink. Protect even when a caller bypasses
        // the enumerator and passes a direct URL to a link.
        var info = stat()
        let ok: Int32 = url.path.withCString { lstat($0, &info) }
        guard ok == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.int64Value,
              let date = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(info.st_dev):\(info.st_ino)"
        #if os(macOS)
        let changed = "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        #else
        let changed = "\(info.st_ctim.tv_sec):\(info.st_ctim.tv_nsec)"
        #endif
        return FileRecord(url: url, bytes: size, modified: date,
                          physicalIdentity: identity, linkCount: UInt64(info.st_nlink),
                          changeStamp: changed)
    }

    public func stillMatchesDisk() -> Bool {
        guard let now = try? FileRecord.snapshot(url) else { return false }
        return now.bytes == bytes && now.modified == modified
            && now.physicalIdentity == physicalIdentity
            && now.linkCount == linkCount && now.changeStamp == changeStamp
    }

}

public struct DuplicateGroup: Identifiable {
    public let id: String
    public let digest: String
    public let files: [FileRecord]
    public let assessment: CleanupAssessment
    public var canClean: Bool { assessment.canTrash }
    public var reclaimableBytes: Int64 { Int64(max(0, files.count - 1)) * (files.first?.bytes ?? 0) }
    public var copyCount: Int { files.count }
}

public struct ScanReport {
    public let groups: [DuplicateGroup]
    public let examinedFiles: Int
    public let skippedFiles: Int
    public let issues: [String]
    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
}

public enum FolderProtection {
    private static let topLevelSystem: [String] = ["/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/dev", "/etc", "/var"]
    private static let excludedNames: Set<String> = [
        ".Trash", ".Trashes", ".git", "node_modules", ".Spotlight-V100", ".fseventsd",
        "CloudStorage", "Mobile Documents", "OneCopy", "Photos Library.photoslibrary"
    ]
    private static let packageSuffixes: [String] = [
        ".app", ".bundle", ".framework", ".photoslibrary", ".photolibrary", ".fcpbundle",
        ".fcpevent", ".imovielibrary", ".logicx", ".band", ".pages", ".numbers", ".key"
    ]

    public static func prohibited(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == "/" { return true }
        for dir in topLevelSystem {
            if path == dir || path.hasPrefix(dir + "/") { return true }
        }
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        if path == homeLibrary || path.hasPrefix(homeLibrary + "/") { return true }
        if path.split(separator: "/").contains(where: { part in
            let name = String(part)
            return excludedNames.contains(name) || packageSuffixes.contains(where: { name.lowercased().hasSuffix($0) })
        }) { return true }
        return false
    }

    public static func cloudLikePath(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
    }
}

public final class DuplicateScanner {
    public init() {}

    public func scan(folders: [URL],
                     progress: @escaping (String) -> Void = { _ in },
                     cancelled: @escaping () -> Bool = { false }) throws -> ScanReport {
        var files: [FileRecord] = []
        var issues: [String] = []
        var seenPaths = Set<String>()
        var seenInodes = Set<String>()
        var skipped = 0
        let fm = FileManager.default
        var didScanRoot = Set<String>()

        for root in folders {
            if cancelled() { throw ScanProblem.cancelled }
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            if !didScanRoot.insert(resolvedRoot.path).inserted { continue }
            if FolderProtection.prohibited(resolvedRoot) {
                issues.append("Пропущена защищённая папка: \(resolvedRoot.path)")
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                issues.append("Не найдена папка: \(resolvedRoot.path)")
                continue
            }
            progress("Читаем: \(resolvedRoot.lastPathComponent)")
            guard let enumerator = fm.enumerator(at: resolvedRoot,
                                                  includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { url, error in
                issues.append("Нет доступа: \(url.lastPathComponent) — \(error.localizedDescription)")
                return true
            }) else { continue }
            for case let url as URL in enumerator {
                if cancelled() { throw ScanProblem.cancelled }
                if FolderProtection.prohibited(url) {
                    enumerator.skipDescendants()
                    skipped += 1
                    continue
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); skipped += 1; continue }
                    if values.isDirectory == true { continue }
                    guard values.isRegularFile == true else { skipped += 1; continue }
                    // Never hash a known iCloud/File Provider placeholder or remote-volume file.
                    if !CleanupSafety.canReadLocally(url) {
                        skipped += 1
                        issues.append("Облачный, сетевой или неопределённый файл пропущен: \(url.path)")
                        continue
                    }
                    guard let record = try FileRecord.snapshot(url) else { skipped += 1; continue }
                    if !seenPaths.insert(record.url.path).inserted { continue }
                    // Hard links to the SAME inode do not represent separate disk content.
                    if let identity = record.physicalIdentity, !seenInodes.insert(identity).inserted { continue }
                    files.append(record)
                } catch { skipped += 1; issues.append("Ошибка чтения \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        progress("Проверяем размеры: \(files.count) файлов")
        let sizeBuckets = Dictionary(grouping: files, by: { $0.bytes }).values.filter { $0.count > 1 }
        var candidates: [(FileRecord, String)] = []
        for bucket in sizeBuckets {
            for file in bucket {
                if cancelled() { throw ScanProblem.cancelled }
                do {
                    guard file.stillMatchesDisk() else { throw ScanProblem.fileChanged(file.url.path) }
                    let quick = try FileHashing.quickFingerprint(file.url, bytes: file.bytes, cancelled: cancelled)
                    candidates.append((file, "\(file.bytes):\(quick)"))
                } catch ScanProblem.cancelled { throw ScanProblem.cancelled }
                catch { skipped += 1; issues.append("Пропущен \(file.name): \(error.localizedDescription)") }
            }
        }
        let quickBuckets = Dictionary(grouping: candidates, by: { $0.1 }).values.filter { $0.count > 1 }
        var hashed: [(FileRecord, String)] = []
        var index = 0
        let total = quickBuckets.reduce(0) { $0 + $1.count }
        for bucket in quickBuckets {
            for (file, _) in bucket {
                if cancelled() { throw ScanProblem.cancelled }
                index += 1
                progress("Сверяем содержимое: \(index) из \(total) — \(file.name)")
                do {
                    guard file.stillMatchesDisk() else { throw ScanProblem.fileChanged(file.url.path) }
                    let digest = try FileHashing.sha256(file.url, cancelled: cancelled)
                    guard file.stillMatchesDisk() else { throw ScanProblem.fileChanged(file.url.path) }
                    hashed.append((file,digest))
                } catch ScanProblem.cancelled { throw ScanProblem.cancelled }
                catch { skipped += 1; issues.append("Пропущен \(file.name): \(error.localizedDescription)") }
            }
        }
        let digestBuckets = Dictionary(grouping: hashed, by: { $0.1 }).values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        for bucket in digestBuckets {
            if cancelled() { throw ScanProblem.cancelled }
            // Never accept a hash collision as evidence. Check entire byte streams.
            var confirmed: [[FileRecord]] = []
            for (file, _) in bucket {
                do {
                    guard file.stillMatchesDisk() else { throw ScanProblem.fileChanged(file.url.path) }
                    var added = false
                    for idx in confirmed.indices {
                        let representative = confirmed[idx][0]
                        if !representative.stillMatchesDisk() { continue }
                        if try FileHashing.byteEqual(representative.url, file.url, cancelled: cancelled) {
                            confirmed[idx].append(file)
                            added = true
                            break
                        }
                    }
                    if !added { confirmed.append([file]) }
                } catch ScanProblem.cancelled { throw ScanProblem.cancelled }
                catch { skipped += 1; issues.append("Не подтверждено \(file.name): \(error.localizedDescription)") }
            }
            for items in confirmed where items.count > 1 {
                let sorted = items.sorted { a,b in
                    let aScore = a.name.count + a.url.path.count
                    let bScore = b.name.count + b.url.path.count
                    return aScore == bScore ? a.url.path < b.url.path : aScore < bScore
                }
                let digest = bucket[0].1
                // All-or-nothing: one risky file disables bulk cleanup of the group.
                let keeper = sorted[0]
                let checks = sorted.dropFirst().map { CleanupSafety.assess(keeper: keeper, candidate: $0) }
                let blocked = checks.contains { $0.status == .protected }
                let review = checks.contains { $0.status == .review }
                let status: CleanupStatus = blocked ? .protected : (review ? .review : .ready)
                let reasons = Array(Set(checks.flatMap(\.reasons))).sorted()
                groups.append(DuplicateGroup(
                    id: digest + ":" + (sorted.first?.url.path ?? ""), digest: digest,
                    files: sorted, assessment: CleanupAssessment(status: status, reasons: reasons)
                ))
            }
        }
        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        progress("Готово: \(groups.count) групп совпадений")
        return ScanReport(groups: groups, examinedFiles: files.count, skippedFiles: skipped, issues: issues)
    }

    /// Always run immediately before moving one candidate to Trash.
    public static func safeToTrash(keeper: FileRecord, candidate: FileRecord) throws -> Bool {
        return try CleanupSafety.finalCheck(keeper: keeper, candidate: candidate)
    }
}
