import Foundation

struct FolderDuplicateGroup: Identifiable {
    let id: String
    let files: [URL]
    let bytesPerFile: Int64
}

struct FolderScanReport {
    var groups: [FolderDuplicateGroup] = []
    var enumerated = 0
    var skipped = 0
}

/// Selected Files folder: read-only. File Provider files may be remote;
/// reject iCloud items and files on volumes not reported as local.
enum FolderScanner {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .fileSizeKey, .isUbiquitousItemKey, .volumeIsLocalKey,
        .contentModificationDateKey
    ]

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: Date?
    }

    /// Scan all user-authorized folders as ONE set, so duplicates located
    /// in different selected folders can also be found. Never escape the
    /// security scopes supplied by UIDocumentPickerViewController.
    static func scan(_ folder: URL) throws -> FolderScanReport {
        try scan([folder])
    }

    static func scan(_ folders: [URL]) throws -> FolderScanReport {
        guard !folders.isEmpty else { throw FolderError.unavailable }
        var report = FolderScanReport()
        var bySize: [Int64: [URL]] = [:]
        var visited: Set<String> = []

        for folder in folders {
            guard let e = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    report.skipped += 1
                    return true
                }
            ) else {
                report.skipped += 1
                continue
            }
            for case let item as URL in e {
                guard let v = try? item.resourceValues(forKeys: keys) else {
                    report.skipped += 1
                    continue
                }
                if v.isSymbolicLink == true || v.isPackage == true {
                    e.skipDescendants()
                    report.skipped += 1
                    continue
                }
                if v.isRegularFile != true { continue }
                let identity = item.standardizedFileURL.path
                guard visited.insert(identity).inserted else { continue }
                report.enumerated += 1
                guard v.isUbiquitousItem != true,
                      v.volumeIsLocal == true,
                      let size = v.fileSize else {
                    report.skipped += 1
                    continue
                }
                bySize[Int64(size), default: []].append(item)
            }
        }
        for (size, matches) in bySize where matches.count > 1 {
            var hashed: [String: [URL]] = [:]
            for url in matches {
                guard let before = snapshot(url),
                      before.size == size,
                      let digest = coordinatedHash(url),
                      digest.size == size,
                      let after = snapshot(url), after == before else {
                    report.skipped += 1
                    continue
                }
                hashed[digest.digest, default: []].append(url)
            }
            for (fingerprint, options) in hashed where options.count > 1 {
                var proven: [[URL]] = []
                for url in options {
                    var joined = false
                    for idx in proven.indices {
                        guard let rep = proven[idx].first,
                              snapshot(rep) != nil, snapshot(url) != nil else { continue }
                        if coordinatedEquals(rep, url) == true {
                            proven[idx].append(url)
                            joined = true
                            break
                        }
                    }
                    if !joined { proven.append([url]) }
                }
                for group in proven where group.count > 1 {
                    let sorted = group.sorted { $0.path < $1.path }
                    report.groups.append(FolderDuplicateGroup(
                        id: "\(fingerprint)-\(sorted[0].path)", files: sorted, bytesPerFile: size))
                }
            }
        }
        report.groups.sort { $0.files.count > $1.files.count }
        return report
    }

    private static func snapshot(_ url: URL) -> Snapshot? {
        guard let v = try? url.resourceValues(forKeys: keys),
              v.isRegularFile == true, v.isSymbolicLink != true,
              v.isUbiquitousItem != true, v.volumeIsLocal == true,
              let size = v.fileSize else { return nil }
        return Snapshot(size: Int64(size), modified: v.contentModificationDate)
    }

    private static func coordinatedHash(_ file: URL) -> (size: Int64, digest: String)? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: (size: Int64, digest: String)?
        coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { readable in
            result = try? ExactFile.hash(readable)
        }
        return coordinationError == nil ? result : nil
    }

    private static func coordinatedEquals(_ a: URL, _ b: URL) -> Bool? {
        guard let beforeA = snapshot(a), let beforeB = snapshot(b) else { return nil }
        let coordinatorA = NSFileCoordinator(filePresenter: nil)
        let coordinatorB = NSFileCoordinator(filePresenter: nil)
        var errorA: NSError?
        var errorB: NSError?
        var equal: Bool?
        // NSFileCoordinator does not provide a two-reading-item overload.
        // Nested read coordination keeps both resources under read access.
        coordinatorA.coordinate(readingItemAt: a, options: [], error: &errorA) { readableA in
            coordinatorB.coordinate(readingItemAt: b, options: [], error: &errorB) { readableB in
                equal = try? ExactFile.equals(readableA, readableB)
            }
        }
        guard errorA == nil, errorB == nil,
              snapshot(a) == beforeA, snapshot(b) == beforeB else { return nil }
        return equal
    }
}

enum FolderError: LocalizedError {
    case unavailable, permission
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Не удалось открыть содержимое папки."
        case .permission: return "Доступ к выбранной папке отсутствует или отозван."
        }
    }
}
