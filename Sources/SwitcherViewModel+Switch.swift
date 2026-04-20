//
//  SwitcherViewModel+Switch.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

extension SwitcherViewModel {
    @MainActor
    func switchTo(_ mode: SDKMode) {
        guard !isRunning else { return }
        guard mode != currentMode else { return }
        guard let pbxprojPath, let sdkPath, let projectDirPath else {
            errorMessage = "Project path and SDK path must be configured first."
            return
        }

        errorMessage = nil
        stepOutputs = [:]
        selectedStep = nil
        isCancelled = false
        isRunning = true

        var stepList: [SwitcherStep]
        if mode == .local {
            stepList = [
                SwitcherStep(id: .readRef, title: "Read .zodl-sdk-ref.json"),
                SwitcherStep(id: .verifySDK, title: "Verify SDK directory"),
                SwitcherStep(id: .shortCircuit, title: "Check if already in sync"),
                SwitcherStep(id: .ensureRemote, title: "Register remote"),
                SwitcherStep(id: .fetchRemote, title: "Fetch remote"),
                SwitcherStep(id: .checkoutBranch, title: "Checkout branch"),
                SwitcherStep(id: .updatePbxproj, title: "Update project.pbxproj"),
                SwitcherStep(id: .initFFI, title: "Init local FFI"),
                SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"),
                SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"),
                SwitcherStep(id: .resolvePackages, title: "Resolve packages"),
            ]
        } else {
            stepList = [
                SwitcherStep(id: .updatePbxproj, title: "Update project.pbxproj"),
                SwitcherStep(id: .initFFI, title: "Skip FFI init"),
                SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"),
                SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"),
                SwitcherStep(id: .resolvePackages, title: "Resolve packages"),
            ]
        }
        steps = stepList

        Task { @MainActor in
            do {
                var ref: SDKRef?
                var remoteName: String?
                var skipRemainingGitSync = false

                for i in stepList.indices {
                    guard !isCancelled else { break }

                    stepList[i].state = .running
                    currentStepID = stepList[i].id
                    selectedStep = stepList[i].id
                    steps = stepList

                    switch stepList[i].id {
                    case .readRef:
                        if let loaded = try readSDKRef(projectDirPath: projectDirPath) {
                            ref = loaded
                            appendShellOutput("repoURL: \(loaded.repoURL)\nbranch:  \(loaded.branch)\n")
                        } else {
                            appendShellOutput("No local SDK ref recorded; skipping git sync steps.\n")
                            skipRemainingGitSync = true
                        }
                        stepList[i].state = .done

                    case .verifySDK:
                        if skipRemainingGitSync {
                            stepList[i].state = .skipped
                        } else {
                            try verifySDKDirectory(sdkPath: sdkPath)
                            stepList[i].state = .done
                        }

                    case .shortCircuit:
                        if skipRemainingGitSync {
                            stepList[i].state = .skipped
                        } else {
                            guard let ref else { throw syncError("Internal: ref missing at short-circuit step.") }
                            if try isAlreadyInSync(sdkPath: sdkPath, ref: ref) {
                                appendShellOutput("Already in sync.\n")
                                skipRemainingGitSync = true
                            }
                            stepList[i].state = .done
                        }

                    case .ensureRemote:
                        if skipRemainingGitSync {
                            stepList[i].state = .skipped
                        } else {
                            guard let ref else { throw syncError("Internal: ref missing at ensure-remote step.") }
                            let name = try ensureRemoteRegistered(sdkPath: sdkPath, repoURL: ref.repoURL)
                            remoteName = name
                            appendShellOutput("Using remote `\(name)` for \(ref.repoURL)\n")
                            stepList[i].state = .done
                        }

                    case .fetchRemote:
                        if skipRemainingGitSync {
                            stepList[i].state = .skipped
                        } else {
                            guard let remoteName else { throw syncError("Internal: remote name missing at fetch step.") }
                            try await runShell("/usr/bin/git", args: ["fetch", remoteName], workingDir: sdkPath)
                            stepList[i].state = .done
                        }

                    case .checkoutBranch:
                        if skipRemainingGitSync {
                            stepList[i].state = .skipped
                        } else {
                            guard let ref, let remoteName else {
                                throw syncError("Internal: ref or remote name missing at checkout step.")
                            }
                            try await alignBranch(sdkPath: sdkPath, remoteName: remoteName, branch: ref.branch)
                            stepList[i].state = .done
                        }

                    case .updatePbxproj:
                        try updatePbxproj(to: mode, pbxprojPath: pbxprojPath, sdkPath: sdkPath)
                        stepList[i].state = .done

                    case .initFFI:
                        if mode == .local {
                            try await runShell(
                                "\(sdkPath)/Scripts/init-local-ffi.sh",
                                args: ["--cached"],
                                workingDir: sdkPath
                            )
                            stepList[i].state = .done
                        } else {
                            stepList[i].state = .skipped
                        }

                    case .clearSPMCaches:
                        try await clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try await clearDerivedData()
                        stepList[i].state = .done

                    case .resolvePackages:
                        try await runShell(
                            "/usr/bin/xcodebuild",
                            args: ["-resolvePackageDependencies", "-project", "\(projectDirPath)/secant.xcodeproj"],
                            workingDir: projectDirPath
                        )
                        stepList[i].state = .done
                    }

                    steps = stepList
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

            refreshDetectedState()
            runningProcess = nil
            isRunning = false
        }
    }

    // MARK: - pbxproj manipulation

    /// Finds the pbxproj object ID for the SDK package reference (local or remote)
    func findPackageRefID(in contents: String) -> String? {
        // Match either XCLocalSwiftPackageReference or XCRemoteSwiftPackageReference for our SDK
        let pattern = "([A-F0-9]{24}) /\\* XC(?:Local|Remote)SwiftPackageReference \"(?:\\.\\./)?zcash-swift-wallet-sdk\" \\*/ = \\{"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let idRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return String(contents[idRange])
    }

    func updatePbxproj(to mode: SDKMode, pbxprojPath: String, sdkPath: String) throws {
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
}
