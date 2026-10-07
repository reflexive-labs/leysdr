// SPDX-License-Identifier: Apache-2.0

// The app's command-line installation rule: what already occupies the path and the exact
// filesystem changes its privileged shell command permits.

import Foundation
import XCTest

@testable import LeylineClient

final class CommandLineToolTests: XCTestCase {
    func testStatusDistinguishesTheBundleAndDestination() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Leyline.app/Contents/Helpers/ley").path
        let destination = root.appendingPathComponent("bin/ley").path

        XCTAssertEqual(
            CommandLineTool.status(sourcePath: source, destinationPath: destination), .unavailable)
        try executable(at: source)
        XCTAssertEqual(
            CommandLineTool.status(sourcePath: source, destinationPath: destination), .missing)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
        XCTAssertEqual(
            CommandLineTool.status(sourcePath: source, destinationPath: destination), .installed)

        try FileManager.default.removeItem(atPath: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination,
            withDestinationPath: "/Volumes/Old/Leyline.app/Contents/Helpers/ley")
        XCTAssertEqual(
            CommandLineTool.status(sourcePath: source, destinationPath: destination), .replaceable)

        try FileManager.default.removeItem(atPath: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination, withDestinationPath: "/tmp/other-ley")
        XCTAssertEqual(
            CommandLineTool.status(sourcePath: source, destinationPath: destination), .conflict)
    }

    func testInstallCommandCreatesAndUpdatesOnlyLeylineSymlinks() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Leyline's.app/Contents/Helpers/ley").path
        let destination = root.appendingPathComponent("bin/ley").path
        try executable(at: source)

        XCTAssertEqual(
            run(CommandLineTool.installCommand(sourcePath: source, destinationPath: destination)), 0
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination), source)

        try FileManager.default.removeItem(atPath: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination,
            withDestinationPath: "/Volumes/Old/Leyline.app/Contents/Helpers/ley")
        XCTAssertEqual(
            run(CommandLineTool.installCommand(sourcePath: source, destinationPath: destination)), 0
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination), source)

        try FileManager.default.removeItem(atPath: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination, withDestinationPath: "/tmp/someone-elses-ley")
        XCTAssertEqual(
            run(CommandLineTool.installCommand(sourcePath: source, destinationPath: destination)),
            73)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination),
            "/tmp/someone-elses-ley")

        try FileManager.default.removeItem(atPath: destination)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: destination))
        XCTAssertEqual(
            run(CommandLineTool.installCommand(sourcePath: source, destinationPath: destination)),
            73)
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "mine")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func executable(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func run(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
