//
//  SwitcherViewModel+Clean.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

extension SwitcherViewModel {
    @MainActor
    func cleanDerivedData(includingSPMCache: Bool) {
        guard !isRunning else { return }
        guard projectDirPath != nil else {
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
                        try await clearSPMCaches()
                        stepList[i].state = .done

                    case .clearDerivedData:
                        try await clearDerivedData()
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

    // MARK: - Cache clearing

    func clearSPMCaches() async throws {
        try await Task.detached(priority: .userInitiated) {
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
        }.value
    }

    func clearDerivedData() async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            let derivedDataDir = "\(home)/Library/Developer/Xcode/DerivedData"

            if fm.fileExists(atPath: derivedDataDir),
               let items = try? fm.contentsOfDirectory(atPath: derivedDataDir) {
                for item in items where item.hasPrefix("secant-") {
                    try fm.removeItem(atPath: "\(derivedDataDir)/\(item)")
                }
            }
        }.value
    }
}
