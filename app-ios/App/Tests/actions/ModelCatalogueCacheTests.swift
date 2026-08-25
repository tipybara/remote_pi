import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// The per-session `list_models` cache and its three invalidation paths
/// (spec 08 §8.11, `actions_repository.dart:13-21`).
@MainActor
final class ModelCatalogueCacheTests: XCTestCase {
    private let a = Fixture.session(1, room: "room-a")
    private let b = Fixture.session(1, room: "room-b")

    private func catalogue(current: String?) -> ModelCatalogue {
        let model = Fixture.model("id", name: current ?? "unused")
        return ModelCatalogue(models: [model], current: current == nil ? nil : model)
    }

    func testStoreAndRead() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        XCTAssertEqual(cache.value(for: a)?.current?.name, "Opus")
        XCTAssertNil(cache.value(for: b))
    }

    /// Keyed by session, not by machine: two sessions on one Mac can run
    /// different models, and the reply's `current` belongs to exactly one.
    func testEntriesAreScopedToOneSession() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        cache.store(catalogue(current: "Sonnet"), for: b)
        cache.invalidate(a)

        XCTAssertNil(cache.value(for: a))
        XCTAssertEqual(cache.value(for: b)?.current?.name, "Sonnet")
    }

    func testInvalidateAll() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        cache.store(catalogue(current: "Sonnet"), for: b)
        cache.invalidateAll()
        XCTAssertNil(cache.value(for: a))
        XCTAssertNil(cache.value(for: b))
    }

    /// Invalidation path 2: the room's live meta names a model the cached
    /// `current` disagrees with — someone else switched.
    func testExternalSwitchInvalidates() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        cache.invalidateIfCurrentDisagrees(with: RoomFacts(modelName: "Sonnet"), for: a)
        XCTAssertNil(cache.value(for: a))
    }

    func testAgreementKeepsTheEntry() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        cache.invalidateIfCurrentDisagrees(with: RoomFacts(modelName: "Opus"), for: a)
        XCTAssertNotNil(cache.value(for: a))
    }

    /// A relay that has not reported a model yet says nothing about the
    /// catalogue; dropping the entry there would put a round-trip in front of
    /// every picker open on a quiet room.
    func testUnknownMetaKeepsTheEntry() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: "Opus"), for: a)
        cache.invalidateIfCurrentDisagrees(with: .unknown, for: a)
        XCTAssertNotNil(cache.value(for: a))
    }

    /// A catalogue the Pi answered without a `current` cannot disagree with
    /// anything.
    func testCatalogueWithoutACurrentIsNeverInvalidatedThisWay() {
        let cache = ModelCatalogueCache()
        cache.store(catalogue(current: nil), for: a)
        cache.invalidateIfCurrentDisagrees(with: RoomFacts(modelName: "Sonnet"), for: a)
        XCTAssertNotNil(cache.value(for: a))
    }
}

/// `RoomFacts` parses the two `room_meta` fields the sheet hydrates from.
final class RoomFactsTests: XCTestCase {
    func testReadsModelAndThinkingFromRoomMeta() {
        let meta = RoomMeta(
            roomID: RoomID("r"), model: "claude-sonnet-4.5", thinking: "high")
        let facts = RoomFacts(meta)
        XCTAssertEqual(facts.modelName, "claude-sonnet-4.5")
        XCTAssertEqual(facts.thinking, .high)
    }

    /// The relay never interprets `thinking`, so a newer Pi's level must be
    /// kept raw rather than forced into a known case.
    func testUnknownThinkingLevelStaysRawAndParsesToNil() {
        let facts = RoomFacts(RoomMeta(roomID: RoomID("r"), thinking: "ultra"))
        XCTAssertEqual(facts.thinkingRaw, "ultra")
        XCTAssertNil(facts.thinking)
    }

    func testUnknownIsEmpty() {
        XCTAssertNil(RoomFacts.unknown.modelName)
        XCTAssertNil(RoomFacts.unknown.thinking)
    }
}
