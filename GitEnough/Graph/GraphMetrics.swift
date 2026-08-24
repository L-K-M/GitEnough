import Foundation

/// Geometry constants for the history graph.
public enum GraphMetrics {
    /// Lane spacing while the lane count fits the column's width budget.
    public static let laneWidth: CGFloat = 16
    /// How many lanes fit at full width; beyond this, lanes squeeze.
    public static let maxUncompressedLanes = 12
    /// Hard cap on the graph column's width.
    public static let maxGraphWidth: CGFloat = CGFloat(maxUncompressedLanes) * laneWidth
    public static let rowHeight: CGFloat = 27
    public static let nodeRadius: CGFloat = 4.5

    /// Lane spacing for a graph with `columnCount` lanes. Lanes squeeze once
    /// more are active than the width budget allows — otherwise a busy repo's
    /// historical lane high-water mark (30+ over a long history) makes the
    /// graph column hog the pane and pushes the commit text past the edge.
    /// No floor: the width cap is the invariant that keeps the layout sane —
    /// past a few dozen lanes the graph is a color smear no matter what, but
    /// a bounded one.
    public static func laneWidth(for columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        guard count > maxUncompressedLanes else { return laneWidth }
        return maxGraphWidth / CGFloat(count)
    }

    /// Width of the graph column for a graph with `columnCount` lanes — never
    /// exceeds `maxGraphWidth`.
    public static func graphWidth(for columnCount: Int) -> CGFloat {
        CGFloat(max(1, columnCount)) * laneWidth(for: columnCount)
    }

    /// How many lanes keep their full spacing before the rest are squeezed.
    ///
    /// Squeezing every lane equally means one crowded stretch sets the spacing
    /// for the whole history: a repo whose merges peak at 54 lanes draws its
    /// long trunk-only stretches at 3.6pt too, and those rows are the ones
    /// people actually read. Lanes can't be spaced per row — a lane sits at a
    /// multiple of the spacing, so varying it by row slides every lane sideways
    /// in proportion to its column — so the generosity has to be a function of
    /// the column instead: the low lanes, where the trunk and the recent
    /// branches live, keep full spacing and the crowd beyond them absorbs the
    /// compression.
    ///
    /// `K` is the largest prefix that still leaves the remaining lanes at least
    /// `crowdedShare` of the spacing they would have had under an even squeeze,
    /// so widening the front never collapses the back.
    static func uncompressedLanes(for columnCount: Int,
                                  crowdedShare: CGFloat = 0.7) -> Int {
        let count = max(1, columnCount)
        guard count > maxUncompressedLanes else { return count }
        let even = maxGraphWidth / CGFloat(count)
        let floorSpacing = crowdedShare * even
        // K · laneWidth + (n − K) · floorSpacing = maxGraphWidth
        let headroom = laneWidth - floorSpacing
        guard headroom > 0 else { return 0 }
        let prefix = (maxGraphWidth - CGFloat(count) * floorSpacing) / headroom
        return min(count, max(0, Int(prefix)))
    }

    /// Spacing between the crowded lanes — everything past `uncompressedLanes`
    /// sharing whatever width the full-spacing prefix left.
    static func crowdedSpacing(for columnCount: Int) -> CGFloat {
        let count = max(1, columnCount)
        let prefix = uncompressedLanes(for: count)
        guard count > prefix else { return laneWidth }
        return (maxGraphWidth - CGFloat(prefix) * laneWidth) / CGFloat(count - prefix)
    }

    /// Horizontal centre of `column` in a graph `columnCount` lanes wide.
    ///
    /// Depends only on the column, never on the row, so a lane never moves
    /// sideways between rows however the graph's density changes around it.
    public static func laneCentre(_ column: Int, columnCount: Int) -> CGFloat {
        let prefix = uncompressedLanes(for: columnCount)
        if column < prefix {
            return (CGFloat(column) + 0.5) * laneWidth
        }
        let spacing = crowdedSpacing(for: columnCount)
        return CGFloat(prefix) * laneWidth
            + (CGFloat(column - prefix) + 0.5) * spacing
    }

    /// Spacing on either side of `column` — what a dot there can grow into.
    public static func spacing(around column: Int, columnCount: Int) -> CGFloat {
        column < uncompressedLanes(for: columnCount)
            ? laneWidth
            : crowdedSpacing(for: columnCount)
    }

    /// Node radius shrinks with squeezing lanes so dots don't bleed together.
    public static func nodeRadius(forLaneWidth laneWidth: CGFloat) -> CGFloat {
        min(nodeRadius, laneWidth * 0.36)
    }
}
