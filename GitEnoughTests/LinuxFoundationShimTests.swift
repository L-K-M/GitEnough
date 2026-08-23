#if !canImport(Darwin)
import XCTest
@testable import GitEnough

/// The stand-ins that let the model layer compile without Apple's SDKs. They
/// only exist on Linux, so the tests do too — on macOS the real Combine and
/// SwiftUI implementations are in play and there is nothing here to check.
final class ObservableObjectShimTests: XCTestCase {

    private final class Model: ObservableObject {
        @Published var name = "initial"
        @Published private(set) var count = 0
        @Published var tracked: String? {
            didSet { observed.append(tracked ?? "nil") }
        }
        var observed: [String] = []

        func bump() { count += 1 }
    }

    func testPublishedPropertiesReadAndWriteLikePlainStorage() {
        let model = Model()
        XCTAssertEqual(model.name, "initial")
        model.name = "changed"
        XCTAssertEqual(model.name, "changed")
    }

    func testWritingAPublishedPropertyNotifiesObservers() {
        let model = Model()
        var notifications = 0
        let token = model.objectWillChange.sink { notifications += 1 }
        model.name = "a"
        model.bump()
        XCTAssertEqual(notifications, 2)
        token.cancel()
    }

    func testNotificationArrivesBeforeTheValueChanges() {
        // SwiftUI depends on this ordering: it snapshots the old value when the
        // will-change fires and diffs against the new one.
        let model = Model()
        var seenDuringNotification: String?
        let token = model.objectWillChange.sink { seenDuringNotification = model.name }
        model.name = "after"
        XCTAssertEqual(seenDuringNotification, "initial")
        token.cancel()
    }

    func testPropertyObserversStillRun() {
        let model = Model()
        model.tracked = "one"
        model.tracked = nil
        XCTAssertEqual(model.observed, ["one", "nil"])
    }

    func testTheSamePublisherIsHandedOutForOneObject() {
        let model = Model()
        XCTAssertTrue(model.objectWillChange === model.objectWillChange)
    }

    func testDistinctObjectsGetDistinctPublishers() {
        let first = Model()
        let second = Model()
        var firstCount = 0
        let token = first.objectWillChange.sink { firstCount += 1 }
        second.name = "unrelated"
        XCTAssertEqual(firstCount, 0)
        token.cancel()
    }

    func testACancelledObserverStopsBeingCalled() {
        let model = Model()
        var notifications = 0
        let token = model.objectWillChange.sink { notifications += 1 }
        model.name = "a"
        token.cancel()
        model.name = "b"
        XCTAssertEqual(notifications, 1)
    }

    func testReleasingTheTokenCancelsIt() {
        let model = Model()
        var notifications = 0
        do {
            _ = model.objectWillChange.sink { notifications += 1 }
        }
        model.name = "a"
        XCTAssertEqual(notifications, 0)
    }

    func testAPublisherOutlivesTheObjectItWasBuiltFor() {
        // The registry holds owners weakly and reuses ObjectIdentifier values
        // after a deallocation; a recycled identity must not resurrect the old
        // object's observers.
        var notifications = 0
        var token: AnyCancellable?
        do {
            let model = Model()
            token = model.objectWillChange.sink { notifications += 1 }
            model.name = "a"
        }
        let replacement = Model()
        replacement.name = "b"
        XCTAssertEqual(notifications, 1)
        token?.cancel()
    }
}

final class CollectionMoveShimTests: XCTestCase {

    func testMovingOneElementDown() {
        var items = ["a", "b", "c", "d"]
        items.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(items, ["b", "c", "a", "d"])
    }

    func testMovingOneElementUp() {
        var items = ["a", "b", "c", "d"]
        items.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)
        XCTAssertEqual(items, ["a", "d", "b", "c"])
    }

    func testMovingSeveralElementsKeepsTheirRelativeOrder() {
        var items = ["a", "b", "c", "d", "e"]
        items.move(fromOffsets: IndexSet([0, 2]), toOffset: 5)
        XCTAssertEqual(items, ["b", "d", "e", "a", "c"])
    }

    func testDroppingOnToTheOwnPositionIsANoOp() {
        var items = ["a", "b", "c"]
        items.move(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        XCTAssertEqual(items, ["a", "b", "c"])
        items.move(fromOffsets: IndexSet(integer: 1), toOffset: 2)
        XCTAssertEqual(items, ["a", "b", "c"])
    }

    func testDroppingAtTheEndAppends() {
        var items = ["a", "b", "c"]
        items.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(items, ["b", "c", "a"])
    }

    func testAnEmptySelectionChangesNothing() {
        var items = ["a", "b"]
        items.move(fromOffsets: IndexSet(), toOffset: 1)
        XCTAssertEqual(items, ["a", "b"])
    }
}
#endif
