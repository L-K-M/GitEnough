import Foundation

/// The lane-assignment result for a list of topologically ordered commits —
/// the model behind the IntelliJ-style branch/merge graph.
///
/// Coordinate space: a commit at `row` r and `column` c is drawn at
/// (c * laneWidth + laneWidth/2, r * rowHeight + rowHeight/2), and every segment
/// endpoint sits on such a row center line: segments connect consecutive rows
/// (vertical lines), bend diagonally one row down (new branch fan-out), or hook
/// one row down into a passing lane (a lane folding into another). Endpoints on
/// center lines are what make every line visibly attach — either to a dot or to
/// the segment continuing it.
struct GraphLayout: Equatable {

    /// A commit node's placement.
    struct Node: Equatable {
        let row: Int
        let column: Int
        let colorIndex: Int
    }

    /// A colored line piece of the graph.
    struct Segment: Equatable {
        enum Kind: Equatable {
            case vertical     // lane continues straight down to the next row
            case branchOut    // a new lane curves down-right out of a merge node
            case joinExisting // a node/lane merges into a passing lane one row down
        }
        let fromRow: Int
        let fromColumn: Int
        let toRow: Int
        let toColumn: Int
        let colorIndex: Int
        let kind: Kind
    }

    private(set) var nodes: [Node] = []
    private(set) var segments: [Segment] = []
    private(set) var columnCount: Int = 0

    static let empty = GraphLayout()

    /// Computes the layout for `commits`, which must be newest-first and
    /// topologically ordered (`git log --all --topo-order --date-order`).
    ///
    /// The algorithm walks commits top-down while tracking "lanes": vertical
    /// channels each *expecting* one commit hash.
    ///
    /// 1. A commit claims the leftmost lane expecting it, or opens a new lane
    ///    (that makes it a branch tip).
    /// 2. The node's first parent inherits the node's lane — or, if another lane
    ///    already expects that parent, the node's lane folds into it.
    /// 3. Every further parent of a merge either joins a lane already expecting
    ///    it or opens a fresh lane to the right — the fan-out curves.
    /// 4. Every still-occupied lane emits a vertical segment into the next row.
    ///
    /// Invariant: at most one lane expects any given hash (parents always prefer
    /// an existing lane), so lanes never cross without an explicit segment
    /// showing the merge.
    static func layout(commits: [Commit]) -> GraphLayout {
        var layout = GraphLayout()
        guard !commits.isEmpty else { return layout }

        var lanes: [String?] = []       // expected commit hash per lane (nil = free)
        var laneColors: [Int] = []      // palette index per lane
        var nextColor = 0

        /// Leftmost free lane, optionally strictly to the right of `column`.
        /// Used for new branch tips, where reusing any freed lane is fine.
        func freeLane(rightOf column: Int? = nil) -> Int {
            if let column,
               let index = lanes.indices.first(where: { $0 > column && lanes[$0] == nil }) {
                return index
            }
            if let index = lanes.firstIndex(where: { $0 == nil }) {
                return index
            }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }

        /// The lane for a merge's non-first parent. Only reuses free lanes
        /// strictly to the RIGHT of the node — never the node's own column (it
        /// may have been freed by the first-parent fold moments earlier, which
        /// would draw a curve into itself) and never a left lane (the fan-out
        /// would cross the node). Appends a fresh column otherwise.
        func branchOutLane(rightOf column: Int) -> Int {
            if let index = lanes.indices.first(where: { $0 > column && lanes[$0] == nil }) {
                return index
            }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }

        for (row, commit) in commits.enumerated() {
            // 1. Claim the lane for this commit.
            let matching = lanes.indices.filter { lanes[$0] == commit.hash }
            let column: Int
            if let first = matching.first {
                column = first
            } else {
                column = freeLane()
                lanes[column] = commit.hash
                laneColors[column] = nextColor
                nextColor += 1
            }
            layout.nodes.append(Node(row: row, column: column, colorIndex: laneColors[column]))

            // 3. Hand out parents. Lanes born here start drawing one row down.
            var newbornLanes = Set<Int>()
            if commit.parents.isEmpty {
                lanes[column] = nil
            } else {
                let firstParent = commit.parents[0]
                if let existing = lanes.indices.first(where: { $0 != column && lanes[$0] == firstParent }) {
                    // First parent already has a lane (it is the second parent of a
                    // merge further up): fold this lane into it. The join takes the
                    // TARGET lane's color — consistent with merge-node joins.
                    layout.segments.append(Segment(fromRow: row, fromColumn: column,
                                                   toRow: row + 1, toColumn: existing,
                                                   colorIndex: laneColors[existing],
                                                   kind: .joinExisting))
                    lanes[column] = nil
                } else {
                    lanes[column] = firstParent
                }
                for parent in commit.parents.dropFirst() {
                    if let existing = lanes.indices.first(where: { $0 != column && lanes[$0] == parent }) {
                        layout.segments.append(Segment(fromRow: row, fromColumn: column,
                                                       toRow: row + 1, toColumn: existing,
                                                       colorIndex: laneColors[existing],
                                                       kind: .joinExisting))
                    } else {
                        let lane = branchOutLane(rightOf: column)
                        lanes[lane] = parent
                        laneColors[lane] = nextColor
                        nextColor += 1
                        layout.segments.append(Segment(fromRow: row, fromColumn: column,
                                                       toRow: row + 1, toColumn: lane,
                                                       colorIndex: laneColors[lane],
                                                       kind: .branchOut))
                        newbornLanes.insert(lane)
                    }
                }
            }

            // 4. Vertical pass-through segments into the next row.
            for lane in lanes.indices where lanes[lane] != nil && !newbornLanes.contains(lane) {
                layout.segments.append(Segment(fromRow: row, fromColumn: lane,
                                               toRow: row + 1, toColumn: lane,
                                               colorIndex: laneColors[lane], kind: .vertical))
            }
        }

        layout.columnCount = lanes.count
        return layout
    }
}

/// The lane color palette. Hues are spread for distinguishability in both light
/// and dark mode; lanes cycle through them in assignment order.
enum GraphPalette {
    static let hues: [Double] = [
        0.62,   // blue
        0.35,   // green
        0.02,   // red-orange
        0.78,   // purple
        0.55,   // teal
        0.12,   // amber
        0.92,   // pink
        0.45,   // mint
        0.68,   // indigo
        0.22,   // olive
    ]

    static func colorIndex(forLane lane: Int) -> Int { lane % hues.count }
}
