// Vendored from ShareCLI's canonical contrib/ghostty-control package.
// See ../README.md for integration provenance and capability bounds.
import Foundation

public enum LiveIOError: Error, Equatable, Sendable {
    case invalidChunkBytes
    case invalidQueueCapacity
    case closed
}

public enum LiveIOEventKind: String, Codable, Sendable {
    case output
    case screenChanged = "screen_changed"
    case resize
    case exit
    case title
    case cwd
    case dropped
}

public struct LiveIOEvent: Codable, Equatable, Sendable {
    public let subscriptionID: UInt64
    public let surfaceID: String
    public let seq: UInt64
    public let kind: LiveIOEventKind
    /// RFC3339 timestamp supplied by the Ghostty app, when available.
    ///
    /// The Rust/root client contract uses an optional string here so native and
    /// non-native transports decode the same event envelope.
    public let timestamp: String?
    public let eventBytesBase64: String?
    public let dropped: Int?
    public let resyncRequired: Bool?

    public init(
        subscriptionID: UInt64,
        surfaceID: String,
        seq: UInt64,
        kind: LiveIOEventKind,
        timestamp: String? = nil,
        eventBytesBase64: String? = nil,
        dropped: Int? = nil,
        resyncRequired: Bool? = nil
    ) {
        self.subscriptionID = subscriptionID
        self.surfaceID = surfaceID
        self.seq = seq
        self.kind = kind
        self.timestamp = timestamp
        self.eventBytesBase64 = eventBytesBase64
        self.dropped = dropped
        self.resyncRequired = resyncRequired
    }

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case surfaceID = "surface_id"
        case seq, kind, timestamp
        case eventBytesBase64 = "event_bytes_base64"
        case dropped
        case resyncRequired = "resync_required"
    }
}

public struct LiveIOSubscription: AsyncSequence, Sendable {
    public typealias Element = LiveIOEvent
    public typealias AsyncIterator = AsyncStream<LiveIOEvent>.Iterator

    public let id: UInt64
    let stream: AsyncStream<LiveIOEvent>

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }
}

/// Actor-isolated live event fanout with bounded per-subscriber buffering.
public actor LiveIOEventHub {
    public static let maxChunkBytes = 64 * 1024
    public static let maxQueueCapacity = 256

    private struct State {
        let surfaceID: String?
        let fromSequence: UInt64
        let maxChunkBytes: Int
        let queueCapacity: Int
        let continuation: AsyncStream<LiveIOEvent>.Continuation
        let stream: AsyncStream<LiveIOEvent>
        var dropped: Int = 0
    }

    private var nextSubscriptionID: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var subscriptions: [UInt64: State] = [:]
    private var lastScreenPayloadBySurface: [String: [UInt8]] = [:]

    public init() {}

    public func subscribe(
        surfaceID: String?,
        fromSequence: UInt64?,
        maxChunkBytes: Int = LiveIOEventHub.maxChunkBytes,
        queueCapacity: Int = 64
    ) throws -> LiveIOSubscription {
        let id = try createSubscription(
            surfaceID: surfaceID,
            fromSequence: fromSequence,
            maxChunkBytes: maxChunkBytes,
            queueCapacity: queueCapacity
        )
        guard let subscription = subscription(id: id) else { throw LiveIOError.closed }
        return subscription
    }

    /// Reserve a stream for a transport that will attach it after sending an
    /// acknowledgement. This avoids making a short-lived acknowledgement value
    /// the lifetime owner of an otherwise active server subscription.
    func createSubscription(
        surfaceID: String?,
        fromSequence: UInt64?,
        maxChunkBytes: Int = LiveIOEventHub.maxChunkBytes,
        queueCapacity: Int = 64
    ) throws -> UInt64 {
        guard (1...Self.maxChunkBytes).contains(maxChunkBytes) else {
            throw LiveIOError.invalidChunkBytes
        }
        guard (1...Self.maxQueueCapacity).contains(queueCapacity) else {
            throw LiveIOError.invalidQueueCapacity
        }
        nextSubscriptionID &+= 1
        let id = nextSubscriptionID
        let startingSequence = fromSequence ?? nextSequence &+ 1
        var continuation: AsyncStream<LiveIOEvent>.Continuation!
        let stream = AsyncStream<LiveIOEvent>(bufferingPolicy: .bufferingNewest(queueCapacity)) {
            continuation = $0
        }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscription(subscriptionID: id)
            }
        }
        subscriptions[id] = State(
            surfaceID: surfaceID,
            fromSequence: startingSequence,
            maxChunkBytes: maxChunkBytes,
            queueCapacity: queueCapacity,
            continuation: continuation,
            stream: stream
        )
        return id
    }

    /// The next sequence number that a newly-created subscription would see.
    public func nextSequenceNumber() -> UInt64 {
        nextSequence &+ 1
    }

    public func subscription(id: UInt64) -> LiveIOSubscription? {
        guard let state = subscriptions[id] else { return nil }
        return LiveIOSubscription(id: id, stream: state.stream)
    }

    @discardableResult
    public func publish(
        surfaceID: String,
        kind: LiveIOEventKind,
        bytes: [UInt8],
        timestamp: String? = nil
    ) throws -> UInt64 {
        // This is a sequence for the source event, not for an individual
        // delivery. Allocate it before fanout so every subscriber can compare
        // a particular terminal event against the same global cursor.
        let sequence = nextSequence &+ 1
        nextSequence = sequence
        let matchingIDs = subscriptions.compactMap { id, state in
            state.surfaceID == nil || state.surfaceID == surfaceID ? id : nil
        }

        for id in matchingIDs {
            guard let initialState = subscriptions[id] else { continue }
            let chunkSize = initialState.maxChunkBytes
            let chunks: [[UInt8]] = bytes.isEmpty ? [[]] : stride(from: 0, to: bytes.count, by: chunkSize).map {
                Array(bytes[$0 ..< min($0 + chunkSize, bytes.count)])
            }
            for chunk in chunks {
                guard var state = subscriptions[id], sequence >= state.fromSequence else { continue }
                let encoded = chunk.isEmpty ? nil : Data(chunk).base64EncodedString()
                let event = LiveIOEvent(
                    subscriptionID: id,
                    surfaceID: surfaceID,
                    seq: sequence,
                    kind: kind,
                    timestamp: timestamp,
                    eventBytesBase64: encoded,
                    dropped: state.dropped > 0 ? state.dropped : nil,
                    resyncRequired: state.dropped > 0 ? true : nil
                )
                let result = state.continuation.yield(event)
                if case .dropped = result {
                    state.dropped += 1
                } else {
                    state.dropped = 0
                }
                subscriptions[id] = state
            }
        }
        return sequence
    }

    /// Publish a bounded visible-screen update only when its bytes differ from
    /// the most recently published payload for the surface. Callers own the
    /// byte bound; this method is intentionally actor-isolated so concurrent
    /// AppKit refreshes cannot race the duplicate filter.
    @discardableResult
    public func publishScreenChanged(
        surfaceID: String,
        bytes: [UInt8],
        timestamp: String? = nil
    ) throws -> UInt64? {
        guard lastScreenPayloadBySurface[surfaceID] != bytes else { return nil }
        lastScreenPayloadBySurface[surfaceID] = bytes
        return try publish(
            surfaceID: surfaceID,
            kind: .screenChanged,
            bytes: bytes,
            timestamp: timestamp
        )
    }

    private func removeSubscription(subscriptionID: UInt64) {
        _ = subscriptions.removeValue(forKey: subscriptionID)
    }

    @discardableResult
    public func unsubscribe(subscriptionID: UInt64) -> Bool {
        guard let state = subscriptions.removeValue(forKey: subscriptionID) else { return false }
        state.continuation.finish()
        if subscriptions.isEmpty {
            lastScreenPayloadBySurface.removeAll(keepingCapacity: true)
        }
        return true
    }

    @discardableResult
    public func unsubscribe(_ subscription: LiveIOSubscription) -> Bool {
        unsubscribe(subscriptionID: subscription.id)
    }
}
