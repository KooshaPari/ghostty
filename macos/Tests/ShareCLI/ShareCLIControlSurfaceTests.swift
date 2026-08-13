import Foundation
import Testing
@testable import Ghostty

@MainActor
struct ShareCLIControlSurfaceTests {
    @Test func unbindRemovesTheStableSurfaceIdentity() {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let surface = TestSurface(id: id, screen: "screen")

        control.bind(surface)
        #expect(control.surfaceIDs == [id])
        #expect(control.inventoryIsComplete == false)

        control.unbind(id)
        #expect(control.surfaceIDs.isEmpty)
        #expect(throws: ShareCLIControlError.surfaceUnavailable(id)) {
            try control.ttyName(for: id)
        }
    }

    @Test func screenLimitNeverSplitsUTF8IntoReplacementText() throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let surface = TestSurface(id: id, screen: "éx")

        control.bind(surface)
        #expect(try control.readVisibleScreen(for: id, maximumBytes: 1).isEmpty)
        #expect(try control.readVisibleScreen(for: id, maximumBytes: 2) == "é")
        #expect(try control.readVisibleScreen(for: id, maximumBytes: 3) == "éx")
        #expect(throws: ShareCLIControlError.invalidTextPayload) {
            try control.readVisibleScreen(for: id, maximumBytes: -1)
        }
    }

    @Test func inventoryBatchRestoresCompletenessWithMonotonicGeneration() async throws {
        let registry = SurfaceProviderRegistry()
        let binding = testBinding(id: "surface-a")
        let replacement = testBinding(id: "surface-b")

        try registry.replaceInventory([binding], generation: 4)
        let stable = try await registry.surfaceInventory()
        #expect(stable.complete == true)
        #expect(stable.generation == "4")

        #expect(throws: ControlError.provider("inventory generation must increase: 4 <= 4")) {
            try registry.replaceInventory([replacement], generation: 4)
        }
        let duplicate = try await registry.surfaceInventory()
        #expect(duplicate.complete == true)
        #expect(duplicate.generation == "4")
        #expect(duplicate.surfaces.map(\.id) == ["surface-a"])

        registry.markInventoryIncomplete()
        let transitional = try await registry.surfaceInventory()
        #expect(transitional.complete == false)
        #expect(transitional.generation == "4")

        #expect(throws: ControlError.provider("inventory generation must increase: 3 <= 4")) {
            try registry.replaceInventory([binding], generation: 3)
        }
        let rejected = try await registry.surfaceInventory()
        #expect(rejected.complete == false)
        #expect(rejected.generation == "4")
        #expect(rejected.surfaces.map(\.id) == ["surface-a"])

        try registry.replaceInventory([binding], generation: 5)
        let advanced = try await registry.surfaceInventory()
        #expect(advanced.complete == true)
        #expect(advanced.generation == "5")
        #expect(advanced.surfaces.map(\.id) == ["surface-a"])

        registry.invalidate()
        let invalidated = try await registry.surfaceInventory()
        #expect(invalidated.complete == false)
        #expect(invalidated.generation == "5")
        #expect(invalidated.surfaces.isEmpty)
    }

    @Test func individualBindingMutationsWithdrawCompleteness() async throws {
        let registry = SurfaceProviderRegistry()
        let first = testBinding(id: "surface-a")
        let second = testBinding(id: "surface-b")

        try registry.replaceInventory([first], generation: 10)
        try registry.register(second)
        var inventory = try await registry.surfaceInventory()
        #expect(inventory.complete == false)
        #expect(inventory.generation == "10")
        #expect(inventory.surfaces.map(\.id) == ["surface-a", "surface-b"])

        try registry.replaceInventory([first, second], generation: 11)
        _ = try registry.replace(second)
        inventory = try await registry.surfaceInventory()
        #expect(inventory.complete == false)
        #expect(inventory.generation == "11")

        try registry.replaceInventory([first, second], generation: 12)
        #expect(registry.unregister(surfaceID: "surface-b") == true)
        inventory = try await registry.surfaceInventory()
        #expect(inventory.complete == false)
        #expect(inventory.generation == "12")
        #expect(inventory.surfaces.map(\.id) == ["surface-a"])
    }

    @Test func unavailableWriteIsNeverAdvertisedOrAccepted() async throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let surface = TestSurface(id: id, screen: "screen", writeAvailable: false)

        #expect(control.start())
        control.bind(surface)

        #expect(control.capability(.sendText) == .unavailable)
        let capabilities = try await control.registry.capabilities(surfaceID: id.uuidString)
        #expect(capabilities.write == false)
        try await #expect(throws: ControlError.provider("native Ghostty text injection unavailable: \(id.uuidString)")) {
            try await control.registry.send(surfaceID: id.uuidString, bytes: Array("hello".utf8))
        }

        control.stop()
    }

    @Test func terminationSynchronouslyInvalidatesProviderBeforeTeardown() async throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let surface = TestSurface(id: id, screen: "screen", writeAvailable: true)

        #expect(control.start())
        control.bind(surface)
        try await control.registry.send(surfaceID: id.uuidString, bytes: Array("before-stop".utf8))
        #expect(surface.sentText == ["before-stop"])

        control.stop()

        #expect(control.state == .stopped)
        #expect(control.surfaceIDs.isEmpty)
        #expect(control.capability(.sendText) == .unavailable)
        try await #expect(throws: ControlError.provider("surface unavailable: \(id.uuidString)")) {
            try await control.registry.send(surfaceID: id.uuidString, bytes: Array("after-stop".utf8))
        }
        #expect(surface.sentText == ["before-stop"])
    }

    @Test func screenChangedEventSerializesAndPreservesSequence() async throws {
        let hub = LiveIOEventHub()
        let subscription = try await hub.subscribe(surfaceID: "surface-a", fromSequence: nil)

        let firstSequence = try await hub.publish(
            surfaceID: "surface-a",
            kind: .screenChanged,
            bytes: Array("screen".utf8),
            timestamp: "2026-08-08T04:20:00Z"
        )
        let secondSequence = try await hub.publish(
            surfaceID: "surface-a",
            kind: .output,
            bytes: Array("output".utf8)
        )

        var iterator = subscription.makeAsyncIterator()
        let firstEvent = try #require(await iterator.next())
        #expect(firstEvent.seq == firstSequence)
        #expect(firstEvent.kind == .screenChanged)
        let encoded = try JSONEncoder().encode(firstEvent)
        #expect(String(data: encoded, encoding: .utf8)?.contains("\"kind\":\"screen_changed\"") == true)
        #expect(try JSONDecoder().decode(LiveIOEvent.self, from: encoded) == firstEvent)

        let secondEvent = try #require(await iterator.next())
        #expect(secondEvent.seq == secondSequence)
        #expect(secondEvent.seq > firstEvent.seq)
    }

    @Test func oneSourceEventHasOneSequenceAcrossSubscribers() async throws {
        let hub = LiveIOEventHub()
        let first = try await hub.subscribe(surfaceID: "surface-a", fromSequence: nil)
        let second = try await hub.subscribe(surfaceID: "surface-a", fromSequence: nil)

        let publishedSequence = try await hub.publish(
            surfaceID: "surface-a",
            kind: .output,
            bytes: Array("shared output".utf8)
        )

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let firstEvent = try #require(await firstIterator.next())
        let secondEvent = try #require(await secondIterator.next())

        #expect(firstEvent.seq == publishedSequence)
        #expect(secondEvent.seq == publishedSequence)
        #expect(firstEvent.seq == secondEvent.seq)
        #expect(firstEvent.subscriptionID != secondEvent.subscriptionID)
    }

    @Test func duplicateScreenChangedPayloadsAreSuppressed() async throws {
        let hub = LiveIOEventHub()
        let subscription = try await hub.subscribe(surfaceID: "surface-a", fromSequence: nil)

        let firstSequence = try #require(
            await hub.publishScreenChanged(surfaceID: "surface-a", bytes: Array("first".utf8))
        )
        #expect(
            try await hub.publishScreenChanged(surfaceID: "surface-a", bytes: Array("first".utf8)) == nil
        )
        let thirdSequence = try #require(
            await hub.publishScreenChanged(surfaceID: "surface-a", bytes: Array("changed".utf8))
        )
        #expect(thirdSequence > firstSequence)

        var iterator = subscription.makeAsyncIterator()
        let firstEvent = try #require(await iterator.next())
        #expect(firstEvent.seq == firstSequence)
        let thirdEvent = try #require(await iterator.next())
        #expect(thirdEvent.seq == thirdSequence)
    }

    @Test func bootstrapPublishesVisibleScreenToLiveSubscribers() async throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let surface = TestSurface(id: id, screen: "native screen")

        #expect(control.start())
        control.bind(surface)
        #expect(control.capability(.liveIO) == .available)
        let subscription = try await control.liveEvents.subscribe(
            surfaceID: id.uuidString,
            fromSequence: nil
        )

        await control.publishVisibleScreen(surface).value

        var iterator = subscription.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.surfaceID == id.uuidString)
        #expect(event.kind == .screenChanged)
        #expect(event.eventBytesBase64 == Data("native screen".utf8).base64EncodedString())

        control.stop()
    }

    @Test func renderInvalidationsPublishOnlyChangedViewportBytesForTheConcreteSurfaceID() async throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let surface = TestSurface(id: id, screen: "visible viewport")

        #expect(control.start())
        control.bind(surface)
        let subscription = try await control.liveEvents.subscribe(
            surfaceID: id.uuidString,
            fromSequence: nil
        )

        await control.publishVisibleScreen(surface).value
        let sequenceAfterFirstRender = await control.liveEvents.nextSequenceNumber()
        await control.publishVisibleScreen(surface).value

        #expect(await control.liveEvents.nextSequenceNumber() == sequenceAfterFirstRender)
        #expect(control.capability(.rawPTY) == .unavailable)

        var iterator = subscription.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.surfaceID == id.uuidString)
        #expect(event.kind == .screenChanged)
        #expect(event.eventBytesBase64 == Data("visible viewport".utf8).base64EncodedString())

        control.stop()
    }
}

@MainActor
private final class TestSurface: ShareCLIControlSurface {
    let shareCLIControlID: UUID
    let screen: String
    let writeAvailable: Bool
    private(set) var sentText: [String] = []

    init(id: UUID, screen: String, writeAvailable: Bool = false) {
        shareCLIControlID = id
        self.screen = screen
        self.writeAvailable = writeAvailable
    }

    var shareCLIWriteAvailable: Bool { writeAvailable }

    func shareCLISendText(_ text: String) throws {
        guard writeAvailable else { throw ShareCLIControlError.writeUnavailable(shareCLIControlID) }
        sentText.append(text)
    }

    var shareCLIForegroundPID: Int? { nil }
    var shareCLITTYName: String? { nil }
    var shareCLIVisibleScreenText: String { screen }
}

private func testBinding(id: String) -> SurfaceBinding {
    SurfaceBinding(
        record: SurfaceRecord(id: id, title: nil, cwd: "", process: nil),
        send: { _ in },
        read: { _ in [] },
        resize: { _, _ in },
        capabilities: {
            SurfaceCapabilities(read: true, write: false, resize: false, layout: false, durablePty: false)
        }
    )
}
