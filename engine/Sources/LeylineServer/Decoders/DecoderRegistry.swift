// SPDX-License-Identifier: GPL-3.0-or-later

// Decoder discovery: directories of manifests, read and never executed.
//
// A plugin is a directory holding `manifest.json`, the proto3 JSON form of `DecoderManifest`
// (docs/design/decoders.md, "Decisions": "Manifest: a file, not a flag"). Discovery reads files
// and runs nothing, so a plugin whose binary is broken still lists, and a manifest that does not
// parse costs a log line rather than the whole registry.

import EngineCore
import Foundation
import LeylineProto
import Logging
import SwiftProtobuf

struct DecoderRegistry: Sendable {
    /// One decoder as found on disk: its manifest, the directory it was found in, and the
    /// program the daemon would spawn.
    struct Installed: Sendable {
        var manifest: Leyline_V1_DecoderManifest
        /// The directory the manifest was read from; the plugin's cwd when it runs.
        var directory: String
        /// Absolute path of the executable, resolved against the directory, the program
        /// directories or `PATH`.
        var executablePath: String
    }

    /// Directories to look in, in order. The first manifest with a given name wins: a decoder
    /// dropped in a `--decoders` directory shadows the one the platform default ships.
    let searchPath: [String]
    /// Directories a manifest's bare `executable` name is looked up in after the plugin's own
    /// directory and before `PATH`: `leylined`'s directory, where an app bundle keeps the decoder
    /// executables beside the daemon (`bundledDecodersPath`).
    let programDirectories: [String]
    private let log = Logger(label: "leyline.decoders")

    init(searchPath: [String], programDirectories: [String] = DecoderRegistry.daemonDirectory()) {
        self.searchPath = searchPath
        self.programDirectories = programDirectories
    }

    /// The directory of the running `leylined`, or nothing when it cannot be found.
    static func daemonDirectory() -> [String] {
        guard let exe = currentExecutablePath() else { return [] }
        return [URL(fileURLWithPath: exe).deletingLastPathComponent().path]
    }

    func scan() -> [Installed] {
        var out: [Installed] = []
        var seen: Set<String> = []
        for dir in searchPath {
            for sub in subdirectories(of: dir) {
                guard let installed = read(directory: sub) else { continue }
                guard seen.insert(installed.manifest.name).inserted else {
                    log.debug("decoder \(installed.manifest.name) in \(sub) is shadowed by an earlier one")
                    continue
                }
                out.append(installed)
            }
        }
        return out
    }

    func find(_ name: String) -> Installed? {
        scan().first { $0.manifest.name == name }
    }

    /// Every directory directly under `dir`, plus `dir` itself when it holds a manifest: a search
    /// path can name a directory of plugins or a single plugin.
    private func subdirectories(of dir: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if fm.fileExists(atPath: dir + "/manifest.json") { out.append(dir) }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return out }
        for name in names.sorted() {
            var isDir: ObjCBool = false
            let path = dir + "/" + name
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                out.append(path)
            }
        }
        return out
    }

    private func read(directory: String) -> Installed? {
        let path = directory + "/manifest.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var options = JSONDecodingOptions()
        // A manifest written against a newer contract still lists what this daemon understands.
        options.ignoreUnknownFields = true
        let manifest: Leyline_V1_DecoderManifest
        do {
            manifest = try Leyline_V1_DecoderManifest(jsonUTF8Bytes: data, options: options)
        } catch {
            log.warning("\(path): manifest does not parse (\(error)); skipping")
            return nil
        }
        guard !manifest.name.isEmpty else {
            log.warning("\(path): manifest has no name; skipping")
            return nil
        }
        guard !manifest.executable.isEmpty, let exe = resolve(manifest.executable, in: directory) else {
            log.warning("\(path): \(manifest.name) names no executable this daemon can find; skipping")
            return nil
        }
        return Installed(manifest: manifest, directory: directory, executablePath: exe)
    }

    /// The manifest's `executable` as a path relative to the plugin's directory, else a name in
    /// the program directories or on `PATH`. An absolute path is taken as it stands.
    private func resolve(_ executable: String, in directory: String) -> String? {
        let fm = FileManager.default
        if executable.hasPrefix("/") {
            return fm.isExecutableFile(atPath: executable) ? executable : nil
        }
        let local = directory + "/" + executable
        if fm.isExecutableFile(atPath: local) { return local }
        guard !executable.contains("/") else { return nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = programDirectories + path.split(separator: ":").map(String.init)
        for dir in dirs where !dir.isEmpty {
            let candidate = String(dir) + "/" + executable
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
