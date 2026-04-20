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

        var stepList: [SwitcherStep] = []
        if includingSPMCache {
            stepList.append(SwitcherStep(id: .clearSPMCaches, title: "Clear SPM caches"))
        }
        stepList.append(SwitcherStep(id: .clearDerivedData, title: "Clear Derived Data"))

        Task { @MainActor in
            await runPipeline(stepList) { stepID in
                switch stepID {
                case .clearSPMCaches:
                    try await clearSPMCaches()
                    return .done

                case .clearDerivedData:
                    try await clearDerivedData()
                    return .done

                default:
                    return .skipped
                }
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
