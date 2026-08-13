// SPDX-License-Identifier: MIT
//
// ShareCLI native control adapter for Ghostty.
//
// This file adapts the vendored ShareCLI control transport in `Control/` to
// Ghostty's AppKit surface model. The vendored transport originated in the
// ShareCLI repository and is intentionally kept macOS-only here; it has no
// dependency on a developer-machine path or a separate SwiftPM runner.

#if os(macOS)
import AppKit
import Darwin
import Foundation

/// App-owned lifecycle and weak surface registry for the native ShareCLI
/// endpoint. The registry intentionally owns neither a `ghostty_surface_t`
/// nor a terminal process: every binding holds only a weak AppKit surface.
@MainActor
final class ShareCLIControlBootstrap {
    private final class WeakSurface: @unchecked Sendable {
        weak var value: (any ShareCLIControlSurface)?

        init(_ value: any ShareCLIControlSurface) {
            self.value = value
        }
    }

    let registry = SurfaceProviderRegistry()
    let liveEvents: LiveIOEventHub
    private let lifecycle: ControlLifecycle
    private let accessGate = ShareCLIProviderAccessGate()
    private var surfaces: [UUID: WeakSurface] = [:]
    private var inventoryGeneration: UInt64 = 0

    private(set) var state: ShareCLIControlState = .stopped

    /// The app is never entitled to claim a globally complete terminal
    /// inventory while it is stopped or while a surface-tree update is pending.
    /// Callers must treat `false` as a request to rescan after the transition.
    private(set) var inventoryIsComplete = false

    init(socketPath: String? = nil) {
        let liveEvents = LiveIOEventHub()
        self.liveEvents = liveEvents
        lifecycle = ControlLifecycle(
            socketPath: socketPath ?? Self.defaultSocketPath(),
            liveEvents: liveEvents
        )
    }

    @discardableResult
    func start() -> Bool {
        guard state == .stopped else { return false }
        registry.invalidate()
        lifecycle.start(provider: registry)
        switch lifecycle.state {
        case .running:
            state = .running
            inventoryIsComplete = false
            accessGate.allowAccess()
            return true
        case let .failed(message):
            state = .failed(message)
            return false
        case .stopped:
            state = .failed("control lifecycle stopped during start")
            return false
        }
    }

    /// Synchronously revoke native provider access and close the listener
    /// before Ghostty starts surface or PTY teardown. Connection draining is
    /// deliberately not scheduled here: a terminating app has no safe native
    /// object lifetime to hand to a detached shutdown task.
    func stop() {
        accessGate.denyAccess()
        lifecycle.stopImmediately()
        registry.invalidate()
        surfaces.removeAll()
        state = .stopped
        inventoryIsComplete = false
    }

    /// Withdraw completeness before a controller mutates its surface tree.
    /// AppDelegate follows this with `synchronize` using an AppKit snapshot.
    func beginSurfaceTreeTransition() {
        guard state == .running else { return }
        inventoryIsComplete = false
        registry.markInventoryIncomplete()
    }

    /// Publish a complete app-owned surface snapshot as one stable inventory
    /// generation. AppDelegate supplies the concrete `Ghostty.SurfaceView`
    /// instances from every live terminal controller; the protocol keeps the
    /// registry independently testable without an artificial terminal process.
    /// A successful synchronization never leaves the endpoint incomplete.
    func synchronize(_ currentSurfaces: [any ShareCLIControlSurface]) {
        guard state == .running else { return }
        beginSurfaceTreeTransition()

        var nextSurfaces: [UUID: WeakSurface] = [:]
        var bindings: [SurfaceBinding] = []
        for surface in currentSurfaces {
            let id = surface.shareCLIControlID
            nextSurfaces[id] = WeakSurface(surface)
            bindings.append(makeBinding(for: surface))
        }

        guard inventoryGeneration < UInt64.max else {
            state = .failed("ShareCLI inventory generation exhausted")
            return
        }
        inventoryGeneration += 1
        do {
            try registry.replaceInventory(bindings, generation: inventoryGeneration)
            surfaces = nextSurfaces
            inventoryIsComplete = true
        } catch {
            registry.markInventoryIncomplete()
            inventoryIsComplete = false
            state = .failed("ShareCLI inventory synchronization failed: \(error)")
        }
    }

    func bind(_ surface: any ShareCLIControlSurface) {
        let id = surface.shareCLIControlID
        surfaces[id] = WeakSurface(surface)
        beginSurfaceTreeTransition()
        _ = try? registry.replace(makeBinding(for: surface))
    }

    func unbind(_ id: UUID) {
        surfaces.removeValue(forKey: id)
        beginSurfaceTreeTransition()
        _ = registry.unregister(surfaceID: id.uuidString)
    }

    var surfaceIDs: [UUID] {
        let stale = surfaces.compactMap { $0.value.value == nil ? $0.key : nil }
        for id in stale {
            unbind(id)
        }
        return surfaces.keys.sorted { $0.uuidString < $1.uuidString }
    }

    func capability(_ capability: ShareCLIControlCapability) -> ShareCLIControlCapabilityState {
        guard state == .running && accessGate.isOpen else { return .unavailable }
        switch capability {
        case .sendText:
            let hasWritableSurface = surfaces.values.contains { $0.value?.shareCLIWriteAvailable == true }
            return accessGate.isOpen && hasWritableSurface ? .available : .unavailable
        case .foregroundPID, .ttyName, .visibleScreen:
            return .available
        case .liveIO:
            return .available
        case .rawPTY, .resize, .durablePTY, .layout:
            return .unavailable
        }
    }

    /// Capture the current visible-screen snapshot at Ghostty's coalesced
    /// render boundary, then fan it out off the AppKit call stack. The hub
    /// suppresses equal payloads, so cursor-only render invalidations do not
    /// become external events.
    @discardableResult
    func publishVisibleScreen(_ surface: any ShareCLIControlSurface) -> Task<Void, Never> {
        guard state == .running && accessGate.isOpen else { return Task {} }
        let id = surface.shareCLIControlID
        guard surfaces[id]?.value != nil else { return Task {} }
        let surfaceID = id.uuidString
        let bytes = Array(surface.shareCLIVisibleScreenText.utf8.prefix(LiveIOEventHub.maxChunkBytes))

        return Task { @MainActor [weak self] in
            guard let self, self.state == .running && self.accessGate.isOpen else { return }
            _ = try? await self.liveEvents.publishScreenChanged(surfaceID: surfaceID, bytes: bytes)
        }
    }

    func foregroundPID(for id: UUID) throws -> Int? {
        try liveSurface(id).shareCLIForegroundPID
    }

    func ttyName(for id: UUID) throws -> String? {
        try liveSurface(id).shareCLITTYName
    }

    func readVisibleScreen(for id: UUID, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0 else { throw ShareCLIControlError.invalidTextPayload }
        var bytes = Array(try liveSurface(id).shareCLIVisibleScreenText.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) {
                return text
            }
            bytes.removeLast()
        }
        return ""
    }

    private func liveSurface(_ id: UUID) throws -> any ShareCLIControlSurface {
        guard let surface = surfaces[id]?.value else {
            surfaces.removeValue(forKey: id)
            throw ShareCLIControlError.surfaceUnavailable(id)
        }
        return surface
    }

    private func makeBinding(for surface: any ShareCLIControlSurface) -> SurfaceBinding {
        let weak = WeakSurface(surface)
        let record = record(for: surface)
        let accessGate = accessGate
        return SurfaceBinding(
            record: record,
            send: { bytes in
                guard accessGate.isOpen else {
                    throw ControlError.provider("native Ghostty surface provider unavailable")
                }
                return try await MainActor.run {
                    guard let surface = weak.value else {
                        throw ControlError.provider("surface unavailable: \(record.id)")
                    }
                    guard surface.shareCLIWriteAvailable else {
                        throw ControlError.provider("native Ghostty text injection unavailable: \(record.id)")
                    }
                    guard let text = String(bytes: bytes, encoding: .utf8) else {
                        throw ControlError.invalidParams("native Ghostty text input requires valid UTF-8")
                    }
                    do {
                        try surface.shareCLISendText(text)
                    } catch {
                        throw ControlError.provider("native Ghostty text injection unavailable: \(record.id)")
                    }
                }
            },
            read: { maximumBytes in
                guard accessGate.isOpen else {
                    throw ControlError.provider("native Ghostty surface provider unavailable")
                }
                return try await MainActor.run {
                    guard let surface = weak.value else {
                        throw ControlError.provider("surface unavailable: \(record.id)")
                    }
                    return Array(surface.shareCLIVisibleScreenText.utf8.prefix(maximumBytes))
                }
            },
            resize: { _, _ in
                throw ControlError.provider("native Ghostty resize control is unavailable")
            },
            capabilities: {
                await MainActor.run {
                    let available = accessGate.isOpen && weak.value != nil
                    let write = available && weak.value?.shareCLIWriteAvailable == true
                    return SurfaceCapabilities(
                        read: available,
                        write: write,
                        resize: false,
                        layout: false,
                        durablePty: false
                    )
                }
            }
        )
    }

    private func record(for surface: any ShareCLIControlSurface) -> SurfaceRecord {
        SurfaceRecord(
            id: surface.shareCLIControlID.uuidString,
            title: surface.shareCLIWindowTitle,
            cwd: surface.shareCLIWorkingDirectory,
            process: ProcessEvidence(
                pid: surface.shareCLIForegroundPID.flatMap { UInt32(exactly: $0) },
                tty: surface.shareCLITTYName,
                cwd: surface.shareCLIWorkingDirectory,
                argv: []
            )
        )
    }

    private static func defaultSocketPath() -> String {
        if let configured = ProcessInfo.processInfo.environment["SHARECLI_GHOSTTY_CONTROL_SOCKET"],
           !configured.isEmpty {
            return configured
        }
        return "\(NSTemporaryDirectory())sharecli-ghostty-\(getuid())-\(getpid()).sock"
    }
}

@MainActor
extension Ghostty.SurfaceView: ShareCLIControlSurface {
    var shareCLIControlID: UUID { id }

    var shareCLIWriteAvailable: Bool { surfaceModel != nil }

    func shareCLISendText(_ text: String) throws {
        guard let surfaceModel else {
            throw ShareCLIControlError.writeUnavailable(id)
        }
        surfaceModel.sendText(text)
    }

    var shareCLIForegroundPID: Int? {
        surfaceModel?.foregroundPID
    }

    var shareCLITTYName: String? {
        surfaceModel?.ttyName
    }

    var shareCLIVisibleScreenText: String {
        cachedVisibleContents.get()
    }

    var shareCLIWorkingDirectory: String {
        pwd ?? ""
    }

    var shareCLIWindowTitle: String? {
        title.isEmpty ? nil : title
    }
}
#endif
