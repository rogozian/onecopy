import Foundation
import OneCopyPlatform
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// IMPORTANT: These states are intentionally conservative. "ready" is NOT a
/// statement that a third-party application does not refer to this exact path.
public enum CleanupStatus: String, Codable {
    case ready
    case review
    case protected
}

public struct CleanupAssessment {
    public let status: CleanupStatus
    public let reasons: [String]
    public var canTrash: Bool { status == .ready }

    public static let ready = CleanupAssessment(status: .ready, reasons: [])
}

/// Fail-closed macOS preflight. All versions still require the user to select
/// a group explicitly, and the OS Trash operation remains reversible.
public enum CleanupSafety {
    /// Call before hashing: accessing a placeholder can initiate a cloud download.
    /// A failed or ambiguous check is excluded rather than assumed to be local.
    public static func canReadLocally(_ url: URL) -> Bool {
        if FolderProtection.prohibited(url) || FolderProtection.cloudLikePath(url) { return false }
        #if os(macOS)
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .volumeIsLocalKey, .isSymbolicLinkKey
        ]) else { return false }
        return values.isUbiquitousItem != true && values.volumeIsLocal == true
            && values.isSymbolicLink != true
        #else
        return true
        #endif
    }

    public static func assess(keeper: FileRecord, candidate: FileRecord) -> CleanupAssessment {
        var protected: [String] = []
        var review: [String] = []

        if keeper.url.standardizedFileURL == candidate.url.standardizedFileURL {
            protected.append("Совпадает путь")
        }
        for file in [keeper, candidate] {
            if FolderProtection.prohibited(file.url) {
                protected.append("Защищённое расположение: \(file.name)")
            }
            if !file.stillMatchesDisk() {
                protected.append("Файл изменился с момента сканирования: \(file.name)")
            }
            if file.linkCount != 1 {
                protected.append("Жёсткие ссылки или неизвестное число ссылок: \(file.name)")
            }
        }
        if keeper.physicalIdentity == nil || candidate.physicalIdentity == nil {
            protected.append("Не удалось установить идентичность файловой системы")
        } else if keeper.physicalIdentity == candidate.physicalIdentity {
            protected.append("Это два имени одного inode, а не независимые копии")
        }
        if keeper.bytes != candidate.bytes {
            protected.append("Разные размеры файлов")
        }

        if !protected.isEmpty {
            return CleanupAssessment(status: .protected, reasons: Array(Set(protected)).sorted())
        }
        do {
            let a = try inspect(keeper.url)
            let b = try inspect(candidate.url)
            if a.cloud || b.cloud { protected.append("Облачный файл или File Provider: автоматическая очистка запрещена") }
            if !a.local || !b.local { protected.append("Сетевой или не локальный том") }
            if a.hasACL || b.hasACL { protected.append("У файла есть ACL: проверьте права и связи вручную") }
            if a.immutable || b.immutable { protected.append("Файл защищён от изменения") }
            if a.mode != b.mode { review.append("Отличаются POSIX-права") }
            if a.owner != b.owner || a.group != b.group { review.append("Отличаются владелец или группа") }
            let xattrResult = keeper.url.path.withCString { pathA in
                candidate.url.path.withCString { pathB in oc_compare_xattrs(pathA, pathB) }
            }
            if xattrResult == 0 { review.append("Отличаются расширенные атрибуты macOS (теги Finder, resource fork и др.)") }
            if xattrResult == -1 { protected.append("Не удалось прочитать все расширенные атрибуты") }
            if xattrResult == -2 { protected.append("Слишком большой расширенный атрибут / resource fork") }
            if a.hiddenExtension != b.hiddenExtension { review.append("Отличается настройка скрытия расширения") }
            // Creation dates often legitimately differ on a renamed/copy downloaded later.
            // We leave them untouched on the remaining copy; they don't prove replacement.
        } catch {
            protected.append("Не удалось достоверно проверить метаданные: \(error.localizedDescription)")
        }
        if !protected.isEmpty { return CleanupAssessment(status: .protected, reasons: Array(Set(protected)).sorted()) }
        if !review.isEmpty { return CleanupAssessment(status: .review, reasons: Array(Set(review)).sorted()) }
        return .ready
    }

    public static func inspect(_ url: URL) throws -> FileMetadata {
        guard !FolderProtection.prohibited(url) else { throw SafetyError.protectedPath }
        guard let record = try FileRecord.snapshot(url), record.linkCount == 1 else {
            throw SafetyError.notRegularOrLinked
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value,
              let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
              let group = (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value else {
            throw SafetyError.missingMetadata
        }
        let immutable = (attrs[.immutable] as? NSNumber)?.boolValue ?? false
        let appendOnly = (attrs[.appendOnly] as? NSNumber)?.boolValue ?? false
        let hiddenExtension = (attrs[.extensionHidden] as? NSNumber)?.boolValue ?? false
        #if os(macOS)
        let v = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .volumeIsLocalKey,
            .isSymbolicLinkKey
        ])
        if v.isSymbolicLink == true { throw SafetyError.notRegularOrLinked }
        // Even fully downloaded iCloud items can sync a deletion to other devices.
        let cloud = v.isUbiquitousItem == true || v.ubiquitousItemHasUnresolvedConflicts == true
            || FolderProtection.cloudLikePath(url)
        let local = v.volumeIsLocal == true
        let aclStatus = url.path.withCString { oc_extended_acl_status($0) }
        guard aclStatus >= 0 else { throw SafetyError.acl }
        let acl = aclStatus == 1
        #else
        let cloud = FolderProtection.cloudLikePath(url)
        let local = true
        let acl = false
        #endif
        return FileMetadata(mode: mode, owner: owner, group: group,
                            hasACL: acl, cloud: cloud, local: local,
                            immutable: immutable || appendOnly, hiddenExtension: hiddenExtension)
    }

    /// Reassess metadata before and after an exhaustive byte comparison.
    /// A file can STILL be modified by another process in the final interval
    /// between this check and Finder's trash operation. Never claim atomicity.
    public static func finalCheck(keeper: FileRecord, candidate: FileRecord) throws -> Bool {
        guard assess(keeper: keeper, candidate: candidate).canTrash else { return false }
        guard try FileHashing.byteEqual(keeper.url, candidate.url) else { return false }
        return assess(keeper: keeper, candidate: candidate).canTrash
            && keeper.stillMatchesDisk() && candidate.stillMatchesDisk()
    }
}

public enum SafetyError: LocalizedError {
    case protectedPath, notRegularOrLinked, missingMetadata, extendedAttribute, acl
    public var errorDescription: String? {
        switch self {
        case .protectedPath: return "Запрещённое расположение"
        case .notRegularOrLinked: return "Необычный тип файла или жёсткая ссылка"
        case .missingMetadata: return "Неизвестные права или владелец"
        case .extendedAttribute: return "Не удалось прочитать все расширенные атрибуты"
        case .acl: return "Не удалось проверить ACL"
        }
    }
}

public struct FileMetadata: Equatable {
    public let mode: UInt32
    public let owner: UInt32
    public let group: UInt32
    public let hasACL: Bool
    public let cloud: Bool
    public let local: Bool
    public let immutable: Bool
    public let hiddenExtension: Bool
}

