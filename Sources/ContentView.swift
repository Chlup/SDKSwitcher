//
//  ContentView.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = SwitcherViewModel()

    private var currentColor: Color { vm.currentMode == .local ? .orange : .blue }
    private var currentIcon: String { vm.currentMode == .local ? "internaldrive.fill" : "cloud.fill" }
    private var currentLabel: String { vm.currentMode == .local ? "Local" : "Remote" }
    private var currentSubtitle: String { vm.currentMode == .local ? "Disk path" : "GitHub release" }
    private var targetMode: SDKMode { vm.currentMode == .local ? .remote : .local }
    private var targetLabel: String { vm.currentMode == .local ? "Switch to Remote" : "Switch to Local" }
    private var targetColor: Color { vm.currentMode == .local ? .blue : .orange }

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
            .disabled(vm.isRunning || vm.currentMode == .unknown)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            // Steps
            if !vm.steps.isEmpty {
                Divider()
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.steps) { step in
                        StepRow(step: step)
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
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 340)
        .background(.background)
    }
}

struct StepRow: View {
    let step: SwitcherStep

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

            Spacer()
        }
    }
}
