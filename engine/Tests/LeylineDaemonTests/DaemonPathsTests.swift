// SPDX-License-Identifier: GPL-3.0-or-later

// The paths `leylined` finds without help from its launch agent, whose ProgramArguments cannot
// expand `~` or name the bundle's directory: the decoders beside the executable and the log file.

import Foundation
@testable import LeylineServer
import XCTest

final class DaemonPathsTests: XCTestCase {
    /// The decoders a bundle carries beside `leylined` are searched last, so a plugin the user
    /// installed in a configured or default directory shadows the bundled one.
    func testBundledDecodersAreSearchedAfterTheConfiguredAndDefaultDirectories() {
        let path = decoderSearchPath(configured: ["/configured"],
                                     executablePath: "/Applications/Leyline.app/Contents/Helpers/leylined")
        XCTAssertEqual(path.first, "/configured")
        XCTAssertEqual(path.last, "/Applications/Leyline.app/Contents/Helpers/decoders")
        guard let defaultIndex = path.firstIndex(of: defaultDecodersPath()) else {
            return XCTFail("the default decoders directory is missing from \(path)")
        }
        XCTAssertEqual(defaultIndex, path.count - 2)
    }

    func testNoExecutablePathAddsNoBundledDirectory() {
        let path = decoderSearchPath(configured: [], executablePath: nil)
        XCTAssertEqual(path.last, defaultDecodersPath())
    }

    /// A plugin found only in the bundle's `decoders` directory is one the daemon can run.
    func testRegistryFindsAPluginBesideTheExecutable() throws {
        let helpers = try makeTempDir("helpers")
        defer { try? FileManager.default.removeItem(atPath: helpers) }
        try FileManager.default.createDirectory(atPath: helpers + "/decoders", withIntermediateDirectories: true)
        try writeFakePlugin(in: helpers + "/decoders", name: "bundled-only")
        let path = decoderSearchPath(configured: [], executablePath: helpers + "/leylined")
        XCTAssertEqual(DecoderRegistry(searchPath: path).find("bundled-only")?.directory,
                       helpers + "/decoders/bundled-only")
    }

    /// The running executable resolves to a real file with no symlink left in its path, so a
    /// `leylined` reached through a link looks beside the file it links to.
    func testCurrentExecutablePathIsResolved() throws {
        let path = try XCTUnwrap(currentExecutablePath())
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, path)
    }

    func testOnlyALeadingTildeSlashIsTheHomeDirectory() {
        XCTAssertEqual(expandingTilde("~/Library/Logs/Leyline/leylined.log", home: "/Users/a"),
                       "/Users/a/Library/Logs/Leyline/leylined.log")
        XCTAssertEqual(expandingTilde("~/x", home: "/Users/a/"), "/Users/a/x")
        XCTAssertEqual(expandingTilde("/tmp/~/x", home: "/Users/a"), "/tmp/~/x")
        XCTAssertEqual(expandingTilde("~other/x", home: "/Users/a"), "~other/x")
        XCTAssertEqual(expandingTilde("relative.log", home: "/Users/a"), "relative.log")
    }

    /// `--log-file` creates the directory, and each start appends to what earlier runs wrote.
    func testLogFileIsCreatedWithItsDirectoryAndAppendedTo() throws {
        let root = try makeTempDir("logfile")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let log = root + "/Logs/Leyline/leylined.log"
        // A spare descriptor stands in for standard output and error, which the test runner keeps.
        let spare = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(spare, 0)
        defer { close(spare) }

        try appendOutput(toLogFile: log, descriptors: [spare])
        XCTAssertEqual(write(spare, "first run\n", 10), 10)
        try appendOutput(toLogFile: log, descriptors: [spare])
        XCTAssertEqual(write(spare, "second run\n", 11), 11)

        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "first run\nsecond run\n")
    }

    func testALogFileThatCannotBeCreatedSaysWhere() throws {
        let root = try makeTempDir("logfile-blocked")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A file where the log's directory should be.
        FileManager.default.createFile(atPath: root + "/Logs", contents: Data())
        let spare = dup(STDERR_FILENO)
        defer { close(spare) }
        XCTAssertThrowsError(try appendOutput(toLogFile: root + "/Logs/leylined.log", descriptors: [spare])) { error in
            XCTAssertTrue(String(describing: error).contains(root + "/Logs/leylined.log"), "\(error)")
        }
    }
}
