import XCTest
@testable import cuelens

final class NativeGazeModelStoreTests: XCTestCase {
    func testInvalidReplacementPreservesInstalledDirectory() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let source = root.appendingPathComponent("invalid")
        try files.createDirectory(at: installed, withIntermediateDirectories: true)
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        let marker = installed.appendingPathComponent("keep.txt")
        try Data("existing pair".utf8).write(to: marker)
        XCTAssertThrowsError(try NativeGazeModelStore.install(from: source, at: installed))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing pair")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: installed.path), ["keep.txt"])
    }
}
