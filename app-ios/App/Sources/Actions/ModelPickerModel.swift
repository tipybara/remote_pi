import Foundation
import Observation
import RemotePiProtocol

/// The Model picker sub-sheet's behaviour (spec 08 §8.12).
///
/// Every state the spec's snapshot table lists is a case of ``Phase``, so
/// "loading", "failed" and "no models available" are reachable by construction
/// rather than by an `if` that someone forgets to write.
@MainActor
@Observable
final class ModelPickerModel {
    enum Phase: Equatable {
        case loading
        /// Includes the **empty** catalogue — the spec's "No models available"
        /// row. It is a successful answer, not a failure, and conflating the
        /// two would offer a Retry button for a Pi with no models configured.
        case loaded(ModelCatalogue)
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    /// `nil` = the `all` chip. Reset whenever a fresh catalogue lands, because
    /// a provider that is gone from the new catalogue would otherwise filter
    /// the list down to nothing with no visible reason.
    private(set) var providerFilter: String?

    /// Set while a `model_set` is resolving, so rows disable and the tapped
    /// row can show it is the one in flight.
    private(set) var pickingModelID: String?

    private var quickActions: QuickActionsModel?
    private var service: (any SessionActionsService)?
    private var session: SessionKey?

    init() {}

    /// The picker shares the parent sheet's view model by reference, matching
    /// Dart (`model_picker_sheet.dart:27-31`): a successful pick must update
    /// the *parent* Model row, and a failure must surface through the parent's
    /// toast, because this sheet is about to be gone.
    func bind(
        to service: any SessionActionsService,
        session: SessionKey,
        quickActions: QuickActionsModel
    ) {
        self.service = service
        self.session = session
        self.quickActions = quickActions
    }

    // MARK: - Derived

    var catalogue: ModelCatalogue? {
        if case .loaded(let value) = phase { return value }
        return nil
    }

    /// Sorted, de-duplicated providers of the loaded catalogue.
    var providers: [String] {
        guard let catalogue else { return [] }
        return Array(Set(catalogue.models.map(\.provider))).sorted()
    }

    /// The chips render **only when more than one provider exists**
    /// (§8.12, `:214`) — a single-provider row of chips is a control with one
    /// meaningful position.
    var showsProviderChips: Bool { providers.count > 1 }

    var filteredModels: [WireModel] {
        guard let catalogue else { return [] }
        guard let providerFilter else { return catalogue.models }
        return catalogue.models.filter { $0.provider == providerFilter }
    }

    /// "Current" compares **both** `id` and `provider` (§8.12, `:246-247`).
    /// Two providers routinely expose the same model id, and matching on id
    /// alone puts the check mark on the wrong row.
    func isCurrent(_ model: WireModel) -> Bool {
        guard let current = catalogue?.current else { return false }
        return current.id == model.id && current.provider == model.provider
    }

    /// `"<provider> · ctx 200k"`, or just the provider when the Pi did not
    /// report a context window (`contextWindow <= 0`).
    func subtitle(for model: WireModel) -> String {
        let window = model.contextWindow
        guard window > 0 else { return model.provider }
        let humanized = window >= 1000
            ? "\(Int((Double(window) / 1000).rounded()))k"
            : "\(window)"
        return "\(model.provider) · ctx \(humanized)"
    }

    func selectProvider(_ provider: String?) {
        providerFilter = provider
    }

    // MARK: - Loading

    func load(forceRefresh: Bool = false) async {
        guard let service, let session else {
            phase = .failed(ActionFailure.notWired.message)
            return
        }
        phase = .loading
        do {
            let catalogue = try await service.listModels(
                for: session, forceRefresh: forceRefresh)
            // Drop a filter the new catalogue cannot honour, rather than
            // rendering an empty list with a chip selected.
            if let providerFilter,
               !catalogue.models.contains(where: { $0.provider == providerFilter }) {
                self.providerFilter = nil
            }
            phase = .loaded(catalogue)
            quickActions?.adopt(catalogue)
        } catch let failure as ActionFailure {
            phase = .failed(failure.message)
        } catch {
            // The Dart picker's generic fallback string (`:104-106`). Kept
            // verbatim so a support conversation matches across clients.
            phase = .failed("Failed to load models")
        }
    }

    /// Tapping a row. Returns `true` when the sub-sheet should pop.
    ///
    /// The dispatch goes through the **parent** model so the optimistic
    /// highlight, the busy spinner and the error toast all live in one place
    /// (§8.12: "failure is toasted by the parent sheet's listener").
    @discardableResult
    func pick(_ model: WireModel) async -> Bool {
        guard let quickActions, pickingModelID == nil else { return false }
        pickingModelID = model.id
        defer { pickingModelID = nil }
        return await quickActions.setModel(model)
    }
}

// MARK: - Row identity

extension WireModel {
    /// `provider/id` — the pair that identifies a model (§8.12).
    ///
    /// `id` alone is not unique: two providers routinely expose the same model
    /// id, and a `ForEach` keyed on it would collapse them into one row (and
    /// then animate the survivor into the wrong slot when the filter changes).
    var pickerRowID: String { "\(provider)/\(id)" }
}
