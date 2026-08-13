// SPDX-License-Identifier: MIT
//
// Shared app-side contracts for the native ShareCLI endpoint.

#if os(macOS)
import Foundation

@MainActor
protocol ShareCLIControlSurface: AnyObject {
    var shareCLIControlID: UUID { get }
    var shareCLIWriteAvailable: Bool { get }
    func shareCLISendText(_ text: String) throws
    var shareCLIForegroundPID: Int? { get }
    var shareCLITTYName: String? { get }
    var shareCLIVisibleScreenText: String { get }
    var shareCLIWorkingDirectory: String { get }
    var shareCLIWindowTitle: String? { get }
}

@MainActor
extension ShareCLIControlSurface {
    var shareCLIWorkingDirectory: String { "" }
    var shareCLIWindowTitle: String? { nil }
}

enum ShareCLIControlCapability: Sendable {
    case sendText, foregroundPID, ttyName, visibleScreen
    case rawPTY, liveIO, resize, durablePTY, layout
}

enum ShareCLIControlCapabilityState: Equatable, Sendable {
    case available, unavailable
}

enum ShareCLIControlError: Error, Equatable {
    case surfaceUnavailable(UUID)
    case writeUnavailable(UUID)
    case invalidTextPayload
}

enum ShareCLIControlState: Equatable {
    case stopped, running
    case failed(String)
}

/// A synchronous lifetime fence between native teardown and asynchronously
/// dispatched provider work. It is independent of AppKit so a connection
/// accepted just before shutdown cannot reach a surface.
final class ShareCLIProviderAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func allowAccess() {
        lock.lock()
        open = true
        lock.unlock()
    }

    func denyAccess() {
        lock.lock()
        open = false
        lock.unlock()
    }
}
#endif
