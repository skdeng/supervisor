# Repository Guidelines

## Project Structure & Module Organization

SuperVisor is a Swift 6.2 SwiftPM executable for macOS 26; there is no Xcode project. Code lives in `Sources/SuperVisor/`: `App/` wires startup, `Core/` owns engine contracts, `UI/` holds shared surfaces, and `Modules/` groups features. Shared integrations live in `Services/`, design tokens in `Theme/`, and preferences in `Settings/`. The Objective-C MediaRemote shim is `Sources/MediaRemoteAdapter/mediaremote_adapter.m`. Bundle metadata is in `Info.plist`; privacy entitlements are in `SuperVisor.entitlements`.

Read `ARCHITECTURE.md` before changing `Core/NotchModule.swift`, `Core/NotchContext.swift`, or `App/ModuleRegistry.swift`; their signatures are shared contracts. New Swift files under `Sources/SuperVisor/` are discovered automatically.

## Build, Test, and Development Commands

- `swift build` — compile the executable without the adapter or stable app bundle.
- `./make-app.sh` — create and sign a debug `build/SuperVisor.app`; Apple identities are preferred, with an ad-hoc fallback.
- `./make-app.sh --release --run` — package an optimized build and launch it.
- `open build/SuperVisor.app` — launch an already packaged app.

Use the packaged app when checking Calendar, Reminders, Bluetooth, or now-playing behavior. An Apple-issued identity keeps permission grants stable across rebuilds; set `SIGNING_IDENTITY` to choose one explicitly.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and filenames matching their primary type or view. Keep modules independent and register them only in `ModuleRegistry`. UI state and module lifecycles generally belong on `@MainActor`; document any `@unchecked Sendable` boundary. Guard private-framework symbols and fail gracefully. No formatter or linter is configured, so follow neighboring code.

## Testing Guidelines

No automated test target or coverage threshold exists. Run `swift build` and package the app before submitting. Manually exercise affected compact and expanded states, permission flows, and both notched and non-notched geometry when relevant. Add future SwiftPM tests under `Tests/SuperVisorTests/`, named after the unit, such as `MeetingLinkTests.swift`.

## Security & Configuration

Treat calendar text, dropped filenames, and now-playing metadata as untrusted. Preserve URL allowlists, safe zip argument handling, finite-number checks, and graceful fallbacks described in `CLAUDE.md`. Never commit generated bundles or `.build/` contents.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative, sentence-case subjects (for example, `Stream now-playing from one long-lived helper`). Keep commits focused; explain motivation and non-obvious verification in the body. Do not add co-author or tooling trailers. Pull requests should summarize user-visible and architectural effects, list validation, link relevant issues, and include screenshots or recordings for UI changes. Explicitly call out permissions, private-framework behavior, or security-sensitive input handling.
