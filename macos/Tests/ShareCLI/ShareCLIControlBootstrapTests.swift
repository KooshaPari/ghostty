import Foundation
import Testing
@testable import Ghostty

@MainActor
struct ShareCLIControlBootstrapTests {
    @Test func startsOnceWhenReadyAndStopsBeforeRegistryTeardown() {
        let control = ShareCLIControlBootstrap()

        #expect(control.state == .stopped)
        #expect(control.start() == true)
        #expect(control.start() == false)
        #expect(control.state == .running)

        control.stop()

        #expect(control.state == .stopped)
        #expect(control.surfaceIDs.isEmpty)
    }

    @Test func bindsWeaklyByStableUUIDAndReportsUnsupportedCapabilities() throws {
        let control = ShareCLIControlBootstrap()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var surface: FakeSurface? = .init(id: id, screen: "abcdef")

        control.bind(surface!)

        #expect(control.surfaceIDs == [id])
        #expect(try control.foregroundPID(for: id) == 42)
        #expect(try control.ttyName(for: id) == "/dev/ttys001")
        #expect(try control.readVisibleScreen(for: id, maximumBytes: 4) == "abcd")
        #expect(control.capability(.rawPTY) == .unavailable)
        #expect(control.capability(.liveIO) == .unavailable)
        #expect(control.capability(.layout) == .unavailable)
        #expect(control.capability(.resize) == .unavailable)

        surface = nil

        #expect(control.surfaceIDs.isEmpty)
        #expect(throws: ShareCLIControlError.surfaceUnavailable(id)) {
            try control.foregroundPID(for: id)
        }
    }

    @Test func synchronizesTheAppOwnedSurfaceSnapshotAsOneCompleteInventory() async throws {
        let control = ShareCLIControlBootstrap()
        let first = FakeSurface(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            screen: "first"
        )
        let second = FakeSurface(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            screen: "second"
        )

        #expect(control.start())
        control.synchronize([first, second])

        let inventory = try await control.registry.surfaceInventory()
        #expect(inventory.complete)
        #expect(inventory.surfaces.map(\.id) == [
            first.shareCLIControlID.uuidString,
            second.shareCLIControlID.uuidString,
        ])

        control.stop()
    }
}

@MainActor
private final class FakeSurface: ShareCLIControlSurface {
    let shareCLIControlID: UUID
    let screen: String

    init(id: UUID, screen: String) {
        shareCLIControlID = id
        self.screen = screen
    }

    var shareCLIWriteAvailable: Bool { false }

    func shareCLISendText(_ text: String) throws {}

    var shareCLIForegroundPID: Int? { 42 }
    var shareCLITTYName: String? { "/dev/ttys001" }
    var shareCLIVisibleScreenText: String { screen }
}
