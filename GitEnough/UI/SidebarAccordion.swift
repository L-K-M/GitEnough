import SwiftUI

/// Headers stay outside the repository scroll view. The expanded body's
/// flexibility pushes later headers to the bottom of the available sidebar.
struct SidebarAccordion<Header: View, Content: View>: View {
    let groups: [SidebarRepositoryGroup]
    let expandedGroupID: String?
    @ViewBuilder var header: (SidebarRepositoryGroup) -> Header
    @ViewBuilder var content: (SidebarRepositoryGroup) -> Content

    var body: some View {
        GeometryReader { geometry in
            // Normally the outer view has zero scroll extent: only the native
            // repository List scrolls. Excess headers remain reachable in a
            // short window. Keep one view tree so resizing or selection cannot
            // replace the native List and lose its keyboard responder.
            ScrollView {
                AccordionLayout(viewportHeight: geometry.size.height) {
                    ForEach(groups) { group in
                        header(group)
                            .fixedSize(horizontal: false, vertical: true)
                        if group.id == expandedGroupID {
                            content(group).layoutValue(key: AccordionBody.self, value: true)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }
}

private struct AccordionBody: LayoutValueKey {
    static let defaultValue = false
}

/// Measure and place headers in one layout pass. Publishing their measured
/// heights into view state would feed window constraint measurement back into
/// itself during interactive resizing.
private struct AccordionLayout: Layout {
    let viewportHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? 250
        let headersHeight = headerSizes(width: width, subviews: subviews).reduce(0) { $0 + $1.height }
        return CGSize(width: width, height: max(viewportHeight, headersHeight + 72))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let sizes = headerSizes(width: bounds.width, subviews: subviews)
        let bodyHeight = max(0, bounds.height - sizes.reduce(0) { $0 + $1.height })
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let height = subview[AccordionBody.self] ? bodyHeight : sizes[index].height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func headerSizes(width: CGFloat, subviews: Subviews) -> [CGSize] {
        subviews.map { $0[AccordionBody.self] ? .zero
            : $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }
}
