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

enum StepID: String {
    case updatePbxproj
    case initFFI
    case clearSPMCaches
    case clearDerivedData
    case resolvePackages
}

struct SwitcherStep: Identifiable {
    let id: StepID
    let title: String
    var state: StepState = .pending
}

struct SwitcherConfig: Codable {
    var projectDirPath: String?
    var sdkPath: String?

    static let filePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.sdkswitcher_config.json"
    }()

    static func load() -> SwitcherConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let config = try? JSONDecoder().decode(SwitcherConfig.self, from: data) else {
            return SwitcherConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: SwitcherConfig.filePath))
    }
}

class SwitcherViewModel: ObservableObject {
    @Published var steps: [SwitcherStep] = []
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var currentMode: SDKMode = .unknown
    @Published var projectDirPath: String?
    @Published var sdkPath: String?
    @Published var stepOutputs: [StepID: String] = [:]
    @Published var selectedStep: StepID?
    @Published var isCancelled = false

    private var runningProcess: Process?

    private let remoteURL = "https://github.com/zcash/zcash-swift-wallet-sdk"
    private let sdkName = "zcash-swift-wallet-sdk"

    private var pbxprojPath: String? {
        guard let projectDirPath else { return nil }
        return "\(projectDirPath)/secant.xcodeproj/project.pbxproj"
    }

    var isConfigured: Bool {
        pbxprojPath != nil && sdkPath != nil
    }

    var selectedStepOutput: String? {
        guard let selectedStep, let output = stepOutputs[selectedStep], !output.isEmpty else { return nil }
        return output
    }

    func selectStep(_ stepID: StepID) {
        guard let step = steps.first(where: { $0.id == stepID }),
              step.state != .pending else { return }
        selectedStep = stepID
    }

    @MainActor
    func cancelRun() {
        isCancelled = true
        runningProcess?.terminate()
    }

    init() {
        let config = SwitcherConfig.load()
        self.projectDirPath = config.projectDirPath
        self.sdkPath = config.sdkPath
        detectCurrentMode()
    }

    func setProjectDirPath(_ path: String) {
        projectDirPath = path
        saveConfig()
        detectCurrentMode()
    }

    func setSDKPath(_ path: String) {
        sdkPath = path
        saveConfig()
        detectCurrentMode()
    }

    private func saveConfig() {
        var config = SwitcherConfig()
        config.projectDirPath = projectDirPath
        config.sdkPath = sdkPath
        config.save()
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
        guard let pbxprojPath,
              let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
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
        guard let pbxprojPath, let sdkPath else {
            errorMessage = "Project path and SDK path must be configured first."
            return
        }

        errorMessage = nil
        stepOutputs = [:]
        selectedStep = nil
        isCancelled = false
        isRunning = true

        var stepList: [SwitcherStep] = [
            SwitcherStep(id: .updatePbxproj, title: "Update project.pbxproj"),
            SwitcherStep(id: .initFFI, title: mode == .local ? "Init local FFI" : "Skip FFI init"),
            SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"),
            SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"),
            SwitcherStep(id: .resolvePackages, title: "Resolve packages"),
        ]
        steps = stepList

        Task { @MainActor in
            do {
                for i in stepList.indices {
                    guard !isCancelled else { break }

                    stepList[i].state = .running
                    currentStepID = stepList[i].id
                    selectedStep = stepList[i].id
                    steps = stepList

                    switch stepList[i].id {
                    case .updatePbxproj:
                        try updatePbxproj(to: mode, pbxprojPath: pbxprojPath, sdkPath: sdkPath)
                        stepList[i].state = .done

                    case .initFFI:
                        if mode == .local {
                            let localPackagesPath = "\(sdkPath)/LocalPackages"
                            if !FileManager.default.fileExists(atPath: localPackagesPath) {
                                try await runShell(
                                    "\(sdkPath)/Scripts/init-local-ffi.sh",
                                    args: ["--cached"],
                                    workingDir: sdkPath
                                )
                                stepList[i].state = .done
                            } else {
                                stepList[i].state = .skipped
                            }
                        } else {
                            stepList[i].state = .skipped
                        }

                    case .clearSPMCaches:
                        try clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try clearDerivedData()
                        stepList[i].state = .done

                    case .resolvePackages:
                        let projectDir = (pbxprojPath as NSString)
                            .deletingLastPathComponent  // secant.xcodeproj
                            .appending("/..")           // secant-ios-wallet
                        try await runShell(
                            "/usr/bin/xcodebuild",
                            args: ["-resolvePackageDependencies", "-project",
                                   (pbxprojPath as NSString).deletingLastPathComponent],
                            workingDir: projectDir
                        )
                        stepList[i].state = .done
                    }

                    steps = stepList
                }

                if !isCancelled {
                    currentMode = mode
                }
            } catch {
                if let idx = stepList.firstIndex(where: { $0.state == .running }) {
                    stepList[idx].state = .failed
                    steps = stepList
                }
                if !isCancelled {
                    errorMessage = error.localizedDescription
                }
            }

            if isCancelled {
                if let idx = stepList.firstIndex(where: { $0.state == .running }) {
                    stepList[idx].state = .failed
                    steps = stepList
                }
                errorMessage = "Cancelled"
            }

            runningProcess = nil
            isRunning = false
        }
    }

    // MARK: - pbxproj manipulation

    private func updatePbxproj(to mode: SDKMode, pbxprojPath: String, sdkPath: String) throws {
        var contents = try String(contentsOfFile: pbxprojPath, encoding: .utf8)

        guard let refID = findPackageRefID(in: contents) else {
            throw NSError(domain: "SDKSwitcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not find SDK package reference ID in project.pbxproj"])
        }

        switch mode {
        case .local:
            contents = switchToLocal(contents, refID: refID)
        case .remote:
            contents = try switchToRemote(contents, refID: refID, sdkPath: sdkPath)
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

    private func switchToRemote(_ contents: String, refID: String, sdkPath: String) throws -> String {
        var result = contents

        let version = try detectLatestSDKVersion(sdkPath: sdkPath)

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

    private func detectLatestSDKVersion(sdkPath: String) throws -> String {
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
        let cacheDirs = [
            "\(home)/Library/Caches/org.swift.swiftpm",
            "\(home)/Library/org.swift.swiftpm"
        ]

        for cacheDir in cacheDirs {
            // Remove repositories/zcash-swift-wallet-sdk-* directories
            let reposDir = "\(cacheDir)/repositories"
            if fm.fileExists(atPath: reposDir),
               let items = try? fm.contentsOfDirectory(atPath: reposDir) {
                for item in items where item.hasPrefix("zcash-swift-wallet-sdk") {
                    try fm.removeItem(atPath: "\(reposDir)/\(item)")
                }
            }

            // Remove manifests/ManifestLoading/zcash-swift-wallet-sdk.dia
            let manifestFile = "\(cacheDir)/manifests/ManifestLoading/zcash-swift-wallet-sdk.dia"
            if fm.fileExists(atPath: manifestFile) {
                try fm.removeItem(atPath: manifestFile)
            }

            // Remove artifacts/*_zcash_zcash_swift_wallet_sdk_*
            let artifactsDir = "\(cacheDir)/artifacts"
            if fm.fileExists(atPath: artifactsDir),
               let items = try? fm.contentsOfDirectory(atPath: artifactsDir) {
                for item in items where item.contains("_zcash_zcash_swift_wallet_sdk_") {
                    try fm.removeItem(atPath: "\(artifactsDir)/\(item)")
                }
            }
        }
    }

    private func clearDerivedData() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let derivedDataDir = "\(home)/Library/Developer/Xcode/DerivedData"

        if fm.fileExists(atPath: derivedDataDir),
           let items = try? fm.contentsOfDirectory(atPath: derivedDataDir) {
            for item in items where item.hasPrefix("secant-") {
                try fm.removeItem(atPath: "\(derivedDataDir)/\(item)")
            }
        }
    }

    private var currentStepID: StepID?

    @MainActor
    private func appendShellOutput(_ text: String) {
        guard let stepID = currentStepID else { return }
        stepOutputs[stepID, default: ""] += text
    }

    private func runShell(_ executable: String, args: [String], workingDir: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [weak self] in
                let process = Process()
                Task { @MainActor in self?.runningProcess = process }
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)

                var env = ProcessInfo.processInfo.environment
                if let cargoEnv = env["HOME"] {
                    env["PATH"] = (env["PATH"] ?? "") + ":\(cargoEnv)/.cargo/bin"
                }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let handleOutput = { (pipe: Pipe) in
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                        Task { @MainActor in
                            self?.appendShellOutput(line)
                        }
                    }
                }
                handleOutput(stdoutPipe)
                handleOutput(stderrPipe)

                do {
                    try process.run()
                    process.waitUntilExit()

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let name = URL(fileURLWithPath: executable).lastPathComponent
                        continuation.resume(throwing: NSError(
                            domain: "SDKSwitcher",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "\(name) exited with code \(process.terminationStatus)"]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
