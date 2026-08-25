import Foundation
import RemotePiProtocol
import Testing

#if canImport(ComposerHarness)
@testable import ComposerHarness
#else
@testable import RemotePi
#endif

@MainActor
@Suite("Queued follow-ups (spec 08 §8.8)")
struct QueuedMessagesModelTests {
    @Test("queued_message_state replaces the queue wholesale")
    func fullReplacement() {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)

        model.apply(.init(items: [.init(id: "a", text: "one"), .init(id: "b", text: "two")]))
        #expect(model.items.map(\.id) == ["a", "b"])

        // Not a delta: the drained item must disappear, not linger.
        model.apply(.init(items: [.init(id: "b", text: "two")]))
        #expect(model.items.map(\.id) == ["b"])

        model.apply(.init(items: []))
        #expect(model.items.isEmpty)
    }

    @Test("Empty-text items are dropped rather than rendered as a blank row")
    func dropsEmptyText() {
        let model = QueuedMessagesModel(sink: FakeComposerHost())
        model.apply(.init(items: [.init(id: "a", text: ""), .init(id: "b", text: "kept")]))
        #expect(model.items.map(\.id) == ["b"])
    }

    @Test("The legacy single-item wire shape decodes with editable defaults")
    func legacyWireShape() throws {
        let json = #"{"type":"queued_message_state","id":"q9","text":"legacy"}"#
        let decoded = try WireJSON.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .queuedMessageState(let state) = decoded else {
            Issue.record("expected queued_message_state, got \(decoded)")
            return
        }
        let model = QueuedMessagesModel(sink: FakeComposerHost())
        model.apply(state)

        #expect(model.items.count == 1)
        #expect(model.items[0].id == "q9")
        #expect(model.items[0].editable)
        #expect(model.items[0].createdAt == 0)
    }

    @Test("Queueing is optimistic and uses one id for the set and its clear")
    func queueMintsOneID() async {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)

        let id = await model.queue(text: "  after this  ")
        #expect(id != nil)
        #expect(model.items.map(\.text) == ["after this"], "the text is trimmed")
        #expect(host.queuedSets == [.init(id: id!, text: "after this")])

        await model.clear(id: id!)
        #expect(model.items.isEmpty)
        #expect(host.queuedClears == [id!], "the clear addresses the id minted at queue time")
    }

    @Test("An empty queue text is refused — a delete must say so")
    func refusesEmptyQueue() async {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)

        let id = await model.queue(text: "   \n ")
        #expect(id == nil)
        #expect(model.items.isEmpty)
        #expect(host.queuedSets.isEmpty, "an empty set would be read as a delete on the Pi")
    }

    @Test("take() pulls an editable item out; a committed one is inert")
    func take() async {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)
        model.apply(
            .init(items: [
                .init(id: "a", text: "editable one", editable: true),
                .init(id: "b", text: "committed", editable: false),
            ])
        )

        #expect(await model.take(model.items[1]) == nil)
        #expect(model.items.count == 2)
        #expect(host.queuedClears.isEmpty)

        #expect(await model.take(model.items[0]) == "editable one")
        #expect(model.items.map(\.id) == ["b"])
        #expect(host.queuedClears == ["a"])
    }

    @Test("clearAll omits target_id, which is the wire's clear-everything")
    func clearAll() async {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)
        model.apply(.init(items: [.init(id: "a", text: "one")]))

        await model.clearAll()

        #expect(model.items.isEmpty)
        #expect(host.queuedClears == [String?.none])
    }

    @Test("reset is local — leaving a session must not clear the Pi's queue")
    func resetIsLocal() {
        let host = FakeComposerHost()
        let model = QueuedMessagesModel(sink: host)
        model.apply(.init(items: [.init(id: "a", text: "one")]))

        model.reset()

        #expect(model.items.isEmpty)
        #expect(host.queuedClears.isEmpty)
    }

    @Test("Minted ids look like user_message ids and are unique")
    func idShape() {
        let first = newQueuedMessageID()
        let second = newQueuedMessageID()
        #expect(first.hasPrefix("cli_"))
        #expect(first != second)
        #expect(first == first.lowercased())
    }
}
