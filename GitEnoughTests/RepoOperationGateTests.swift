import XCTest
@testable import GitEnough

final class RepoOperationGateTests: XCTestCase {

    func testOnlyOneOperationCanBeAdmitted() throws {
        var gate = RepoOperationGate()
        let first = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.isActive)
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.finish(first))
        XCTAssertFalse(gate.isActive)
        XCTAssertNotNil(gate.begin())
    }

    func testStaleCompletionCannotReleaseAnotherOperation() throws {
        var gate = RepoOperationGate()
        let first = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.finish(first))
        let second = try XCTUnwrap(gate.begin())

        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(gate.activeID, second)
    }
}
