//
//  FileWatcher.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import Foundation

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
