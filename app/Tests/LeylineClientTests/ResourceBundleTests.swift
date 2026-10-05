// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import LeylineClient

final class ResourceBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func place(_ bundle: String, in dir: String) throws -> URL {
        let b = root.appendingPathComponent(dir).appendingPathComponent(bundle)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = b.appendingPathComponent("bands.json")
        try Data("[]".utf8).write(to: file)
        return file
    }

    /// A distributed app's layout: the bundle in Contents/Resources, found before the app's root
    /// and the executable's directory, which a bundle there would shadow.
    func testContentsResourcesComesFirst() throws {
        let want = try place(
            "LeylineApp_LeylineClient.bundle", in: "Leyline.app/Contents/Resources")
        _ = try place("LeylineApp_LeylineClient.bundle", in: "Leyline.app/Contents/MacOS")
        let dirs = ["Leyline.app/Contents/Resources", "Leyline.app", "Leyline.app/Contents/MacOS"]
            .map { root.appendingPathComponent($0) }
        XCTAssertEqual(ResourceBundle.find("bands.json", in: dirs)?.path, want.path)
    }

    func testLinuxResourcesDirectoryBesideTheExecutable() throws {
        let want = try place("LeylineApp_LeylineClient.resources", in: "debug")
        let dirs = [root.appendingPathComponent("nowhere"), root.appendingPathComponent("debug")]
        XCTAssertEqual(ResourceBundle.find("bands.json", in: dirs)?.path, want.path)
    }

    /// A bundle without the file, or another target's bundle, is not the one.
    func testNothingFoundIsNil() throws {
        _ = try place("Other_Target.bundle", in: "a")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("b/LeylineApp_LeylineClient.bundle"),
            withIntermediateDirectories: true)
        let dirs = ["a", "b"].map { root.appendingPathComponent($0) }
        XCTAssertNil(ResourceBundle.find("bands.json", in: dirs))
    }

    /// The test binary sits beside the build's resource bundle, so the search finds it without
    /// the generated accessor.
    func testThisBuildIsFoundWithoutBundleModule() {
        XCTAssertNotNil(ResourceBundle.find("bands.json", in: ResourceBundle.searchDirectories))
    }
}
