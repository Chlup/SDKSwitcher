//
//  ContentView.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension String {
    var abbreviatingWithTildeInPath: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

struct ContentView: View {
    @ObservedObject var vm: SwitcherViewModel

    private var currentColor: Color { vm.currentMode == .local ? .orange : .blue }
    private var currentIcon: String { vm.currentMode == .local ? "internaldrive.fill" : "cloud.fill" }
    private var currentLabel: String { vm.currentMode == .local ? "Local" : "Remote" }
    private var currentSubtitle: String { vm.currentMode == .local ? "Disk path" : "GitHub release" }
    private var targetMode: SDKMode { vm.currentMode == .local ? .remote : .local }
    private var targetLabel: String { vm.currentMode == .local ? "Switch to Remote" : "Switch to Local" }
    private var targetColor: Color { vm.currentMode == .local ? .blue : .orange }

    private var isSyncDisabled: Bool {
        vm.isRunning || !vm.isConfigured || vm.currentMode != .local
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("SDK Switcher")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("zcash-swift-wallet-sdk (Xcode project)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Path configuration
            VStack(alignment: .leading, spacing: 8) {
                PathRow(
                    label: "Project",
                    path: vm.projectDirPath,
                    action: { pickProjectDir() }
                )
                PathRow(
                    label: "SDK",
                    path: vm.sdkPath,
                    action: { pickSDKFolder() }
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if vm.isConfigured {
                Divider()
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: ".zodl-sdk-ref.json")
                        if let ref = vm.currentSDKRef {
                            InfoRow(label: "Repo", value: ref.repoURL)
                            InfoRow(label: "Branch", value: ref.branch)
                        } else {
                            Text("No local SDK ref recorded")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: "Local SDK repo")
                        if let state = vm.currentSDKState {
                            if let err = state.errorDescription {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                InfoRow(label: "Repo", value: state.remoteURL ?? "(branch not on any remote)")
                                InfoRow(label: "Branch", value: state.branch ?? "(detached HEAD)")
                                InfoRow(label: "Clean", value: state.isClean ? "yes" : "uncommitted changes")
                            }
                        } else {
                            Text("Not available")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }

            // Current state
            VStack(spacing: 6) {
                Image(systemName: currentIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(currentColor)
                Text(currentLabel)
                    .font(.headline)
                Text(currentSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            // Toggle button
            Button {
                vm.switchTo(targetMode)
            } label: {
                Text(targetLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(vm.isRunning ? Color.secondary : targetColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(vm.isRunning || !vm.isConfigured || vm.currentMode == .unknown)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            // Sync SDK button
            Button {
                vm.syncSDK()
            } label: {
                Text("Sync SDK")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isSyncDisabled ? Color.secondary : Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isSyncDisabled)
            .padding(.horizontal, 24)
            .padding(.bottom, vm.isRunning ? 8 : 24)

            // Cancel button
            if vm.isRunning {
                Button {
                    vm.cancelRun()
                } label: {
                    Text("Cancel")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            // Steps
            if !vm.steps.isEmpty {
                Divider()
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.steps) { step in
                        StepRow(step: step, isSelected: vm.selectedStep == step.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selectStep(step.id)
                            }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Error
            if let error = vm.errorMessage {
                Divider()
                    .padding(.horizontal, 24)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Step output
            if let output = vm.selectedStepOutput {
                Divider()
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Output")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(output)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("shellOutputEnd")
                        }
                        .frame(height: 200)
                        .onChange(of: output) {
                            proxy.scrollTo("shellOutputEnd", anchor: .bottom)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 480)
        .background(.background)
        .background(WindowAccessor())
    }

    private func pickProjectDir() {
        let panel = NSOpenPanel()
        panel.title = "Select project directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            vm.setProjectDirPath(url.path)
        }
    }

    private func pickSDKFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select SDK folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            vm.setSDKPath(url.path)
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PathRow: View {
    let label: String
    let path: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 50, alignment: .leading)

            Text(path?.abbreviatingWithTildeInPath ?? "Not set")
                .font(.caption)
                .foregroundStyle(path == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Browse") {
                action()
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}

struct StepRow: View {
    let step: SwitcherStep
    var isSelected: Bool = false

    private var isTappable: Bool {
        step.state != .pending
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch step.state {
                case .pending:
                    Circle()
                        .stroke(.tertiary, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                case .running:
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 20)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 20))
                case .skipped:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 20))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 20))
                }
            }

            Text(step.title)
                .font(.callout)
                .foregroundStyle(step.state == .pending ? .secondary : .primary)
                .underline(isSelected)

            Spacer()
        }
        .cursor(isTappable ? .pointingHand : .arrow)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// Installs a delegate on the hosting window to hide on close instead of quitting
struct WindowAccessor: NSViewRepresentable {
    private class Delegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        // Refresh detected state whenever the window becomes key so the UI
        // always reflects current values when the user looks at it.
        func windowDidBecomeKey(_ notification: Notification) {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                Task { @MainActor in
                    appDelegate.viewModel.refreshDetectedState()
                }
            }
        }
    }

    private static let delegate = Delegate()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = WindowAccessor.delegate
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, !(window.delegate is Delegate) {
            window.delegate = WindowAccessor.delegate
        }
    }
}


