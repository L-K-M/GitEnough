import XCTest
@testable import GitEnough

/// The freedesktop.org Trash implementation that stands in for
/// `FileManager.trashItem` on Linux. The tests run on both platforms — the code
/// is platform-independent, and a macOS run keeps it from rotting between Linux
/// CI cycles.
final class FreedesktopTrashTests: XCTestCase {

    private var root: URL!
    private var trashRoot: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitenough-trash-\(UUID().uuidString)")
        trashRoot = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func trashInfo(for name: String) throws -> String {
        try String(contentsOf: trashRoot.appendingPathComponent("info/\(name).trashinfo"),
                   encoding: .utf8)
    }

    // MARK: - Moving

    func testTrashingMovesTheFileAndWritesItsRecord() throws {
        let file = try makeFile("notes.txt", contents: "hello")
        try FreedesktopTrash.trash(file, homeTrash: trashRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let trashed = trashRoot.appendingPathComponent("files/notes.txt")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "hello")

        let info = try trashInfo(for: "notes.txt")
        XCTAssertTrue(info.hasPrefix("[Trash Info]\n"))
        XCTAssertTrue(info.contains("Path=\(file.path)"), info)
        XCTAssertTrue(info.contains("DeletionDate="), info)
    }

    func testTrashingADirectoryTakesItsContents() throws {
        let directory = root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "artifact".write(to: directory.appendingPathComponent("out.o"),
                             atomically: true, encoding: .utf8)

        try FreedesktopTrash.trash(directory, homeTrash: trashRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let moved = trashRoot.appendingPathComponent("files/build/out.o")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "artifact")
    }

    func testSecondFileWithTheSameNameGetsItsOwnEntry() throws {
        try FreedesktopTrash.trash(try makeFile("notes.txt", contents: "first"),
                                   homeTrash: trashRoot)
        try FreedesktopTrash.trash(try makeFile("notes.txt", contents: "second"),
                                   homeTrash: trashRoot)

        let files = trashRoot.appendingPathComponent("files")
        XCTAssertEqual(
            try String(contentsOf: files.appendingPathComponent("notes.txt"), encoding: .utf8),
            "first")
        XCTAssertEqual(
            try String(contentsOf: files.appendingPathComponent("notes.2.txt"), encoding: .utf8),
            "second")
        XCTAssertTrue(try trashInfo(for: "notes.2.txt").contains("Path="))
    }

    func testTrashDirectoriesAreCreatedPrivate() throws {
        try FreedesktopTrash.trash(try makeFile("notes.txt"), homeTrash: trashRoot)
        let attributes = try FileManager.default.attributesOfItem(atPath: trashRoot.path)
        // The trash holds whatever the user deleted; 0700 keeps other accounts out.
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o700)
    }

    func testAFailedMoveLeavesNoOrphanRecord() throws {
        let missing = root.appendingPathComponent("never-existed.txt")
        XCTAssertThrowsError(try FreedesktopTrash.trash(missing, homeTrash: trashRoot))
        let info = trashRoot.appendingPathComponent("info/never-existed.txt.trashinfo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path),
                       "an info record without a file would show as a ghost entry in the file manager")
    }

    // MARK: - Record contents

    func testPathIsPercentEncodedButKeepsSeparators() {
        let info = FreedesktopTrash.trashInfo(originalPath: "/home/ada/my notes/50% #1.txt",
                                              deletedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(info.contains("Path=/home/ada/my%20notes/50%25%20%231.txt"), info)
    }

    func testDeletionDateIsLocalWallClockWithoutAZone() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 4
        components.hour = 5; components.minute = 6; components.second = 7
        let date = Calendar.current.date(from: components)!
        let info = FreedesktopTrash.trashInfo(originalPath: "/tmp/x", deletedAt: date)
        XCTAssertTrue(info.contains("DeletionDate=2026-03-04T05:06:07"), info)
    }

    // MARK: - Naming

    func testDisambiguationGoesBeforeTheExtension() {
        XCTAssertEqual(FreedesktopTrash.candidateName("notes.txt", attempt: 1), "notes.txt")
        XCTAssertEqual(FreedesktopTrash.candidateName("notes.txt", attempt: 2), "notes.2.txt")
        XCTAssertEqual(FreedesktopTrash.candidateName("archive.tar.gz", attempt: 3),
                       "archive.tar.3.gz")
    }

    func testExtensionlessAndDotfileNamesKeepTheirShape() {
        XCTAssertEqual(FreedesktopTrash.candidateName("Makefile", attempt: 2), "Makefile.2")
        // ".env" is a dotfile, not an extension — a leading dot must survive.
        XCTAssertEqual(FreedesktopTrash.candidateName(".env", attempt: 2), ".env.2")
    }

    // MARK: - Volume trash

    func testVolumeRootIsDerivedFromEitherSpelling() {
        XCTAssertEqual(
            FreedesktopTrash.volumeRoot(ofTrash: URL(fileURLWithPath: "/data/.Trash-1000")),
            "/data")
        XCTAssertEqual(
            FreedesktopTrash.volumeRoot(ofTrash: URL(fileURLWithPath: "/data/.Trash/1000")),
            "/data")
        XCTAssertNil(
            FreedesktopTrash.volumeRoot(ofTrash: URL(fileURLWithPath: "/home/ada/.local/share/Trash")))
    }

    func testVolumeTrashRecordsAPathRelativeToItsVolume() {
        let path = FreedesktopTrash.originalPath(
            of: URL(fileURLWithPath: "/data/projects/notes.txt"),
            relativeTo: URL(fileURLWithPath: "/data/.Trash-1000"))
        // Relative, so the entry survives the volume being mounted elsewhere.
        XCTAssertEqual(path, "projects/notes.txt")
    }

    func testHomeTrashRecordsAnAbsolutePath() {
        let path = FreedesktopTrash.originalPath(
            of: URL(fileURLWithPath: "/home/ada/notes.txt"),
            relativeTo: URL(fileURLWithPath: "/home/ada/.local/share/Trash"))
        XCTAssertEqual(path, "/home/ada/notes.txt")
    }

    // MARK: - Location

    func testHomeTrashFollowsXDGDataHome() {
        let trash = FreedesktopTrash.homeTrashDirectory(
            environment: ["XDG_DATA_HOME": "/custom/data"], home: "/home/ada")
        XCTAssertEqual(trash.path, "/custom/data/Trash")
    }

    func testHomeTrashFallsBackToTheDefaultAndIgnoresRelativeOverrides() {
        XCTAssertEqual(
            FreedesktopTrash.homeTrashDirectory(environment: [:], home: "/home/ada").path,
            "/home/ada/.local/share/Trash")
        // The XDG spec says a relative value is invalid and must be ignored.
        XCTAssertEqual(
            FreedesktopTrash.homeTrashDirectory(environment: ["XDG_DATA_HOME": "data"],
                                                home: "/home/ada").path,
            "/home/ada/.local/share/Trash")
    }
}
