# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

SDKSwitcher is a small macOS SwiftUI menubar-style utility that toggles the `zcash-swift-wallet-sdk` dependency in the `secant-ios-wallet` Xcode project between a **local** Swift Package reference (on-disk, sibling directory `../zcash-swift-wallet-sdk`) and a **remote** Swift Package reference (pinned to a GitHub release tag).

There are no tests, no package manager, and no CI — it's a single Xcode app target.

## Build / Run

Open in Xcode:

```
open SDKSwitcher.xcodeproj
```

Build from CLI:

```
xcodebuild -project SDKSwitcher.xcodeproj -scheme SDKSwitcher build
```

Run the app from Xcode (⌘R). The app needs filesystem access to the paths hardcoded in `SwitcherViewModel` (see below) and permission to spawn `/usr/bin/xcodebuild`, `/usr/bin/git`, and the SDK's `init-local-ffi.sh`.

## Architecture

The entire logic lives in `Sources/SwitcherViewModel.swift` — `ContentView.swift` is just a thin SwiftUI shell that binds to it.

Key flow in `SwitcherViewModel.switchTo(_:)`:

1. **Rewrite `project.pbxproj`** textually (no Xcode project parser — regex + string replacement). Finds the SDK's 24-char object ID via regex over either `XCLocalSwiftPackageReference` or `XCRemoteSwiftPackageReference`, then swaps the definition block, the packageReferences list comment, and product dependency comments. Creates/removes the `XCLocalSwiftPackageReference` section as needed.
2. **Init local FFI** (local mode only) by shelling out to `<sdkPath>/Scripts/init-local-ffi.sh --cached`. Skipped if `LocalPackages` already exists.
3. **Clear SPM caches** under `~/Library/Caches/org.swift.swiftpm` and `~/Library/org.swift.swiftpm`.
4. **Resolve packages** via `xcodebuild -resolvePackageDependencies`.

When switching to remote, the latest SDK version is detected by running `git describe --tags --abbrev=0` inside `sdkPath`; a leading `v` is stripped. The remote definition uses `upToNextMinorVersion` pinning.

### Hardcoded paths

`SwitcherViewModel` has user-specific absolute paths (`/Users/lukaskorba/...`) for `pbxprojPath`, `sdkPath`, and the remote URL / SDK name. Anything that touches switching logic must account for these being configurable-in-source-only today — don't assume they're environment-driven.

### pbxproj editing invariants

The rewrite relies on tab-indented lines (`\t\t`) and the exact section markers `/* Begin XC{Local,Remote}SwiftPackageReference section */` / `... End ...`. Order matters: definition blocks are removed **before** comment strings get swapped, otherwise the regex anchors no longer match. The regex for the object ID expects a 24-char hex uppercase id.
