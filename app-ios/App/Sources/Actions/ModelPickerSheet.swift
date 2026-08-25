import RemotePiProtocol
import SwiftUI

/// Model picker sub-sheet (spec 08 §8.12), pushed from the Quick Actions
/// Model row.
///
/// It shares the parent's ``QuickActionsModel`` by reference so a successful
/// pick updates the row underneath and a failure surfaces in the parent's
/// inline error — this sheet is gone by the time either matters.
struct ModelPickerSheet: View {
    let session: SessionKey
    let quickActions: QuickActionsModel

    @Environment(AppModel.self) private var app
    @Environment(SessionSelection.self) private var selection
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model = ModelPickerModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
            content(for: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.colors.bg)
        .presentationBackground(theme.colors.bg)
        .presentationCornerRadius(AppMetrics.radiusSheetSmall)
        // §8.12 caps the sheet at 78% of the screen. `.fraction(0.78)` is the
        // native equivalent; `.large` is offered as well so a long catalogue
        // can be dragged up rather than scrolled inside a short window.
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
        .dismissOnSessionChange(selection)
        .task {
            model.bind(
                to: AppModelSessionActions(app: app),
                session: session,
                quickActions: quickActions
            )
            await model.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Choose a model")
                .font(theme.type.mono(13, weight: .medium))
                .foregroundStyle(theme.colors.text)

            Spacer(minLength: 0)

            Button {
                Task { await model.load(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Body states

    @ViewBuilder
    private func content(for phase: ModelPickerModel.Phase) -> some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.regular)
                .tint(theme.colors.accent)
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Could not load models",
                message: message
            ) {
                SecondaryButton(title: "Retry") {
                    Task { await model.load(forceRefresh: true) }
                }
                .frame(maxWidth: 200)
            }
            .frame(maxWidth: .infinity)
        case .loaded(let catalogue) where catalogue.models.isEmpty:
            // A successful answer with nothing in it. No Retry button: there
            // is nothing to retry, the Pi simply has no models configured.
            EmptyStateView(
                systemImage: "square.stack.3d.up.slash",
                title: "No models available",
                message: "The Pi did not report any models for this session."
            )
            .frame(maxWidth: .infinity)
        case .loaded:
            loadedBody
        }
    }

    private var loadedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsProviderChips { providerChips }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredModels, id: \.pickerRowID) { entry in
                        modelRow(entry)
                        Rectangle()
                            .fill(theme.colors.border)
                            .frame(height: AppMetrics.hairline)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private var providerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "all", isSelected: model.providerFilter == nil) {
                    model.selectProvider(nil)
                }
                ForEach(model.providers, id: \.self) { provider in
                    chip(label: provider, isSelected: model.providerFilter == provider) {
                        model.selectProvider(provider)
                    }
                }
            }
            .padding(.horizontal, AppMetrics.sheetGutter)
            .padding(.vertical, 10)
        }
    }

    private func chip(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.type.mono(11))
                .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? theme.colors.accent.opacity(0.12) : theme.colors.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isSelected ? theme.colors.accent : theme.colors.border,
                            lineWidth: AppMetrics.hairline
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func modelRow(_ entry: WireModel) -> some View {
        let isCurrent = model.isCurrent(entry)
        return Button {
            Task {
                // Pop only on success — a failure keeps the list up so the
                // user can pick something else, and the message appears on
                // the parent sheet underneath.
                if await model.pick(entry) { dismiss() }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(theme.type.mono(13))
                            .foregroundStyle(isCurrent ? theme.colors.accent : theme.colors.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if entry.reasoning { reasoningBadge }
                    }
                    Text(model.subtitle(for: entry))
                        .font(theme.type.mono(10))
                        .foregroundStyle(theme.colors.muted)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.pickingModelID != nil)
        .opacity(model.pickingModelID == nil || model.pickingModelID == entry.id ? 1 : 0.5)
        .accessibilityLabel("\(entry.name), \(model.subtitle(for: entry))")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var reasoningBadge: some View {
        Text("reasoning")
            .font(theme.type.mono(9))
            .foregroundStyle(theme.colors.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.colors.accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
