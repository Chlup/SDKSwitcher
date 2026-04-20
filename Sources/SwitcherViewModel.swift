//
//  SwitcherViewModel.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import SwiftUI
import Foundation
import Combine

@MainActor
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
    @Published var currentSDKRef: SDKRef?
    @Published var currentSDKState: SDKLocalState?

    var runningProcess: Process?
    var currentStepID: StepID?

    let remoteURL = "https://github.com/zcash/zcash-swift-wallet-sdk"
    let sdkName = "zcash-swift-wallet-sdk"

    // Reactive observation — file watchers + periodic timer both feed
    // refreshDetectedState() through a 500 ms debounce.
    private var refFileWatcher: FileWatcher?
    private var gitHeadWatcher: FileWatcher?
    private var refreshTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private let pollInterval: TimeInterval = 300  // 5 minutes

    var pbxprojPath: String? {
        guard let projectDirPath else { return nil }
        return "\(projectDirPath)/secant.xcodeproj/project.pbxproj"
    }

    var isConfigured: Bool {
        pbxprojPath != nil && sdkPath != nil
    }

    var statusText: String {
        if let runningStep = steps.first(where: { $0.state == .running }) {
            return runningStep.title
        }
        return "Idle"
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
        refreshDetectedState()
        setupWatchers()
        startRefreshTimer()
    }

    func setProjectDirPath(_ path: String) {
        projectDirPath = path
        saveConfig()
        refreshDetectedState()
        setupWatchers()
    }

    func setSDKPath(_ path: String) {
        sdkPath = path
        saveConfig()
        refreshDetectedState()
        setupWatchers()
    }

    @MainActor
    func refreshDetectedState() {
        detectCurrentMode()
        detectCurrentSDKRef()
        detectCurrentSDKState()
    }

    // MARK: - Reactive observation

    private func setupWatchers() {
        refFileWatcher?.tearDown()
        refFileWatcher = nil
        gitHeadWatcher?.tearDown()
        gitHeadWatcher = nil

        if let projectDirPath {
            refFileWatcher = FileWatcher(
                path: "\(projectDirPath)/.zodl-sdk-ref.json",
                onChange: { [weak self] in self?.scheduleDebouncedRefresh() }
            )
        }

        if let sdkPath {
            gitHeadWatcher = FileWatcher(
                path: "\(sdkPath)/.git/HEAD",
                onChange: { [weak self] in self?.scheduleDebouncedRefresh() }
            )
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDetectedState()
            }
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshDetectedState()
            }
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func saveConfig() {
        var config = SwitcherConfig()
        config.projectDirPath = projectDirPath
        config.sdkPath = sdkPath
        config.save()
    }

    // MARK: - Detection

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
    func detectCurrentSDKRef() {
        guard let projectDirPath else {
            currentSDKRef = nil
            return
        }
        currentSDKRef = (try? readSDKRef(projectDirPath: projectDirPath)) ?? nil
    }

    @MainActor
    func detectCurrentSDKState() {
        guard let sdkPath else {
            currentSDKState = nil
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sdkPath, isDirectory: &isDir), isDir.boolValue else {
            currentSDKState = SDKLocalState(
                branch: nil,
                remoteURL: nil,
                isClean: false,
                errorDescription: "SDK path does not exist."
            )
            return
        }

        guard FileManager.default.fileExists(atPath: "\(sdkPath)/.git") else {
            currentSDKState = SDKLocalState(
                branch: nil,
                remoteURL: nil,
                isClean: false,
                errorDescription: "Not a git repository."
            )
            return
        }

        let branchRaw = (try? gitCapture(["branch", "--show-current"], cwd: sdkPath)) ?? ""
        let branch: String? = branchRaw.isEmpty ? nil : branchRaw
        let statusOutput = (try? gitCapture(["status", "--porcelain"], cwd: sdkPath)) ?? ""
        let remoteURL = branch.flatMap { remoteURLForCurrentBranch(sdkPath: sdkPath, branch: $0) }

        currentSDKState = SDKLocalState(
            branch: branch,
            remoteURL: remoteURL,
            isClean: statusOutput.isEmpty,
            errorDescription: nil
        )
    }

    /// Returns the URL of the remote that the current branch was checked out from,
    /// using the same matching logic as `Scripts/update-sdk-ref.sh`:
    ///   1. Primary (SHA match): first remote where `<remote>/<branch>` SHA equals HEAD SHA.
    ///   2. Fallback (name match): exactly one remote has a ref with the current branch name.
    ///   3. Neither: `nil`.
    private func remoteURLForCurrentBranch(sdkPath: String, branch: String) -> String? {
        guard let remotesOutput = try? gitCapture(["remote"], cwd: sdkPath) else {
            return nil
        }
        let remotes = remotesOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        if remotes.isEmpty { return nil }

        if let headSHA = try? gitCapture(["rev-parse", "HEAD"], cwd: sdkPath) {
            for remote in remotes {
                if let remoteSHA = try? gitCapture(["rev-parse", "\(remote)/\(branch)"], cwd: sdkPath),
                   remoteSHA == headSHA {
                    return try? gitCapture(["remote", "get-url", remote], cwd: sdkPath)
                }
            }
        }

        let candidates = remotes.filter { remote in
            (try? gitCapture(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], cwd: sdkPath)) != nil
        }
        if candidates.count == 1 {
            return try? gitCapture(["remote", "get-url", candidates[0]], cwd: sdkPath)
        }

        return nil
    }

    // MARK: - Shell / Git helpers

    func syncError(_ message: String) -> NSError {
        NSError(domain: "SDKSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func gitCapture(_ args: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw syncError("git \(args.joined(separator: " ")) failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func appendShellOutput(_ text: String) {
        guard let stepID = currentStepID else { return }
        stepOutputs[stepID, default: ""] += text
    }

    func runShell(_ executable: String, args: [String], workingDir: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [weak self] in
                let process = Process()
                Task { @MainActor in self?.runningProcess = process }
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)

                var env = ProcessInfo.processInfo.environment
                let home = env["HOME"] ?? NSHomeDirectory()
                let prependedPaths = [
                    "/opt/homebrew/bin",
                    "/opt/homebrew/sbin",
                    "/usr/local/bin",
                    "/usr/local/sbin",
                    "\(home)/.cargo/bin",
                ]
                let existingPATH = env["PATH"] ?? ""
                env["PATH"] = (prependedPaths + [existingPATH]).joined(separator: ":")
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
