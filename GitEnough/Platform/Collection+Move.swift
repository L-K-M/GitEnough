#if !canImport(Darwin)
import Foundation

/// `move(fromOffsets:toOffset:)` — the reordering primitive a drag in the
/// sidebar produces — ships with Apple's SDKs but not with
/// swift-corelibs-foundation, so Linux needs its own.
///
/// The offsets are interpreted exactly as Apple's version does: `destination`
/// indexes the collection *before* anything is removed, so a drag onto row 3
/// means "put these in front of whatever is row 3 right now".
extension RangeReplaceableCollection where Self: MutableCollection, Index == Int {
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        // Highest offset first: removing low indices would shift the rest.
        for offset in source.sorted(by: >) where indices.contains(offset) {
            remove(at: offset)
        }
        // Every removed element that sat before the drop target pulls it left.
        let insertionPoint = destination - source.count(in: 0..<destination)
        insert(contentsOf: moving,
               at: Swift.max(startIndex, Swift.min(insertionPoint, endIndex)))
    }
}
#endif
