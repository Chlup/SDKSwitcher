//
//  SDKSwitcherApp.swift
//  SDKSwitcher
//
//  Created by Lukáš Korba on 01.04.2026.
//

import SwiftUI
import AppKit
import Combine

@main
struct SDKSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("SDK Switcher", id: "main") {
            ContentView(vm: appDelegate.viewModel)
                .onAppear {
                    // Hide from dock
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = SwitcherViewModel()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        // Update menu when status changes
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer to next run loop so published values are updated
                DispatchQueue.main.async {
                    self?.updateMenu()
                }
            }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: "SDK Switcher")
        }
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem()
        statusMenuItem.isEnabled = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))

        if viewModel.isRunning {
            let spinner = NSProgressIndicator(frame: NSRect(x: 14, y: 2, width: 16, height: 16))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            container.addSubview(spinner)

            let label = NSTextField(labelWithString: viewModel.statusText)
            label.font = NSFont.menuFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 36, y: 1, width: 150, height: 18)
            container.addSubview(label)
        } else {
            let label = NSTextField(labelWithString: viewModel.statusText)
            label.font = NSFont.menuFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 14, y: 1, width: 170, height: 18)
            container.addSubview(label)
        }

        statusMenuItem.view = container
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Switch button
        let canSwitch = !viewModel.isRunning && viewModel.isConfigured && viewModel.currentMode != .unknown
        let targetMode: SDKMode = viewModel.currentMode == .local ? .remote : .local
        let switchTitle = viewModel.currentMode == .local ? "Switch to Remote" : "Switch to Local"
        let switchItem = NSMenuItem(title: switchTitle, action: canSwitch ? #selector(switchMode) : nil, keyEquivalent: "")
        switchItem.target = self
        switchItem.tag = targetMode == .local ? 0 : 1
        menu.addItem(switchItem)

        // Sync SDK button
        let canSync = !viewModel.isRunning && viewModel.isConfigured && viewModel.currentMode == .local
        let syncItem = NSMenuItem(title: "Sync SDK", action: canSync ? #selector(syncSDK) : nil, keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        // Cancel button
        let cancelItem = NSMenuItem(title: "Cancel", action: viewModel.isRunning ? #selector(cancelRun) : nil, keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)

        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ",")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func showWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") ?? false }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Open the window via the SwiftUI scene system
            NSApp.sendAction(Selector(("showMainWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func switchMode(_ sender: NSMenuItem) {
        let mode: SDKMode = sender.tag == 0 ? .local : .remote
        viewModel.switchTo(mode)
    }

    @objc private func syncSDK() {
        viewModel.syncSDK()
    }

    @objc private func cancelRun() {
        viewModel.cancelRun()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

