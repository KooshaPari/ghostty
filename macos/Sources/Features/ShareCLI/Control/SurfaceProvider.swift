// Vendored from ShareCLI's canonical contrib/ghostty-control package.
// See ../README.md for integration provenance and capability bounds.
import Foundation

/// A single app-owned surface binding.
///
/// The Ghostty fork should construct bindings with closures that capture only
/// weak/actor-safe references to its SurfaceView and termio objects. ShareCLI
/// never stores a raw Ghostty C pointer or invokes shell text through this
/// type. Every operation remains asynchronous so a MainActor-bound adapter can
/// hop to the app actor for a short operation.
public struct SurfaceBinding: Sendable {
    public let record: SurfaceRecord

    private let sendOperation: @Sendable ([UInt8]) async throws -> Void
    private let readOperation: @Sendable (Int) async throws -> [UInt8]
    private let resizeOperation: @Sendable (UInt16, UInt16) async throws -> Void
    private let capabilitiesOperation: @Sendable () async throws -> SurfaceCapabilities

    public init(
        record: SurfaceRecord,
        send: @escaping @Sendable ([UInt8]) async throws -> Void,
        read: @escaping @Sendable (Int) async throws -> [UInt8],
        resize: @escaping @Sendable (UInt16, UInt16) async throws -> Void,
        capabilities: @escaping @Sendable () async throws -> SurfaceCapabilities
    ) {
        self.record = record
        self.sendOperation = send
        self.readOperation = read
        self.resizeOperation = resize
        self.capabilitiesOperation = capabilities
    }

    fileprivate func send(_ bytes: [UInt8]) async throws {
        try await sendOperation(bytes)
    }

    fileprivate func read(maxBytes: Int) async throws -> [UInt8] {
        try await readOperation(maxBytes)
    }

    fileprivate func resize(rows: UInt16, cols: UInt16) async throws {
        try await resizeOperation(rows, cols)
    }

    fileprivate func capabilities() async throws -> SurfaceCapabilities {
        try await capabilitiesOperation()
    }
}

/// Explicit degraded provider used while Ghostty's native surface tree is
/// unavailable (for example, before app readiness or after teardown).
///
/// Keeping the listener alive with an empty, read-only provider lets clients
/// distinguish "control plane is up, surfaces unavailable" from a dead socket.
public struct UnavailableSurfaceProvider: SurfaceProvider, Sendable {
    public let reason: String

    public init(reason: String = "native Ghostty surface provider unavailable") {
        self.reason = reason
    }

    public func surfaceInventory() async throws -> SurfaceInventory { .unavailable }

    public func send(surfaceID: String, bytes: [UInt8]) async throws {
        throw ControlError.provider(reason)
    }

    public func read(surfaceID: String, maxBytes: Int) async throws -> [UInt8] {
        throw ControlError.provider(reason)
    }

    public func resize(surfaceID: String, rows: UInt16, cols: UInt16) async throws {
        throw ControlError.provider(reason)
    }

    public func capabilities(surfaceID: String) async throws -> SurfaceCapabilities {
        SurfaceCapabilities(read: false, write: false, resize: false, layout: false, durablePty: false)
    }
}

/// Lock-isolated registry that adapts Ghostty's live surface tree to the
/// ShareCLI `SurfaceProvider` contract.
///
/// The app actor can synchronously withdraw inventory completeness before a
/// tree mutation and atomically publish a fresh, stable batch afterwards. A
/// binding disappearing during a request produces an explicit provider error;
/// it never falls back to AppleScript, process scraping, or command execution.
public final class SurfaceProviderRegistry: SurfaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [String: SurfaceBinding] = [:]
    private var inventoryReady = false
    private var lastPublishedGeneration: UInt64?

    public init() {}

    /// Add one binding and withdraw inventory completeness. Callers must follow
    /// with `replaceInventory(_:generation:)` before treating omissions as exits.
    public func register(_ binding: SurfaceBinding) throws {
        guard !binding.record.id.isEmpty else {
            throw ControlError.invalidParams("surface binding id must not be empty")
        }
        lock.lock()
        defer { lock.unlock() }
        guard bindings[binding.record.id] == nil else {
            throw ControlError.provider("surface binding already registered: \(binding.record.id)")
        }
        // A one-binding mutation cannot prove a full tree. Keep the previous
        // generation for stale-read detection, but require a later batch to
        // publish a new complete generation.
        inventoryReady = false
        bindings[binding.record.id] = binding
    }

    /// Assert that the app has completed a consistent enumeration of its
    /// surface tree. The registry intentionally starts incomplete so its empty
    /// startup state cannot make the ledger infer exits. Generations are
    /// registry-owned and must advance strictly for the process lifetime.
    public func markInventoryStable(generation: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireNextGeneration(generation)
        lastPublishedGeneration = generation
        inventoryReady = true
    }

    /// Withdraw the completeness assertion before a surface-tree rebuild or
    /// during app teardown. Existing bindings remain available for targeted
    /// operations, but omission is no longer exit evidence.
    public func markInventoryIncomplete() {
        lock.lock()
        defer { lock.unlock() }
        inventoryReady = false
    }

    /// Publish an app-actor snapshot as one inventory generation. The
    /// incomplete transition and binding replacement share one lock so a
    /// request observes either the prior stable generation or this complete
    /// generation, never a partial tree.
    public func replaceInventory(_ inventory: [SurfaceBinding], generation: UInt64) throws {
        var next: [String: SurfaceBinding] = [:]
        for binding in inventory {
            guard !binding.record.id.isEmpty else {
                throw ControlError.invalidParams("surface binding id must not be empty")
            }
            guard next.updateValue(binding, forKey: binding.record.id) == nil else {
                throw ControlError.provider("duplicate surface binding: \(binding.record.id)")
            }
        }

        lock.lock()
        defer { lock.unlock() }
        try requireNextGeneration(generation)
        inventoryReady = false
        bindings = next
        lastPublishedGeneration = generation
        inventoryReady = true
    }

    /// Remove every native binding during lifecycle invalidation. The socket
    /// is closed separately by the lifecycle owner, so this never leaves a
    /// stale provider path reachable between termination and PTY teardown. The
    /// last generation intentionally remains visible on the incomplete result.
    public func invalidate() {
        lock.lock()
        bindings.removeAll()
        inventoryReady = false
        lock.unlock()
    }

    /// Replace one binding and withdraw inventory completeness. This API is for
    /// transient app-side bookkeeping; only a batch may publish a generation.
    @discardableResult
    public func replace(_ binding: SurfaceBinding) throws -> SurfaceBinding? {
        guard !binding.record.id.isEmpty else {
            throw ControlError.invalidParams("surface binding id must not be empty")
        }
        lock.lock()
        defer { lock.unlock() }
        // See `register`: only `replaceInventory` can publish completeness.
        inventoryReady = false
        return bindings.updateValue(binding, forKey: binding.record.id)
    }

    /// Remove one binding and withdraw inventory completeness when it existed.
    /// The previous generation remains visible until the next stable batch.
    @discardableResult
    public func unregister(surfaceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bindings.removeValue(forKey: surfaceID) != nil else { return false }
        // A removal may hide a live split, so it invalidates the old complete
        // snapshot until the app actor republishes a full batch.
        inventoryReady = false
        return true
    }

    public func surfaceInventory() throws -> SurfaceInventory {
        lock.lock()
        defer { lock.unlock() }
        return SurfaceInventory(
            surfaces: bindings.values.map(\.record).sorted { $0.id < $1.id },
            complete: inventoryReady,
            generation: lastPublishedGeneration.map(String.init)
        )
    }

    public func send(surfaceID: String, bytes: [UInt8]) async throws {
        try await binding(for: surfaceID).send(bytes)
    }

    public func read(surfaceID: String, maxBytes: Int) async throws -> [UInt8] {
        try await binding(for: surfaceID).read(maxBytes: maxBytes)
    }

    public func resize(surfaceID: String, rows: UInt16, cols: UInt16) async throws {
        try await binding(for: surfaceID).resize(rows: rows, cols: cols)
    }

    public func capabilities(surfaceID: String) async throws -> SurfaceCapabilities {
        try await binding(for: surfaceID).capabilities()
    }

    private func binding(for surfaceID: String) throws -> SurfaceBinding {
        lock.lock()
        defer { lock.unlock() }
        guard let binding = bindings[surfaceID] else {
            throw ControlError.provider("surface unavailable: \(surfaceID)")
        }
        return binding
    }

    private func requireNextGeneration(_ generation: UInt64) throws {
        guard let lastPublishedGeneration else { return }
        guard generation > lastPublishedGeneration else {
            throw ControlError.provider(
                "inventory generation must increase: \(generation) <= \(lastPublishedGeneration)"
            )
        }
    }
}
