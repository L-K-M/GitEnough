import Foundation

/// Geometry constants for the history graph.
enum GraphMetrics {
    /// Lane spacing while the lane count fits the column's width budget.
    static let laneWidth: CGFloat = 16
    /// How many lanes fit at full width; beyond this, lanes squeeze.
    static let maxUncompressedLanes = 12
    /// Hard cap on the graph column's width.
    static let maxGraphWidth: CGFloat = CGFloat(maxUncompressedLanes) * laneWidth
    static let rowHeight: CGFloat = 27
    static let nodeRadius: CGFloat = 4.5

    /// Lane spacing for a graph with `columnCount` lanes. Lanes squeeze once
    /// more are active than the width budget allows — otherwise a busy repo's
    /// historical lane high-water mark (30+ over a long history) makes the
    /// graph column hog the pane and pushes the commit text past the edge.
    /// No floor: the width cap is the invariant that keeps the layout sane —
    /// past a few dozen lanes the graph is a color smear no matter what, but
    /// a bounded one.
    static func laneWidth(for columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        guard count > maxUncompressedLanes else { return laneWidth }
        return maxGraphWidth / CGFloat(count)
    }

    /// Width of the graph column for a graph with `columnCount` lanes — never
    /// exceeds `maxGraphWidth`.
    static func graphWidth(for columnCount: Int) -> CGFloat {
        CGFloat(max(1, columnCount)) * laneWidth(for: columnCount)
    }

    /// Node radius shrinks with squeezing lanes so dots don't bleed together.
    static func nodeRadius(forLaneWidth laneWidth: CGFloat) -> CGFloat {
        min(nodeRadius, laneWidth * 0.36)
    }
}
