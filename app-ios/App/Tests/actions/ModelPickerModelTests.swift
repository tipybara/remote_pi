import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// Model picker states and filtering (spec 08 §8.12).
@MainActor
final class ModelPickerModelTests: XCTestCase {
    private var service = FakeActionsService()
    private var quickActions = QuickActionsModel()
    private let session = Fixture.session()

    private func makeModel() -> ModelPickerModel {
        service = FakeActionsService()
        quickActions = QuickActionsModel()
        quickActions.bind(to: service, session: session)
        let model = ModelPickerModel()
        model.bind(to: service, session: session, quickActions: quickActions)
        return model
    }

    private func catalogue(
        _ models: [WireModel], current: WireModel? = nil
    ) -> ModelCatalogue {
        ModelCatalogue(models: models, current: current)
    }

    // MARK: - The four snapshot states

    func testStartsLoading() {
        XCTAssertEqual(makeModel().phase, .loading)
    }

    func testLoadedCatalogue() async {
        let model = makeModel()
        let opus = Fixture.model("opus", name: "Opus")
        service.listModelsResult = .success(catalogue([opus], current: opus))
        await model.load()

        XCTAssertEqual(model.phase, .loaded(catalogue([opus], current: opus)))
        XCTAssertEqual(service.calls, [.listModels(session, forceRefresh: false)])
    }

    /// An empty catalogue is a **successful answer**, not a failure — offering
    /// Retry for a Pi with no models configured would be a loop.
    func testEmptyCatalogueIsLoadedNotFailed() async {
        let model = makeModel()
        service.listModelsResult = .success(.empty)
        await model.load()

        XCTAssertEqual(model.phase, .loaded(.empty))
        XCTAssertTrue(model.filteredModels.isEmpty)
    }

    func testFailureCarriesTheActionMessage() async {
        let model = makeModel()
        service.listModelsResult = .failure(ActionFailure("no model registry configured"))
        await model.load()
        XCTAssertEqual(model.phase, .failed("no model registry configured"))
    }

    func testUnboundPickerFailsRatherThanHanging() async {
        let model = ModelPickerModel()
        await model.load()
        XCTAssertEqual(model.phase, .failed(ActionFailure.notWired.message))
    }

    func testRefreshForcesARefetch() async {
        let model = makeModel()
        await model.load()
        await model.load(forceRefresh: true)
        XCTAssertEqual(
            service.calls,
            [.listModels(session, forceRefresh: false), .listModels(session, forceRefresh: true)])
    }

    // MARK: - Providers

    func testProviderChipsOnlyWhenMoreThanOneProvider() async {
        let model = makeModel()
        service.listModelsResult = .success(
            catalogue([Fixture.model("a", provider: "anthropic")]))
        await model.load()
        XCTAssertFalse(model.showsProviderChips)

        service.listModelsResult = .success(
            catalogue([
                Fixture.model("a", provider: "openai"),
                Fixture.model("b", provider: "anthropic"),
            ]))
        await model.load(forceRefresh: true)
        XCTAssertTrue(model.showsProviderChips)
        XCTAssertEqual(model.providers, ["anthropic", "openai"], "sorted")
    }

    func testProviderFilter() async {
        let model = makeModel()
        let a = Fixture.model("a", provider: "openai")
        let b = Fixture.model("b", provider: "anthropic")
        service.listModelsResult = .success(catalogue([a, b]))
        await model.load()

        XCTAssertEqual(model.filteredModels, [a, b], "the `all` chip")
        model.selectProvider("anthropic")
        XCTAssertEqual(model.filteredModels, [b])
    }

    /// A filter the new catalogue cannot honour would render an empty list
    /// with a chip selected and nothing to explain it.
    func testStaleProviderFilterIsDroppedOnReload() async {
        let model = makeModel()
        service.listModelsResult = .success(
            catalogue([
                Fixture.model("a", provider: "openai"),
                Fixture.model("b", provider: "anthropic"),
            ]))
        await model.load()
        model.selectProvider("openai")

        service.listModelsResult = .success(
            catalogue([Fixture.model("b", provider: "anthropic")]))
        await model.load(forceRefresh: true)

        XCTAssertNil(model.providerFilter)
        XCTAssertEqual(model.filteredModels.count, 1)
    }

    // MARK: - Current

    /// "Current" compares **both** id and provider (§8.12, `:246-247`): two
    /// providers routinely expose the same model id.
    func testCurrentComparesIDAndProvider() async {
        let model = makeModel()
        let anthropic = Fixture.model("claude-sonnet-4.5", provider: "anthropic")
        let proxy = Fixture.model("claude-sonnet-4.5", provider: "bedrock")
        service.listModelsResult = .success(catalogue([anthropic, proxy], current: proxy))
        await model.load()

        XCTAssertFalse(model.isCurrent(anthropic))
        XCTAssertTrue(model.isCurrent(proxy))
    }

    func testNoCurrentMeansNoCheckMark() async {
        let model = makeModel()
        let entry = Fixture.model("a")
        service.listModelsResult = .success(catalogue([entry]))
        await model.load()
        XCTAssertFalse(model.isCurrent(entry))
    }

    // MARK: - Subtitle

    func testSubtitleOmitsAnUnreportedContextWindow() {
        let model = makeModel()
        XCTAssertEqual(
            model.subtitle(for: Fixture.model("a", provider: "openai", contextWindow: 0)),
            "openai")
    }

    func testSubtitleHumanizesTheContextWindow() {
        let model = makeModel()
        XCTAssertEqual(
            model.subtitle(
                for: Fixture.model("a", provider: "anthropic", contextWindow: 200_000)),
            "anthropic · ctx 200k")
        XCTAssertEqual(
            model.subtitle(for: Fixture.model("a", provider: "anthropic", contextWindow: 512)),
            "anthropic · ctx 512")
        XCTAssertEqual(
            model.subtitle(for: Fixture.model("a", provider: "anthropic", contextWindow: 1_500)),
            "anthropic · ctx 2k", "rounded, like the Dart `(ctx / 1000).round()`")
    }

    // MARK: - Row identity

    /// `id` alone is not unique; a `ForEach` keyed on it would collapse two
    /// providers' rows into one.
    func testRowIDIncludesTheProvider() {
        XCTAssertNotEqual(
            Fixture.model("m", provider: "openai").pickerRowID,
            Fixture.model("m", provider: "anthropic").pickerRowID)
    }

    // MARK: - Picking

    func testPickDelegatesToTheParentAndReportsSuccess() async {
        let model = makeModel()
        let entry = Fixture.model("opus", name: "Opus")
        service.listModelsResult = .success(catalogue([entry]))
        await model.load()

        let popped = await model.pick(entry)
        XCTAssertTrue(popped)
        XCTAssertEqual(quickActions.currentModel, entry)
        XCTAssertNil(model.pickingModelID, "the in-flight marker is cleared")
    }

    /// A failed pick keeps the list up so the user can choose something else;
    /// the message appears on the parent sheet underneath.
    func testFailedPickKeepsTheSubSheetOpenAndToastsOnTheParent() async {
        let model = makeModel()
        let entry = Fixture.model("opus")
        service.listModelsResult = .success(catalogue([entry]))
        await model.load()
        service.setModelFailure = ActionFailure("no auth configured")

        let popped = await model.pick(entry)
        XCTAssertFalse(popped)
        XCTAssertEqual(quickActions.errorMessage, "no auth configured")
    }

    /// Loading a catalogue upgrades the parent's Model row from a display name
    /// to a structured record.
    func testLoadAdoptsTheCurrentModelIntoTheParent() async {
        let model = makeModel()
        let current = Fixture.model("opus", name: "Opus 4.7")
        service.listModelsResult = .success(catalogue([current], current: current))
        await model.load()
        XCTAssertEqual(quickActions.modelRowLabel, "Opus 4.7")
    }
}
