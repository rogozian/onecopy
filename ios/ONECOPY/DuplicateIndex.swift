import Foundation

/// Platform-independent candidate grouping. Hash equality is only a filter:
/// callers must byte-compare every candidate before labeling it 'identical'.
struct IndexedFile: Hashable {
    let id: String
    let size: Int64
    let sha256: String
}

enum DuplicateIndex {
    static func groups(_ files: [IndexedFile]) -> [[IndexedFile]] {
        Dictionary(grouping: files, by: { "\($0.size):\($0.sha256)" })
            .values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.id < $1.id } }
            .sorted {
                let firstA = $0.first?.id ?? ""
                let firstB = $1.first?.id ?? ""
                return firstA < firstB
            }
    }
}
