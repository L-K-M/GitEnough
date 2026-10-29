#if canImport(AppKit) && !SWIFT_PACKAGE
import AppKit
import SwiftUI
import XCTest
@testable import GitEnough

@MainActor
final class SidebarAccordionTests: XCTestCase {
    func testFirstMiddleAndLastExpandedGroupsKeepAllHeadersVisible() async throws {
        let groups = makeGroups(count: 3)
        for expanded in groups {
            let fixture = LayoutFixture(groups: groups, expandedID: expanded.id, rowCount: 80,
                                        size: NSSize(width: 280, height: 420))
            await fixture.settleLayout()
            try assertFillsSidebar(fixture, groups: groups, expandedID: expanded.id)
            fixture.close()
        }
    }

    func testEmptyShortAndLongListsUseTheSameRemainingSpace() async throws {
        let groups = makeGroups(count: 3)
        var bodyHeights: [CGFloat] = []
        for rowCount in [0, 1, 120] {
            let fixture = LayoutFixture(groups: groups, expandedID: groups[1].id, rowCount: rowCount,
                                        size: NSSize(width: 280, height: 420))
            await fixture.settleLayout()
            try assertFillsSidebar(fixture, groups: groups, expandedID: groups[1].id)
            bodyHeights.append(try XCTUnwrap(fixture.frames["body"]).height)
            fixture.close()
        }
        for height in bodyHeights.dropFirst() {
            XCTAssertEqual(height, bodyHeights[0], accuracy: 1,
                           "Repository count must not move group headers or shrink the active list")
        }
    }

    func testHeadersStayPinnedWhenTheListHasLessThanItsPreferredMinimumHeight() async throws {
        let groups = makeGroups(count: 3)
        let fixture = LayoutFixture(groups: groups, expandedID: groups[0].id, rowCount: 80,
                                    size: NSSize(width: 280, height: 120))
        defer { fixture.close() }
        await fixture.settleLayout()

        let viewport = try XCTUnwrap(fixture.frames["viewport"])
        let body = try XCTUnwrap(fixture.frames["body"])
        XCTAssertEqual(viewport.height, 120, accuracy: 1)
        XCTAssertEqual(body.height, 30, accuracy: 1,
                       "Headers that fit must stay visible even when fewer than 72 points remain for repositories")
        try assertFillsSidebar(fixture, groups: groups, expandedID: groups[0].id)
    }

    func testResizingKeepsHeadersAndExpandedListInsideTheSidebar() async throws {
        let groups = makeGroups(count: 3)
        let fixture = LayoutFixture(groups: groups, expandedID: groups[1].id, rowCount: 100,
                                    size: NSSize(width: 280, height: 500))
        defer { fixture.close() }
        for size in [NSSize(width: 280, height: 500), NSSize(width: 200, height: 210),
                     NSSize(width: 350, height: 650), NSSize(width: 240, height: 300)] {
            fixture.resize(to: size)
            await fixture.settleLayout()
            try assertFillsSidebar(fixture, groups: groups, expandedID: groups[1].id)
        }
    }

    func testTooManyHeadersRemainReachableByScrolling() async throws {
        let groups = makeGroups(count: 14)
        let fixture = LayoutFixture(groups: groups, expandedID: groups[0].id, rowCount: 0,
                                    size: NSSize(width: 280, height: 240))
        defer { fixture.close() }
        await fixture.settleLayout()
        let viewport = try XCTUnwrap(fixture.frames["viewport"])
        let first = try XCTUnwrap(fixture.frames[headerKey(groups[0])])
        let last = try XCTUnwrap(fixture.frames[headerKey(groups.last!)])
        XCTAssertGreaterThanOrEqual(first.minY, viewport.minY - 1)
        XCTAssertGreaterThan(last.maxY, viewport.maxY,
                             "Overflow must be in scrollable content rather than compressed headers")

        let outerScrollView = try XCTUnwrap(fixture.hostingView.descendants(of: NSScrollView.self).first {
            $0.contentView.bounds.height >= viewport.height - 1
                && ($0.documentView?.bounds.height ?? 0) > viewport.height + 1
        }, "The overflow layout must provide a scroll view covering the sidebar")
        let document = try XCTUnwrap(outerScrollView.documentView)
        let bottomOrigin = document.isFlipped
            ? document.bounds.maxY - outerScrollView.contentView.bounds.height : document.bounds.minY
        outerScrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomOrigin))
        outerScrollView.reflectScrolledClipView(outerScrollView.contentView)
        await fixture.settleLayout()

        let visibleLast = try XCTUnwrap(fixture.frames[headerKey(groups.last!)])
        XCTAssertGreaterThanOrEqual(visibleLast.minY, viewport.minY - 1)
        XCTAssertLessThanOrEqual(visibleLast.maxY, viewport.maxY + 1,
                                 "The final group must be completely reachable after scrolling")

        fixture.resize(to: NSSize(width: 280, height: 700))
        await fixture.settleLayout()
        try assertFillsSidebar(fixture, groups: groups, expandedID: groups[0].id)
    }

    func testOriginalSingleListDoesNotKeepLowerHeadersVisible() async throws {
        let groups = makeGroups(count: 3)
        // This minimal version of the former layout keeps headers and expanded
        // repositories in one native List. It demonstrates the observable
        // regression without depending on preferences or real repositories.
        let fixture = LayoutFixture(groups: groups, expandedID: groups[0].id, rowCount: 100,
                                    size: NSSize(width: 280, height: 420), originalSingleList: true)
        defer { fixture.close() }
        await fixture.settleLayout()
        let viewport = try XCTUnwrap(fixture.frames["viewport"])
        XCTAssertFalse(groups.allSatisfy { group in
            guard let frame = fixture.frames[headerKey(group)] else { return false }
            return frame.minY >= viewport.minY && frame.maxY <= viewport.maxY
        }, "The old scrolling-header layout must fail the fixed-header visibility invariant")
    }

    func testRepositorySelectionPreservesTheNativeListAndFirstResponder() async throws {
        _ = NSApplication.shared
        let groups = makeGroups(count: 3)
        let state = RepositorySelection(expandedGroupID: groups[2].id)
        let hostingView = NSHostingView(rootView: SelectingAccordion(groups: groups, state: state))
        hostingView.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 420),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 420)
        await settleLayout(of: hostingView)
        let table = try XCTUnwrap(hostingView.descendants(of: NSTableView.self).first {
            !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.height > 0
        })
        XCTAssertTrue(window.makeFirstResponder(table))

        for row in 0..<4 {
            // Native selection notifies SwiftUI's List delegate and updates the
            // surrounding observable state, just as an arrow-key selection does.
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await settleLayout(of: hostingView)
            XCTAssertEqual(state.selectedRepository, "repository-\(row)")
            XCTAssertTrue(hostingView.descendants(of: NSTableView.self).contains { $0 === table },
                          "Selecting another repository must not replace its native list")
            XCTAssertTrue(window.firstResponder === table,
                          "The next arrow key must still reach the repository list")
        }
    }

    func testNativeSplitWindowResizesWithNormalHostingSizeConstraints() async throws {
        _ = NSApplication.shared
        let groups = makeGroups(count: 3)
        let measurements = Frames()
        let workspace = NavigationSplitView {
            MeasuredAccordion(groups: groups, expandedID: groups[1].id, rowCount: 80,
                              originalSingleList: false, measurements: measurements)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            Text("Repository detail").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 520)
        // Keep NSHostingView's normal sizing options here. The simpler geometry
        // fixtures deliberately disable them, which cannot detect feedback
        // between split-view minimum sizing and window constraint updates.
        let hostingView = NSHostingView(rootView: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView

        for size in [NSSize(width: 1240, height: 780), NSSize(width: 1100, height: 660),
                     NSSize(width: 1040, height: 600), NSSize(width: 860, height: 520),
                     NSSize(width: 1450, height: 900), NSSize(width: 1040, height: 600)] {
            window.setContentSize(size)
            hostingView.updateConstraintsForSubtreeIfNeeded()
            await settleLayout(of: hostingView)
            let viewport = try XCTUnwrap(measurements.values["viewport"])
            let body = try XCTUnwrap(measurements.values["body"])
            XCTAssertEqual(body.height, viewport.height - 90, accuracy: 1)
            for group in groups {
                let header = try XCTUnwrap(measurements.values[headerKey(group)])
                XCTAssertGreaterThanOrEqual(header.minY, viewport.minY - 1)
                XCTAssertLessThanOrEqual(header.maxY, viewport.maxY + 1)
            }
            XCTAssertGreaterThanOrEqual(hostingView.frame.width, 860)
            XCTAssertGreaterThanOrEqual(hostingView.frame.height, 520)
        }
    }

    private func settleLayout(of view: NSView) async {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertFillsSidebar(_ fixture: LayoutFixture, groups: [SidebarRepositoryGroup],
                                    expandedID: String, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let viewport = try XCTUnwrap(fixture.frames["viewport"], file: file, line: line)
        let body = try XCTUnwrap(fixture.frames["body"], file: file, line: line)
        let headers = try groups.map { try XCTUnwrap(fixture.frames[headerKey($0)], file: file, line: line) }
        XCTAssertEqual(headers.first!.minY, viewport.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual((headers + [body]).map(\.maxY).max()!, viewport.maxY,
                       accuracy: 1, file: file, line: line)
        XCTAssertEqual(body.height, viewport.height - headers.reduce(0) { $0 + $1.height },
                       accuracy: 1, file: file, line: line)
        let expandedIndex = try XCTUnwrap(groups.firstIndex { $0.id == expandedID }, file: file, line: line)
        XCTAssertEqual(body.minY, headers[expandedIndex].maxY, accuracy: 1, file: file, line: line)
        if expandedIndex + 1 < headers.count {
            XCTAssertEqual(body.maxY, headers[expandedIndex + 1].minY, accuracy: 1, file: file, line: line)
        }
        for frame in headers + [body] {
            XCTAssertEqual(frame.minX, viewport.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.maxX, viewport.maxX, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        }
    }

    private func makeGroups(count: Int) -> [SidebarRepositoryGroup] {
        (0..<count).map {
            SidebarRepositoryGroup(id: "group-\($0)", title: "Group \($0)", subtitle: nil,
                                   repositories: [], manualGroupID: nil)
        }
    }

    private func headerKey(_ group: SidebarRepositoryGroup) -> String { "header-\(group.id)" }

    private final class Frames {
        var values: [String: CGRect] = [:]
    }

    @MainActor
    private final class RepositorySelection: ObservableObject {
        @Published var selectedRepository: String?
        @Published var expandedGroupID: String

        init(expandedGroupID: String) { self.expandedGroupID = expandedGroupID }
    }

    private struct SelectingAccordion: View {
        let groups: [SidebarRepositoryGroup]
        @ObservedObject var state: RepositorySelection

        var body: some View {
            SidebarAccordion(groups: groups, expandedGroupID: state.expandedGroupID) { group in
                Text(group.title).frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            } content: { group in
                List(selection: Binding(get: { state.selectedRepository }, set: { path in
                    // AppKit can synchronize a programmatic table selection
                    // during List layout. Publish the fixture's parent update
                    // at the next event boundary, after that layout completes.
                    DispatchQueue.main.async {
                        if state.selectedRepository != path { state.selectedRepository = path }
                    }
                })) {
                    ForEach(0..<12, id: \.self) { row in
                        Text("Repository \(row)").tag("repository-\(row)")
                    }
                }
                .listStyle(.sidebar)
                .id(group.id)
                .onChange(of: state.selectedRepository) { _, _ in state.expandedGroupID = group.id }
            }
        }
    }

    @MainActor
    private final class LayoutFixture {
        private let measurements = Frames()
        let hostingView: NSHostingView<MeasuredAccordion>
        private let window: NSWindow
        var frames: [String: CGRect] { measurements.values }

        init(groups: [SidebarRepositoryGroup], expandedID: String, rowCount: Int, size: NSSize,
             originalSingleList: Bool = false) {
            _ = NSApplication.shared
            hostingView = NSHostingView(rootView: MeasuredAccordion(
                groups: groups, expandedID: expandedID, rowCount: rowCount,
                originalSingleList: originalSingleList, measurements: measurements))
            hostingView.sizingOptions = []
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            resize(to: size)
        }

        func resize(to size: NSSize) {
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.needsLayout = true
        }

        func settleLayout() async {
            // Native lists complete their layout over more than one
            // run-loop turn. The window is never ordered or made key.
            for _ in 0..<4 {
                hostingView.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        func close() { window.close() }
    }

    private struct MeasuredAccordion: View {
        let groups: [SidebarRepositoryGroup]
        let expandedID: String
        let rowCount: Int
        let originalSingleList: Bool
        let measurements: Frames

        var body: some View {
            Group {
                if originalSingleList {
                    List {
                        ForEach(groups) { group in
                            DisclosureGroup(isExpanded: .constant(group.id == expandedID)) {
                                ForEach(0..<rowCount, id: \.self) { Text("Repository \($0)") }
                            } label: {
                                header(group)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                } else {
                    SidebarAccordion(groups: groups, expandedGroupID: expandedID) { group in
                        header(group)
                    } content: { _ in
                        List(0..<rowCount, id: \.self) { Text("Repository \($0)") }
                            .listStyle(.sidebar)
                            .background(frameProbe("body"))
                    }
                }
            }
            .background(frameProbe("viewport"))
            .coordinateSpace(name: "accordion-layout-test")
            .onPreferenceChange(FramePreference.self) { measurements.values = $0 }
        }

        private func header(_ group: SidebarRepositoryGroup) -> some View {
            Text(group.title)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .background(frameProbe("header-\(group.id)"))
        }

        private func frameProbe(_ key: String) -> some View {
            GeometryReader { geometry in
                Color.clear.preference(key: FramePreference.self,
                                       value: [key: geometry.frame(in: .named("accordion-layout-test"))])
            }
        }
    }

    private struct FramePreference: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }
}

@MainActor
private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view in
            ((view as? T).map { [$0] } ?? []) + view.descendants(of: type)
        }
    }
}
#endif
