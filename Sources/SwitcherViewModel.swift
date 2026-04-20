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
    case readRef
    case verifySDK
    case shortCircuit
    case ensureRemote
    case fetchRemote
    case checkoutBranch
    case initFFI
    case clearSPMCaches
    case clearDerivedData
    case resolvePackages
}

struct SDKRef {
    let repoURL: String
    let branch: String
}

struct SDKLocalState {
    let branch: String?         // nil if detached HEAD
    let remoteURL: String?      // "origin" if present, else first remote
    let isClean: Bool
    let errorDescription: String?
}

/// Reactive file watcher wrapping DispatchSource.makeFileSystemObjectSource.
/// Invokes `onChange` (on the main actor) when the watched file is written to.
/// Handles the common case where the file is atomically replaced (delete+rename)
/// by cancelling the current source and re-opening after a brief delay.
///
/// Resource cleanup requires an explicit `tearDown()` call before the instance
/// is released. Swift 6's `deinit` is always nonisolated, so it cannot touch
/// the main-actor-isolated stored state safely; the owning view model calls
/// `tearDown()` during watcher replacement.
@MainActor
final class FileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var retryTask: Task<Void, Never>?

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        start()
    }

    func tearDown() {
        retryTask?.cancel()
        retryTask = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    private func start() {
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor != -1 else {
            scheduleRetry()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        self.source = source

        // DispatchSource event handlers aren't inferred as `@MainActor`
        // even with `queue: .main`, so we hop explicitly via Task.
        source.setEventHandler { [weak self] in
            guard let source = self?.source else { return }
            let events = source.data
            Task { @MainActor [weak self] in
                self?.handleEvents(events)
            }
        }

        source.setCancelHandler { [fd = fileDescriptor] in
            if fd != -1 { close(fd) }
        }

        source.resume()
    }

    private func handleEvents(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            tearDown()
            onChange()
            scheduleRetry()
        } else {
            onChange()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
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

    private var runningProcess: Process?

    private let remoteURL = "https://github.com/zcash/zcash-swift-wallet-sdk"
    private let sdkName = "zcash-swift-wallet-sdk"

    // Reactive observation — file watchers + periodic timer both feed
    // refreshDetectedState() through a 500 ms debounce.
    private var refFileWatcher: FileWatcher?
    private var gitHeadWatcher: FileWatcher?
    private var refreshTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private let pollInterval: TimeInterval = 300  // 5 minutes

    private var pbxprojPath: String? {
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
                        try clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try clearDerivedData()
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

    // MARK: - Sync SDK

    @MainActor
    func syncSDK() {
        guard !isRunning else { return }
        guard let projectDirPath, let sdkPath else {
            errorMessage = "Project path and SDK path must be configured first."
            return
        }

        errorMessage = nil
        stepOutputs = [:]
        selectedStep = nil
        isCancelled = false
        isRunning = true

        var stepList: [SwitcherStep] = [
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
        steps = stepList

        Task { @MainActor in
            defer {
                refreshDetectedState()
                runningProcess = nil
                isRunning = false
            }

            func markRemainingSkipped(from index: Int) {
                for j in stepList.indices where j > index {
                    stepList[j].state = .skipped
                }
            }

            do {
                var ref: SDKRef?
                var remoteName: String?

                for i in stepList.indices {
                    guard !isCancelled else { break }

                    stepList[i].state = .running
                    currentStepID = stepList[i].id
                    selectedStep = stepList[i].id
                    steps = stepList

                    switch stepList[i].id {
                    case .readRef:
                        guard let loaded = try readSDKRef(projectDirPath: projectDirPath) else {
                            appendShellOutput("No local SDK ref recorded; nothing to sync.\n")
                            stepList[i].state = .done
                            markRemainingSkipped(from: i)
                            steps = stepList
                            return
                        }
                        ref = loaded
                        appendShellOutput("repoURL: \(loaded.repoURL)\nbranch:  \(loaded.branch)\n")
                        stepList[i].state = .done

                    case .verifySDK:
                        try verifySDKDirectory(sdkPath: sdkPath)
                        stepList[i].state = .done

                    case .shortCircuit:
                        guard let ref else { throw syncError("Internal: ref missing at short-circuit step.") }
                        if try isAlreadyInSync(sdkPath: sdkPath, ref: ref) {
                            appendShellOutput("Already in sync.\n")
                            stepList[i].state = .done
                            markRemainingSkipped(from: i)
                            steps = stepList
                            return
                        }
                        stepList[i].state = .done

                    case .ensureRemote:
                        guard let ref else { throw syncError("Internal: ref missing at ensure-remote step.") }
                        let name = try ensureRemoteRegistered(sdkPath: sdkPath, repoURL: ref.repoURL)
                        remoteName = name
                        appendShellOutput("Using remote `\(name)` for \(ref.repoURL)\n")
                        stepList[i].state = .done

                    case .fetchRemote:
                        guard let remoteName else { throw syncError("Internal: remote name missing at fetch step.") }
                        try await runShell("/usr/bin/git", args: ["fetch", remoteName], workingDir: sdkPath)
                        stepList[i].state = .done

                    case .checkoutBranch:
                        guard let ref, let remoteName else {
                            throw syncError("Internal: ref or remote name missing at checkout step.")
                        }
                        try await alignBranch(sdkPath: sdkPath, remoteName: remoteName, branch: ref.branch)
                        stepList[i].state = .done

                    case .initFFI:
                        try await runShell(
                            "\(sdkPath)/Scripts/init-local-ffi.sh",
                            args: ["--cached"],
                            workingDir: sdkPath
                        )
                        stepList[i].state = .done

                    case .clearSPMCaches:
                        try clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try clearDerivedData()
                        stepList[i].state = .done

                    case .resolvePackages:
                        try await runShell(
                            "/usr/bin/xcodebuild",
                            args: ["-resolvePackageDependencies", "-project", "\(projectDirPath)/secant.xcodeproj"],
                            workingDir: projectDirPath
                        )
                        stepList[i].state = .done

                    case .updatePbxproj:
                        stepList[i].state = .skipped
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
        }
    }

    // MARK: - Clean

    @MainActor
    func cleanDerivedData(includingSPMCache: Bool) {
        guard !isRunning else { return }
        guard let projectDirPath else {
            errorMessage = "Project path must be configured first."
            return
        }

        errorMessage = nil
        stepOutputs = [:]
        selectedStep = nil
        isCancelled = false
        isRunning = true

        var stepList: [SwitcherStep] = []
        if includingSPMCache {
            stepList.append(SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"))
        }
        stepList.append(SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"))
        steps = stepList

        Task { @MainActor in
            defer {
                refreshDetectedState()
                runningProcess = nil
                isRunning = false
            }

            do {
                for i in stepList.indices {
                    guard !isCancelled else { break }

                    stepList[i].state = .running
                    currentStepID = stepList[i].id
                    selectedStep = stepList[i].id
                    steps = stepList

                    switch stepList[i].id {
                    case .clearSPMCaches:
                        try clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try clearDerivedData()
                        stepList[i].state = .done

                    default:
                        stepList[i].state = .skipped
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
        }
    }

    // MARK: - Sync helpers

    private func syncError(_ message: String) -> NSError {
        NSError(domain: "SDKSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func readSDKRef(projectDirPath: String) throws -> SDKRef? {
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

    private func verifySDKDirectory(sdkPath: String) throws {
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

    private func isAlreadyInSync(sdkPath: String, ref: SDKRef) throws -> Bool {
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

    private func ensureRemoteRegistered(sdkPath: String, repoURL: String) throws -> String {
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

    private func alignBranch(sdkPath: String, remoteName: String, branch: String) async throws {
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

    private func gitCapture(_ args: [String], cwd: String) throws -> String {
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
