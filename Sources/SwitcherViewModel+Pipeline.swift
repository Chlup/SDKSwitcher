//
//  SwitcherViewModel+Pipeline.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

extension SwitcherViewModel {
    // MARK: - Pipeline runner

    /// Executes a list of steps, dispatching each to `handler` and tracking
    /// step state, errors, cancellation, and final cleanup. The handler returns
    /// a `StepOutcome` that controls whether the step is marked done/skipped or
    /// halts the remaining pipeline.
    @MainActor
    func runPipeline(
        _ stepList: [SwitcherStep],
        handler: @MainActor (StepID) async throws -> StepOutcome
    ) async {
        errorMessage = nil
        stepOutputs = [:]
        selectedStep = nil
        isCancelled = false
        isRunning = true

        var mutableList = stepList
        steps = mutableList

        var halted = false

        do {
            for i in mutableList.indices {
                guard !isCancelled else { break }

                if halted {
                    mutableList[i].state = .skipped
                    steps = mutableList
                    continue
                }

                mutableList[i].state = .running
                currentStepID = mutableList[i].id
                selectedStep = mutableList[i].id
                steps = mutableList

                let outcome = try await handler(mutableList[i].id)
                switch outcome {
                case .done:
                    mutableList[i].state = .done
                case .skipped:
                    mutableList[i].state = .skipped
                case .halt:
                    mutableList[i].state = .done
                    halted = true
                }
                steps = mutableList
            }
        } catch {
            if let idx = mutableList.firstIndex(where: { $0.state == .running }) {
                mutableList[idx].state = .failed
                steps = mutableList
            }
            if !isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        if isCancelled {
            if let idx = mutableList.firstIndex(where: { $0.state == .running }) {
                mutableList[idx].state = .failed
                steps = mutableList
            }
            errorMessage = "Cancelled"
        }

        refreshDetectedState()
        runningProcess = nil
        isRunning = false
    }

    // MARK: - Shared step actions

    /// Reads the SDK ref and logs its contents on success. Returns `nil` if no
    /// ref is recorded; callers decide whether that is fatal or a halt signal.
    @MainActor
    func performReadRef(projectDirPath: String) throws -> SDKRef? {
        let loaded = try readSDKRef(projectDirPath: projectDirPath)
        if let loaded {
            appendShellOutput("repoURL: \(loaded.repoURL)\nbranch:  \(loaded.branch)\n")
        }
        return loaded
    }

    /// Returns true when the local SDK is already aligned with `ref`. Logs
    /// "Already in sync." on hit; callers decide what to do with the signal.
    @MainActor
    func performShortCircuit(sdkPath: String, ref: SDKRef) throws -> Bool {
        let synced = try isAlreadyInSync(sdkPath: sdkPath, ref: ref)
        if synced {
            appendShellOutput("Already in sync.\n")
        }
        return synced
    }

    /// Ensures the requested remote is registered and returns its name.
    @MainActor
    func performEnsureRemote(sdkPath: String, ref: SDKRef) throws -> String {
        let name = try ensureRemoteRegistered(sdkPath: sdkPath, repoURL: ref.repoURL)
        appendShellOutput("Using remote `\(name)` for \(ref.repoURL)\n")
        return name
    }

    @MainActor
    func performFetchRemote(sdkPath: String, remoteName: String) async throws {
        try await runShell("/usr/bin/git", args: ["fetch", remoteName], workingDir: sdkPath)
    }

    @MainActor
    func performCheckoutBranch(sdkPath: String, remoteName: String, branch: String) async throws {
        try await alignBranch(sdkPath: sdkPath, remoteName: remoteName, branch: branch)
    }

    @MainActor
    func performInitFFI(sdkPath: String) async throws {
        try await runShell(
            "\(sdkPath)/Scripts/init-local-ffi.sh",
            args: ["--cached"],
            workingDir: sdkPath
        )
    }

    @MainActor
    func performResolvePackages(projectDirPath: String) async throws {
        try await runShell(
            "/usr/bin/xcodebuild",
            args: ["-resolvePackageDependencies", "-project", "\(projectDirPath)/secant.xcodeproj"],
            workingDir: projectDirPath
        )
    }
}
