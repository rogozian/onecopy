import Foundation
import Photos
import CryptoKit

struct PhotoGroup: Identifiable {
    let id: String
    let items: [PHAsset]
    let mediaType: PHAssetMediaType
    let digest: String
}

struct PhotoScanReport {
    var groups: [PhotoGroup] = []
    var totalAssets = 0
    var candidates = 0
    var skippedComplex = 0
    var skippedUnavailable = 0
}

/// Conservative Photos workflow:
/// * only single-resource, unmodified normal image/video assets;
/// * skips favorites, hidden, burst, Live Photos, edited assets and shared/synced sources;
/// * never downloads original media from iCloud;
/// * identifies byte-identical ORIGINAL media, not interchangeable metadata;
/// * rechecks bytes directly before user-confirmed Photos deletion.
enum PhotoScanner {
    private static let manager = PHAssetResourceManager.default()

    static func singleResource(_ asset: PHAsset) -> PHAssetResource? {
        guard asset.sourceType.contains(.typeUserLibrary),
              !asset.isHidden,
              asset.burstIdentifier == nil,
              !asset.mediaSubtypes.contains(.photoLive),
              asset.mediaType == .image || asset.mediaType == .video
        else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first else { return nil }
        if asset.mediaType == .image && resource.type != .photo { return nil }
        if asset.mediaType == .video && resource.type != .video { return nil }
        return resource
    }

    static func scan(progress: @escaping (Int, Int) -> Void) -> PhotoScanReport {
        var report = PhotoScanReport()
        let fetch = PHAsset.fetchAssets(with: nil)
        report.totalAssets = fetch.count
        var buckets: [String: [PHAsset]] = [:]
        fetch.enumerateObjects { asset, _, _ in
            guard singleResource(asset) != nil else {
                report.skippedComplex += 1
                return
            }
            // This is only an optimization. Full hashes and byte checks follow.
            let durationMillis = Int64((asset.duration * 1000).rounded())
            let key = "\(asset.mediaType.rawValue):\(asset.pixelWidth):\(asset.pixelHeight):\(durationMillis)"
            buckets[key, default: []].append(asset)
        }
        let possible = buckets.values.filter { $0.count > 1 }.flatMap { $0 }
        report.candidates = possible.count
        var fingerprints: [String: [(PHAsset, PHAssetResource)]] = [:]
        for (i, asset) in possible.enumerated() {
            defer { progress(i + 1, possible.count) }
            guard let resource = singleResource(asset), let data = digest(resource) else {
                report.skippedUnavailable += 1
                continue
            }
            let key = "\(asset.mediaType.rawValue):\(resource.type.rawValue):\(resource.uniformTypeIdentifier):\(data.size):\(data.sha)"
            fingerprints[key, default: []].append((asset, resource))
        }
        // SHA-256 is not a mathematical proof of equality. Before we display
        // 'exact duplicate', compare the full original resource bytes too.
        for (fingerprint, pairs) in fingerprints where pairs.count > 1 {
            var verified: [[PHAsset]] = []
            for (asset, resource) in pairs {
                var inserted = false
                for index in verified.indices {
                    guard let representative = verified[index].first,
                          let repResource = singleResource(representative) else { continue }
                    if (try? exactOriginalBytesEqual(repResource, resource)) == true {
                        verified[index].append(asset)
                        inserted = true
                        break
                    }
                }
                if !inserted { verified.append([asset]) }
            }
            for group in verified where group.count > 1 {
                let ordered = group.sorted {
                    ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture)
                }
                let uid = ordered.map(\.localIdentifier).sorted().joined(separator: "|")
                report.groups.append(PhotoGroup(id: uid, items: ordered,
                                                mediaType: ordered[0].mediaType,
                                                digest: fingerprint.components(separatedBy: ":").last ?? ""))
            }
        }
        report.groups.sort { $0.items.count > $1.items.count }
        return report
    }

    /// Streams an original resource: memory stays bounded even for big videos.
    private static func digest(_ resource: PHAssetResource) -> (size: Int64, sha: String)? {
        final class Holder {
            let lock = NSLock()
            var hash = SHA256()
            var count: Int64 = 0
            var completed = false
            var error: Error?
            func append(_ chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                guard !completed else { return }
                hash.update(data: chunk)
                count += Int64(chunk.count)
            }
            func finish(_ err: Error?) {
                lock.lock(); defer { lock.unlock() }
                completed = true
                error = err
            }
            func result() -> (size: Int64, sha: String)? {
                lock.lock(); defer { lock.unlock() }
                guard completed, error == nil else { return nil }
                return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
            }
        }
        let holder = Holder()
        let semaphore = DispatchSemaphore(value: 0)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let request = manager.requestData(for: resource, options: options, dataReceivedHandler: {
            holder.append($0)
        }, completionHandler: { error in
            holder.finish(error)
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + 180) == .timedOut {
            manager.cancelDataRequest(request)
            return nil
        }
        return holder.result()
    }

    /// For a proof stronger than SHA-256, compare the actual bytes of the two
    /// original resources. Temporary files are always removed afterwards.
    /// May fail on large videos when temporary disk capacity is insufficient.
    static func exactOriginalBytesEqual(_ left: PHAssetResource, _ right: PHAssetResource) throws -> Bool {
        guard left.type == right.type && left.uniformTypeIdentifier == right.uniformTypeIdentifier else {
            return false
        }
        let base = FileManager.default.temporaryDirectory
        let one = base.appendingPathComponent("onecopy-\(UUID().uuidString).tmp")
        let two = base.appendingPathComponent("onecopy-\(UUID().uuidString).tmp")
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
        }
        try exportWithoutNetwork(left, to: one)
        try exportWithoutNetwork(right, to: two)
        return try ExactFile.equals(one, two)
    }

    private static func exportWithoutNetwork(_ resource: PHAssetResource, to url: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let lock = NSLock()
        var completionError: Error?
        var finished = false
        manager.writeData(for: resource, toFile: url, options: options) { err in
            lock.lock()
            completionError = err
            finished = true
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 240) == .success else {
            throw ScanIssue.timeout
        }
        lock.lock()
        let err = completionError
        let done = finished
        lock.unlock()
        guard done else { throw ScanIssue.timeout }
        if let err { throw err }
    }

    static func verifyBeforeDeletion(keeperID: String, removeIDs: [String]) throws -> [PHAsset] {
        guard Set(removeIDs).count == removeIDs.count && !removeIDs.contains(keeperID) else { throw ScanIssue.modified }
        let ids = [keeperID] + removeIDs
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        guard byID.count == ids.count, let keeper = byID[keeperID],
              let original = singleResource(keeper) else { throw ScanIssue.modified }
        var verified: [PHAsset] = []
        for id in removeIDs {
            guard id != keeperID, let candidate = byID[id],
                  let resource = singleResource(candidate),
                  !candidate.isFavorite,
                  candidate.mediaType == keeper.mediaType,
                  candidate.pixelWidth == keeper.pixelWidth,
                  candidate.pixelHeight == keeper.pixelHeight,
                  Int64((candidate.duration * 1000).rounded()) == Int64((keeper.duration * 1000).rounded())
            else { throw ScanIssue.modified }
            guard try exactOriginalBytesEqual(original, resource) else { throw ScanIssue.modified }
            verified.append(candidate)
        }
        guard !verified.isEmpty else { throw ScanIssue.modified }
        return verified
    }
}

enum ScanIssue: LocalizedError {
    case timeout, modified
    var errorDescription: String? {
        switch self {
        case .timeout: return "Слишком долгое чтение или файл недоступен локально. Ничего не удалено."
        case .modified: return "Файлы изменились, исчезли или больше не совпадают. Ничего не удалено."
        }
    }
}
