//
//  SwitcherViewModel+Sync.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

extension SwitcherViewModel {
    @MainActor
    func syncSDK() {
        guard !isRunning else { return }
        guard let projectDirPath, let sdkPath else {
            errorMessage = "Project path and SDK path must be configured first."
            return
        }

        let stepList: [SwitcherStep] = [
            SwitcherStep(id: .readRef, title: "Read .zodl-sdk-ref.json"),
            SwitcherStep(id: .verifySDK, title: "Verify SDK directory"),
            SwitcherStep(id: .shortCircuit, title: "Check if already in sync"),
            SwitcherStep(id: .ensureRemote, title: "Register remote"),
            SwitcherStep(id: .fetchRemote, title: "Fetch remote"),
            SwitcherStep(id: .checkoutBranch, title: "Checkout branch"),
            SwitcherStep(id: .initFFI, title: "Init local FFI"),
            SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"),
            SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"),
            SwitcherStep(id: .resolvePackages, title: "Resolve packages"),
        ]

        Task { @MainActor in
            var ref: SDKRef?
            var remoteName: String?

            await runPipeline(stepList) { stepID in
                switch stepID {
                case .readRef:
                    guard let loaded = try performReadRef(projectDirPath: projectDirPath) else {
                        appendShellOutput("No local SDK ref recorded; nothing to sync.\n")
                        return .halt
                    }
                    ref = loaded
                    return .done

                case .verifySDK:
                    try verifySDKDirectory(sdkPath: sdkPath)
                    return .done

                case .shortCircuit:
                    guard let ref else { throw syncError("Internal: ref missing at short-circuit step.") }
                    if try performShortCircuit(sdkPath: sdkPath, ref: ref) {
                        return .halt
                    }
                    return .done

                case .ensureRemote:
                    guard let ref else { throw syncError("Internal: ref missing at ensure-remote step.") }
                    remoteName = try performEnsureRemote(sdkPath: sdkPath, ref: ref)
                    return .done

                case .fetchRemote:
                    guard let remoteName else { throw syncError("Internal: remote name missing at fetch step.") }
                    try await performFetchRemote(sdkPath: sdkPath, remoteName: remoteName)
                    return .done

                case .checkoutBranch:
                    guard let ref, let remoteName else {
                        throw syncError("Internal: ref or remote name missing at checkout step.")
                    }
                    try await performCheckoutBranch(sdkPath: sdkPath, remoteName: remoteName, branch: ref.branch)
                    return .done

                case .initFFI:
                    try await performInitFFI(sdkPath: sdkPath)
                    return .done

                case .clearSPMCaches:
                    try await clearSPMCaches()
                    return .done

                case .clearDerivedData:
                    try await clearDerivedData()
                    return .done

                case .resolvePackages:
                    try await performResolvePackages(projectDirPath: projectDirPath)
                    return .done

                case .updatePbxproj:
                    return .skipped
                }
            }
        }
    }

    // MARK: - Sync helpers

    func readSDKRef(projectDirPath: String) throws -> SDKRef? {
        let path = "\(projectDirPath)/.zodl-sdk-ref.json"
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw syncError("Invalid .zodl-sdk-ref.json: expected a JSON object.")
        }
        if dict.isEmpty {
            return nil
        }
        guard let repoURL = dict["repoURL"] as? String, !repoURL.isEmpty,
              let branch = dict["branch"] as? String, !branch.isEmpty else {
            throw syncError("Invalid .zodl-sdk-ref.json: missing repoURL or branch.")
        }
        return SDKRef(repoURL: repoURL, branch: branch)
    }

    func verifySDKDirectory(sdkPath: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sdkPath, isDirectory: &isDir), isDir.boolValue else {
            throw syncError("SDK path `\(sdkPath)` does not exist. Clone the SDK before syncing.")
        }
        guard FileManager.default.fileExists(atPath: "\(sdkPath)/.git") else {
            throw syncError("SDK path `\(sdkPath)` is not a git repository.")
        }
        let status = try gitCapture(["status", "--porcelain"], cwd: sdkPath)
        if !status.isEmpty {
            throw syncError("Uncommitted changes in `\(sdkPath)`. Commit or stash before syncing.")
        }
    }

    func isAlreadyInSync(sdkPath: String, ref: SDKRef) throws -> Bool {
        let currentBranch = try gitCapture(["branch", "--show-current"], cwd: sdkPath)
        guard currentBranch == ref.branch else { return false }

        let normalizedRef = normalizeGitURL(ref.repoURL)
        let remotes = try gitCapture(["remote"], cwd: sdkPath)
            .split(separator: "\n")
            .map(String.init)

        for remote in remotes {
            let url = try gitCapture(["remote", "get-url", remote], cwd: sdkPath)
            guard normalizeGitURL(url) == normalizedRef else { continue }

            let remoteRef = "\(remote)/\(ref.branch)"
            guard let remoteSHA = try? gitCapture(["rev-parse", remoteRef], cwd: sdkPath) else {
                continue
            }
            let headSHA = try gitCapture(["rev-parse", "HEAD"], cwd: sdkPath)
            if remoteSHA == headSHA {
                return true
            }
        }
        return false
    }

    func ensureRemoteRegistered(sdkPath: String, repoURL: String) throws -> String {
        let normalizedTarget = normalizeGitURL(repoURL)
        let remotes = try gitCapture(["remote"], cwd: sdkPath)
            .split(separator: "\n")
            .map(String.init)

        for remote in remotes {
            let url = try gitCapture(["remote", "get-url", remote], cwd: sdkPath)
            if normalizeGitURL(url) == normalizedTarget {
                return remote
            }
        }

        let derivedName = deriveRemoteName(from: repoURL)
        if remotes.contains(derivedName) {
            let existingURL = try gitCapture(["remote", "get-url", derivedName], cwd: sdkPath)
            throw syncError(
                "Remote `\(derivedName)` already exists and points to `\(existingURL)`, "
                + "not `\(repoURL)`. Rename or remove the existing remote and retry."
            )
        }

        _ = try gitCapture(["remote", "add", derivedName, repoURL], cwd: sdkPath)
        return derivedName
    }

    func alignBranch(sdkPath: String, remoteName: String, branch: String) async throws {
        let remoteRef = "\(remoteName)/\(branch)"
        let remoteSHA = try gitCapture(["rev-parse", remoteRef], cwd: sdkPath)
        let currentBranch = try gitCapture(["branch", "--show-current"], cwd: sdkPath)

        if currentBranch == branch {
            let headSHA = try gitCapture(["rev-parse", "HEAD"], cwd: sdkPath)
            if headSHA == remoteSHA { return }
            throw syncError(
                "Local branch `\(branch)` exists and differs from `\(remoteRef)`. "
                + "Resolve manually (delete or rebase the local branch) and retry."
            )
        }

        if localBranchExists(branch, sdkPath: sdkPath) {
            let localSHA = try gitCapture(["rev-parse", "refs/heads/\(branch)"], cwd: sdkPath)
            if localSHA != remoteSHA {
                throw syncError(
                    "Local branch `\(branch)` exists and differs from `\(remoteRef)`. "
                    + "Resolve manually (delete or rebase the local branch) and retry."
                )
            }
            try await runShell("/usr/bin/git", args: ["checkout", branch], workingDir: sdkPath)
        } else {
            try await runShell("/usr/bin/git", args: ["checkout", "-b", branch, remoteRef], workingDir: sdkPath)
        }
    }

    private func localBranchExists(_ branch: String, sdkPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]
        process.currentDirectoryURL = URL(fileURLWithPath: sdkPath)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func normalizeGitURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix(".git") {
            result = String(result.dropLast(4))
        }
        if result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result.lowercased()
    }

    private func deriveRemoteName(from url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        if let schemeRange = trimmed.range(of: "://") {
            trimmed = String(trimmed[schemeRange.upperBound...])
            // Drop host: everything up to first '/'
            if let slash = trimmed.firstIndex(of: "/") {
                trimmed = String(trimmed[trimmed.index(after: slash)...])
            }
        } else if trimmed.hasPrefix("git@"), let colon = trimmed.firstIndex(of: ":") {
            trimmed = String(trimmed[trimmed.index(after: colon)...])
        }

        let firstSegment = trimmed.split(separator: "/").first.map(String.init) ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        let mapped = firstSegment.lowercased().map { allowed.contains($0) ? $0 : Character("-") }
        let name = String(mapped)
        return name.isEmpty ? "fork" : name
    }
}
