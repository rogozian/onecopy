import Foundation

@main
struct GroupingSmoke {
    static func main() {
        func assert(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAILED: \(label)") }
            print("PASS: \(label)")
        }
        let objects = [
            IndexedFile(id: "photo.jpg", size: 10, sha256: "alpha"),
            IndexedFile(id: "copy.jpeg", size: 10, sha256: "alpha"),
            IndexedFile(id: "changed.jpg", size: 10, sha256: "bravo"),
            IndexedFile(id: "other.jpg", size: 9, sha256: "alpha"),
            IndexedFile(id: "movie.mov", size: 9999, sha256: "z"),
            IndexedFile(id: "movie (1).mov", size: 9999, sha256: "z")
        ]
        let groups = DuplicateIndex.groups(objects)
        assert(groups.count == 2, "Only two matching groups")
        assert(groups.allSatisfy { $0.count == 2 }, "No singleton groups")
        assert(groups.flatMap { $0.map(\.id) }.contains("copy.jpeg"), "Renamed extension supported")
        assert(!groups.flatMap { $0.map(\.id) }.contains("changed.jpg"), "Different hash excluded")
        assert(!groups.flatMap { $0.map(\.id) }.contains("other.jpg"), "Different size excluded")
        assert(DuplicateIndex.groups([]).isEmpty, "Empty input")
        assert(DuplicateIndex.groups([objects[0]]).isEmpty, "One original is safe")
        print("7 grouping tests passed (platform-independent only)")
    }
}
