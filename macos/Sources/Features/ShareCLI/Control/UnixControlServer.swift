// Vendored from ShareCLI's canonical contrib/ghostty-control package.
// See ../README.md for integration provenance and capability bounds.
import Foundation
import Darwin

/// Owner-only newline-delimited Unix-domain listener for a native Ghostty app.
public final class UnixControlServer: @unchecked Sendable {
    public let path: String

    private static let maxSocketPathBytes = 104
    private let dispatcher: ControlDispatcher
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ActiveConnection] = [:]

    public init(path: String, dispatcher: ControlDispatcher) {
        self.path = path
        self.dispatcher = dispatcher
        self.queue = DispatchQueue(label: "sharecli.ghostty-control", qos: .userInitiated)
    }

    deinit { stopImmediately() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenerFD < 0 else { return }
        guard path.utf8.count + 1 <= Self.maxSocketPathBytes else {
            throw ControlError.invalidRequest("control socket path is too long")
        }
        removeExistingSocketIfSafe()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("create control socket") }
        do {
            var address = try unixAddress(path)
            let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, addressLength)
                }
            }
            guard bound == 0 else { throw socketError("bind control socket") }
            guard Darwin.listen(fd, 16) == 0 else { throw socketError("listen control socket") }
            guard Darwin.fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw socketError("configure control socket")
            }
            guard Darwin.chmod(path, mode_t(0o600)) == 0 else {
                throw socketError("protect control socket")
            }
            listenerFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnections() }
            // Listener ownership stays with this object rather than the
            // dispatch-source cancellation handler. Teardown must close the
            // descriptor synchronously, before Ghostty destroys a surface or
            // PTY that an already accepted request could otherwise reach.
            source.setCancelHandler {}
            source.resume()
            self.source = source
        } catch {
            Darwin.close(fd)
            removeExistingSocketIfSafe()
            throw error
        }
    }

    /// Close the listener and await all accepted request and event-forwarding
    /// tasks. Callers may tear down their native provider only after this
    /// method returns.
    public func stop() async {
        let work = beginStop()
        closeListener(work.listenerFD)
        work.source?.cancel()
        removeExistingSocketIfSafe()
        for connection in work.connections {
            await connection.cancelAndWait()
        }
    }

    /// Synchronous termination path for `deinit` and native app teardown,
    /// where Swift cannot await. It closes the listener and interrupts clients
    /// before their provider may be invalidated; controlled shutdown may use
    /// `stop()` when it needs to await all connection tasks.
    func stopImmediately() {
        let work = beginStop()
        closeListener(work.listenerFD)
        work.source?.cancel()
        removeExistingSocketIfSafe()
        work.connections.forEach { $0.cancel() }
    }

    private func beginStop() -> (
        listenerFD: Int32,
        source: DispatchSourceRead?,
        connections: [ActiveConnection]
    ) {
        lock.lock()
        let activeListenerFD = listenerFD
        let activeSource = source
        source = nil
        listenerFD = -1
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        return (activeListenerFD, activeSource, activeConnections)
    }

    private func closeListener(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    private func acceptConnections() {
        while true {
            lock.lock()
            let listenerFD = self.listenerFD
            lock.unlock()
            guard listenerFD >= 0 else { return }
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            guard peerBelongsToCurrentUser(fd) else {
                Darwin.close(fd)
                continue
            }
            let connection = ActiveConnection(fd: fd)
            lock.lock()
            let accepting = self.listenerFD >= 0
            if accepting {
                connections[ObjectIdentifier(connection)] = connection
            }
            lock.unlock()
            guard accepting else {
                connection.cancel()
                continue
            }
            let task = Task.detached(priority: .userInitiated) { [weak self, weak connection] in
                guard let connection else { return }
                await self?.serveConnection(connection)
            }
            connection.setTask(task)
        }
    }

    private func peerBelongsToCurrentUser(_ fd: Int32) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else { return false }
        return peerUID == geteuid()
    }

    private func serveConnection(_ connection: ActiveConnection) async {
        let fd = connection.fd
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        connectionLoop: while !Task.isCancelled {
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= ControlDispatcher.maxRequestBytes else { break }
            while let newline = buffer.firstIndex(of: 0x0a) {
                guard !Task.isCancelled else { break connectionLoop }
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                var response = await dispatcher.dispatch(Data(line))
                if !response.isEmpty {
                    response.append(0x0a)
                    guard connection.writer.send(response) else { break connectionLoop }
                }
                if let subscriptionID = subscriptionID(from: response),
                   let liveEvents = dispatcher.liveEvents,
                   let subscription = await liveEvents.subscription(id: subscriptionID) {
                    connection.addSubscription(subscriptionID)
                    let task = Task.detached(priority: .userInitiated) { [writer = connection.writer] in
                        for await event in subscription {
                            guard let data = Self.encodeEvent(event) else { return }
                            var line = data
                            line.append(0x0a)
                            guard writer.send(line) else { return }
                        }
                    }
                    connection.addEventTask(task)
                }
            }
        }
        await finishConnection(connection)
    }

    private func finishConnection(_ connection: ActiveConnection) async {
        connection.interrupt()
        await connection.cancelEventTasksAndWait()
        connection.writer.close()
        if let liveEvents = dispatcher.liveEvents {
            for subscriptionID in connection.subscriptionIDs() {
                _ = await liveEvents.unsubscribe(subscriptionID: subscriptionID)
            }
        }
        removeConnection(connection)
        connection.finish()
    }

    private func removeConnection(_ connection: ActiveConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private static func encodeEvent(_ event: LiveIOEvent) -> Data? {
        guard let params = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "surface.io.event",
            "params": params,
        ])
    }

    private func subscriptionID(from response: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return nil }
        guard let value = result["subscription_id"] as? NSNumber else { return nil }
        let type = String(cString: value.objCType)
        guard ["i", "s", "l", "q", "I", "S", "L", "Q"].contains(type),
              value.int64Value >= 0 else { return nil }
        return value.uint64Value
    }

    private func removeExistingSocketIfSafe() {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(path)
    }

    private func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { pointer in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: UnsafeRawBufferPointer(start: pointer, count: path.utf8.count + 1))
            }
        }
        return address
    }

    private func socketError(_ operation: String) -> ControlError {
        .provider("\(operation): \(String(cString: strerror(errno)))")
    }
}

private final class ActiveConnection: @unchecked Sendable {
    let fd: Int32
    let writer: SocketWriter

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var eventTasks: [Task<Void, Never>] = []
    private var registeredSubscriptions = Set<UInt64>()
    private var cancelRequested = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(fd: Int32) {
        self.fd = fd
        self.writer = SocketWriter(fd: fd)
    }

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func addEventTask(_ task: Task<Void, Never>) {
        lock.lock()
        eventTasks.append(task)
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func addSubscription(_ id: UInt64) {
        lock.lock()
        registeredSubscriptions.insert(id)
        lock.unlock()
    }

    func subscriptionIDs() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return Array(registeredSubscriptions)
    }

    func interrupt() {
        writer.interrupt()
    }

    func cancelEventTasksAndWait() async {
        let tasks = takeEventTasks()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func takeEventTasks() -> [Task<Void, Never>] {
        lock.lock()
        let tasks = eventTasks
        eventTasks.removeAll()
        lock.unlock()
        return tasks
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let connectionTask = task
        let tasks = eventTasks
        lock.unlock()
        connectionTask?.cancel()
        tasks.forEach { $0.cancel() }
        writer.interrupt()
        writer.close()
    }

    func cancelAndWait() async {
        cancel()
        await waitUntilFinished()
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if isFinished() { return }
        await withCheckedContinuation { continuation in
            enqueueFinishWaiter(continuation)
        }
    }

    private func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func enqueueFinishWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume()
            return
        }
        finishWaiters.append(continuation)
        lock.unlock()
    }
}

private final class SocketWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        Darwin.close(fd)
        lock.unlock()
    }

    func interrupt() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
}
