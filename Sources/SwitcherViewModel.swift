//
//  SwitcherViewModel.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import SwiftUI
import Foundation
import Combine

enum SDKMode: String {
    case local   = "local"
    case remote  = "remote"
    case unknown = "unknown"
}

enum StepState {
    case pending, running, done, skipped, failed
}

struct SwitcherStep: Identifiable {
    let id = UUID()
    let title: String
    var state: StepState = .pending
}

class SwitcherViewModel: ObservableObject {
    @Published var steps: [SwitcherStep] = []
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var currentMode: SDKMode = .unknown

    // Paths — adjust if your setup differs
    private let pbxprojPath = "/Users/lukaskorba/Dev/Xcode/GitHub/LukasKorba/secant-ios-wallet/secant.xcodeproj/project.pbxproj"
    private let sdkPath = "/Users/lukaskorba/Dev/Xcode/GitHub/LukasKorba/zcash-swift-wallet-sdk"
    private let remoteURL = "https://github.com/zcash/zcash-swift-wallet-sdk"
    private let sdkName = "zcash-swift-wallet-sdk"

    init() {
        detectCurrentMode()
    }

    // MARK: - Find the Xcode object ID dynamically

    /// Finds the pbxproj object ID for the SDK package reference (local or remote)
    private func findPackageRefID(in contents: String) -> String? {
        // Match either XCLocalSwiftPackageReference or XCRemoteSwiftPackageReference for our SDK
        let pattern = "([A-F0-9]{24}) /\\* XC(?:Local|Remote)SwiftPackageReference \"(?:\\.\\./)?zcash-swift-wallet-sdk\" \\*/ = \\{"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let idRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return String(contents[idRange])
    }

    @MainActor
    func detectCurrentMode() {
        guard let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            currentMode = .unknown
            return
        }

        if contents.contains("XCLocalSwiftPackageReference \"../\(sdkName)\"") {
            currentMode = .local
        } else if contents.contains("XCRemoteSwiftPackageReference \"\(sdkName)\"")
                    && contents.contains(remoteURL) {
            currentMode = .remote
        } else {
            currentMode = .unknown
        }
    }

    @MainActor
    func switchTo(_ mode: SDKMode) {
        guard !isRunning else { return }
        guard mode != currentMode else { return }

        errorMessage = nil
        isRunning = true

        var stepList: [SwitcherStep] = [
            SwitcherStep(title: "Update project.pbxproj"),
            SwitcherStep(title: mode == .local ? "Init local FFI" : "Skip FFI init"),
            SwitcherStep(title: "Clear SPM caches"),
            SwitcherStep(title: "Resolve packages"),
        ]
        steps = stepList

        Task { @MainActor in
            do {
                // Step 0: Update project.pbxproj
                stepList[0].state = .running
                steps = stepList
                try updatePbxproj(to: mode)
                stepList[0].state = .done
                steps = stepList

                // Step 1: Init local FFI (local mode only)
                stepList[1].state = .running
                steps = stepList
                if mode == .local {
                    let localPackagesPath = "\(sdkPath)/LocalPackages"
                    if !FileManager.default.fileExists(atPath: localPackagesPath) {
                        try await runShell(
                            "\(sdkPath)/Scripts/init-local-ffi.sh",
                            args: ["--cached"],
                            workingDir: sdkPath
                        )
                        stepList[1].state = .done
                    } else {
                        stepList[1].state = .skipped
                    }
                } else {
                    stepList[1].state = .skipped
                }
                steps = stepList

                // Step 2: Clear SPM caches
                stepList[2].state = .running
                steps = stepList
                try clearSPMCaches()
                stepList[2].state = .done
                steps = stepList

                // Step 3: Resolve packages
                stepList[3].state = .running
                steps = stepList
                let projectDir = (pbxprojPath as NSString)
                    .deletingLastPathComponent  // secant.xcodeproj
                    .appending("/..")           // secant-ios-wallet
                try await runShell(
                    "/usr/bin/xcodebuild",
                    args: ["-resolvePackageDependencies", "-project",
                           (pbxprojPath as NSString).deletingLastPathComponent],
                    workingDir: projectDir
                )
                stepList[3].state = .done
                steps = stepList

                currentMode = mode
            } catch {
                if let idx = stepList.firstIndex(where: { $0.state == .running }) {
                    stepList[idx].state = .failed
                    steps = stepList
                }
                errorMessage = error.localizedDescription
            }

            isRunning = false
        }
    }

    // MARK: - pbxproj manipulation

    private func updatePbxproj(to mode: SDKMode) throws {
        var contents = try String(contentsOfFile: pbxprojPath, encoding: .utf8)

        guard let refID = findPackageRefID(in: contents) else {
            throw NSError(domain: "SDKSwitcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not find SDK package reference ID in project.pbxproj"])
        }

        switch mode {
        case .local:
            contents = switchToLocal(contents, refID: refID)
        case .remote:
            contents = try switchToRemote(contents, refID: refID)
        case .unknown:
            return
        }

        try contents.write(toFile: pbxprojPath, atomically: true, encoding: .utf8)
    }

    private func switchToLocal(_ contents: String, refID: String) -> String {
        var result = contents

        // 1. Remove the remote definition entry FIRST (before comments change)
        let remoteDefPattern = "\t\t\(refID) /\\* XCRemoteSwiftPackageReference \"\(sdkName)\" \\*/ = \\{[\\s\\S]*?\\n\t\t\\};\n"
        if let regex = try? NSRegularExpression(pattern: remoteDefPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 2. Replace comments in packageReferences list and product dependencies
        result = result.replacingOccurrences(
            of: "\(refID) /* XCRemoteSwiftPackageReference \"\(sdkName)\" */",
            with: "\(refID) /* XCLocalSwiftPackageReference \"../\(sdkName)\" */"
        )

        // 3. Insert local definition
        let localDef = "\t\t\(refID) /* XCLocalSwiftPackageReference \"../\(sdkName)\" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = \"../\(sdkName)\";\n\t\t};\n"

        if result.contains("/* Begin XCLocalSwiftPackageReference section */") {
            result = result.replacingOccurrences(
                of: "/* End XCLocalSwiftPackageReference section */",
                with: localDef + "/* End XCLocalSwiftPackageReference section */"
            )
        } else {
            let localSection = "/* Begin XCLocalSwiftPackageReference section */\n" + localDef + "/* End XCLocalSwiftPackageReference section */\n\n"
            result = result.replacingOccurrences(
                of: "/* Begin XCRemoteSwiftPackageReference section */",
                with: localSection + "/* Begin XCRemoteSwiftPackageReference section */"
            )
        }

        return result
    }

    private func switchToRemote(_ contents: String, refID: String) throws -> String {
        var result = contents

        let version = try detectLatestSDKVersion()

        // 1. Remove the local definition entry FIRST (before comments change)
        let localDefPattern = "\t\t\(refID) /\\* XCLocalSwiftPackageReference \"\\.\\./\(sdkName)\" \\*/ = \\{[\\s\\S]*?\\n\t\t\\};\n"
        if let regex = try? NSRegularExpression(pattern: localDefPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 2. Replace comments in packageReferences list and product dependencies
        result = result.replacingOccurrences(
            of: "\(refID) /* XCLocalSwiftPackageReference \"../\(sdkName)\" */",
            with: "\(refID) /* XCRemoteSwiftPackageReference \"\(sdkName)\" */"
        )

        // Remove empty XCLocalSwiftPackageReference section if it's now empty
        let emptySectionPattern = "/\\* Begin XCLocalSwiftPackageReference section \\*/\n/\\* End XCLocalSwiftPackageReference section \\*/\n\n?"
        if let regex = try? NSRegularExpression(pattern: emptySectionPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 3. Insert remote definition
        let remoteDef = "\t\t\(refID) /* XCRemoteSwiftPackageReference \"\(sdkName)\" */ = {\n\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = \"\(remoteURL)\";\n\t\t\trequirement = {\n\t\t\t\tkind = upToNextMinorVersion;\n\t\t\t\tminimumVersion = \(version);\n\t\t\t};\n\t\t};\n"

        result = result.replacingOccurrences(
            of: "/* End XCRemoteSwiftPackageReference section */",
            with: remoteDef + "/* End XCRemoteSwiftPackageReference section */"
        )

        return result
    }

    private func detectLatestSDKVersion() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["describe", "--tags", "--abbrev=0"]
        process.currentDirectoryURL = URL(fileURLWithPath: sdkPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tag = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if tag.isEmpty {
            throw NSError(domain: "SDKSwitcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not detect SDK version from git tags"])
        }

        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: - Helpers

    private func clearSPMCaches() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/Library/Caches/org.swift.swiftpm",
            "\(home)/Library/org.swift.swiftpm"
        ]
        for path in paths {
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
        }
    }

    private func runShell(_ executable: String, args: [String], workingDir: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)

                var env = ProcessInfo.processInfo.environment
                if let cargoEnv = env["HOME"] {
                    env["PATH"] = (env["PATH"] ?? "") + ":\(cargoEnv)/.cargo/bin"
                }
                process.environment = env

                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let name = URL(fileURLWithPath: executable).lastPathComponent
                        let msg = stderrText.isEmpty
                            ? "\(name) exited with code \(process.terminationStatus)"
                            : "\(name) exited with code \(process.terminationStatus):\n\(stderrText)"
                        continuation.resume(throwing: NSError(
                            domain: "SDKSwitcher",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
