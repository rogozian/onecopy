import XCTest
import Foundation
@testable import OneCopyCore
#if os(macOS)
import Darwin
#endif

final class DuplicateScannerTests: XCTestCase {
    var sandbox: URL!
    override func setUpWithError() throws {
        sandbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OneCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testSHA256Vectors() throws {
        let empty = try write("empty", "")
        let abc = try write("abc", "abc")
        XCTAssertEqual(try FileHashing.sha256(empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try FileHashing.sha256(abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRenamedExactCopiesOnly() throws {
        let a = try write("video_final.mp4", "a repeated byte stream")
        let b = try write("renamed.anything", "a repeated byte stream")
        _ = try write("almost_same.mp4", "A repeated byte stream")
        let result = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.url)), Set([a,b]))
        XCTAssertEqual(result.reclaimableBytes, Int64("a repeated byte stream".utf8.count))
    }

    func testEmptyFilesAreDuplicate() throws {
        _ = try write("empty.a", "")
        _ = try write("empty.b", "")
        let result = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.reclaimableBytes, 0)
    }

    func testChangedCandidateCannotBeApprovedForTrash() throws {
        let a = try write("a.txt", "same here")
        let b = try write("b.txt", "same here")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        let keeper = try XCTUnwrap(report.groups.first?.files.first(where: { $0.url == a }))
        let candidate = try XCTUnwrap(report.groups.first?.files.first(where: { $0.url == b }))
        XCTAssertTrue(try DuplicateScanner.safeToTrash(keeper: keeper, candidate: candidate))
        try Data("new text".utf8).write(to: b)
        XCTAssertFalse(try DuplicateScanner.safeToTrash(keeper: keeper, candidate: candidate))
    }

    func testHardLinksNotCountedTwice() throws {
        let a = try write("original.txt", "hard link sample")
        let b = sandbox.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: a, to: b)
        let report = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertTrue(report.groups.isEmpty)
    }

    func testHiddenFilesNotScanned() throws {
        _ = try write("visible.txt", "repeat")
        _ = try write(".hidden.txt", "repeat")
        let result = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(result.groups.count, 0)
    }

    func testLargeStreamingFile() throws {
        let url = sandbox.appendingPathComponent("large.bin")
        let data = Data(repeating: 0x42, count: 2_500_000)
        try data.write(to: url)
        let mirror = sandbox.appendingPathComponent("renamed-video.mp4")
        try FileManager.default.copyItem(at: url, to: mirror)
        let result = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.reclaimableBytes, 2_500_000)
    }

    func testSingleByteDifferenceDoesNotMatch() throws {
        _ = try write("a", "12345")
        _ = try write("b", "12346")
        XCTAssertTrue(try DuplicateScanner().scan(folders: [sandbox]).groups.isEmpty)
    }

    func testProtectedSystemRootRejected() {
        XCTAssertTrue(FolderProtection.prohibited(URL(fileURLWithPath: "/System")))
        XCTAssertTrue(FolderProtection.prohibited(URL(fileURLWithPath: "/")))
    }
    func testRegularCopiesAdmittedWhenMetadataMatches() throws {
        let first = try write("original.data", "one payload")
        let second = try write("different.name", "one payload")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.assessment.status, .ready)
        let a = try XCTUnwrap(group.files.first(where: { $0.url == first }))
        let b = try XCTUnwrap(group.files.first(where: { $0.url == second }))
        XCTAssertTrue(try DuplicateScanner.safeToTrash(keeper: a, candidate: b))
    }

    func testDifferentPermissionsBlockCleanupButStillShowContentMatch() throws {
        let first = try write("original.txt", "same content")
        let second = try write("copy.txt", "same content")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: second.path)
        let report = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].assessment.status, .review)
        let items = report.groups[0].files
        XCTAssertFalse(try DuplicateScanner.safeToTrash(keeper: items[0], candidate: items[1]))
    }

    func testHardLinkedKeeperBlocksDeletingOtherwiseIdenticalCopy() throws {
        let original = try write("original.txt", "exact duplicate")
        let linked = sandbox.appendingPathComponent("extra-hardlink")
        try FileManager.default.linkItem(at: original, to: linked)
        _ = try write("separate-copy.txt", "exact duplicate")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].assessment.status, .protected)
    }

    func testSymbolicLinkNeverApprovedOrCounted() throws {
        let original = try write("real.txt", "some text")
        let symlink = sandbox.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        _ = try write("copy.txt", "some text")
        XCTAssertNil(try FileRecord.snapshot(symlink))
        let report = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertEqual(report.groups.first?.files.count, 2)
    }

    func testReplacingScannedFileWithSameLengthIsRejected() throws {
        let original = try write("original", "aaaa")
        let copied = try write("copy", "aaaa")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        let first = try XCTUnwrap(report.groups[0].files.first(where: { $0.url == original }))
        let other = try XCTUnwrap(report.groups[0].files.first(where: { $0.url == copied }))
        let replacement = try write("replacement", "aaaa")
        try FileManager.default.removeItem(at: copied)
        try FileManager.default.moveItem(at: replacement, to: copied)
        XCTAssertFalse(try DuplicateScanner.safeToTrash(keeper: first, candidate: other))
    }

    func testMissingFileCannotBeDeleted() throws {
        let original = try write("original", "abcd")
        let copied = try write("copy", "abcd")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        let first = try XCTUnwrap(report.groups[0].files.first(where: { $0.url == original }))
        let other = try XCTUnwrap(report.groups[0].files.first(where: { $0.url == copied }))
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(try DuplicateScanner.safeToTrash(keeper: first, candidate: other))
    }

    func testSuspiciousPackagesNeverScanned() throws {
        let root = sandbox.appendingPathComponent("archive.photoslibrary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try write("outside.txt", "duplicate")
        let inside = root.appendingPathComponent("inside.txt")
        try Data("duplicate".utf8).write(to: inside)
        let report = try DuplicateScanner().scan(folders: [sandbox])
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertTrue(FolderProtection.prohibited(inside))
    }

    func testCloudPathPolicy() {
        XCTAssertTrue(FolderProtection.cloudLikePath(URL(fileURLWithPath: "/Users/example/Library/CloudStorage/Dropbox/file.txt")))
        XCTAssertTrue(FolderProtection.prohibited(URL(fileURLWithPath: "/Users/example/Library/CloudStorage/Dropbox")))
    }

    #if os(macOS)
    /// Actual Finder-compatible Trash integration, restricted to temporary test files.
    /// The test restores the file and verifies its bytes, and never empties Trash.
    func testRealTrashAndRestoreRoundTrip() throws {
        let keeperURL = try write("onecopy-real-trash-keeper.txt", "test-only matching bytes")
        let duplicateURL = try write("onecopy-real-trash-copy.txt", "test-only matching bytes")
        let result = try DuplicateScanner().scan(folders: [sandbox])
        let group = try XCTUnwrap(result.groups.first)
        let keeper = try XCTUnwrap(group.files.first { $0.url == keeperURL })
        let duplicate = try XCTUnwrap(group.files.first { $0.url == duplicateURL })
        XCTAssertTrue(try DuplicateScanner.safeToTrash(keeper: keeper, candidate: duplicate))
        var moved: NSURL?
        try FileManager.default.trashItem(at: duplicateURL, resultingItemURL: &moved)
        let inTrash = try XCTUnwrap(moved as URL?)
        defer {
            // If restore failed during testing, clean only the uniquely named test artifact.
            if FileManager.default.fileExists(atPath: inTrash.path) {
                try? FileManager.default.removeItem(at: inTrash)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path))
        try FileManager.default.moveItem(at: inTrash, to: duplicateURL)
        XCTAssertTrue(try FileHashing.byteEqual(keeperURL, duplicateURL))
    }

    func testDifferentFinderExtendedAttributesAreNotAutoDeletable() throws {
        let keeperURL = try write("onecopy-xattr-first.txt", "exact content")
        let candidateURL = try write("onecopy-xattr-second.txt", "exact content")
        let value = Data("unique finder metadata".utf8)
        let rc = value.withUnsafeBytes { raw -> Int32 in
            keeperURL.path.withCString { path in
                "com.onecopy.qa".withCString { name in
                    Darwin.setxattr(path, name, raw.baseAddress, raw.count, 0, 0)
                }
            }
        }
        XCTAssertEqual(rc, 0, "Test fixture xattr must be writable")
        let report = try DuplicateScanner().scan(folders: [sandbox])
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.assessment.status, .review)
        let a = try XCTUnwrap(group.files.first { $0.url == keeperURL })
        let b = try XCTUnwrap(group.files.first { $0.url == candidateURL })
        XCTAssertFalse(try DuplicateScanner.safeToTrash(keeper: a, candidate: b))
    }
    #endif

}
