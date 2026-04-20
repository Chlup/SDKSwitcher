//
//  Models.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

enum SDKMode: String {
    case local   = "local"
    case remote  = "remote"
    case unknown = "unknown"
}

enum StepState {
    case pending, running, done, skipped, failed
}

/// Result of executing a single pipeline step's handler.
/// - `done`: step ran successfully; continue with the next step.
/// - `skipped`: step did not run (precondition not met); continue with the next step.
/// - `halt`: step ran successfully; mark all remaining steps as skipped and exit.
enum StepOutcome {
    case done
    case skipped
    case halt
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
