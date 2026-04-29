import SwiftUI

/// Sets target weights per HoldingKind so `RebalanceHintView` has
/// something to compare current allocation against. Persisted in
/// UserDefaults via `PortfolioViewModel.targetAllocation` so the
/// setting survives across launches.
///
/// UX rules:
/// * Show every kind that the user actually owns first, then the
///   remaining kinds underneath (so the picker doesn't dump 7 zero-
///   weighted rows in their face on day 1).
/// * Sum is shown live; "Save" is disabled unless the sum is in
///   [0.99, 1.01]. Mirrors how target-allocation tools elsewhere
///   handle floating-point drift.
/// * Reset button restores all weights to 0.
struct TargetAllocationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PortfolioViewModel

    @State private var weights: [HoldingKind: Double] = [:]

    private var sum: Double {
        weights.values.reduce(0, +)
    }

    private var isValid: Bool {
        sum > 0.99 && sum < 1.01
    }

    private var orderedKinds: [HoldingKind] {
        let owned = Set(viewModel.holdings.map(\.kind))
        let ownedOrdered = HoldingKind.allCases.filter { owned.contains($0) }
        let unowned = HoldingKind.allCases.filter { !owned.contains($0) }
        return ownedOrdered + unowned
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "rebalance.target.sum"))
                        Spacer()
                        Text(percentString(sum))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(isValid ? .green : .red)
                    }
                } footer: {
                    Text(String(localized: "rebalance.target.footer"))
                }

                Section(String(localized: "rebalance.target.section")) {
                    ForEach(orderedKinds, id: \.self) { kind in
                        kindRow(kind)
                    }
                }
            }
            .navigationTitle(String(localized: "rebalance.target.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.save")) {
                        viewModel.targetAllocation = weights.reduce(into: [:]) { acc, pair in
                            acc[pair.key] = Decimal(pair.value)
                        }
                        dismiss()
                    }
                    .disabled(!isValid)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        for k in HoldingKind.allCases { weights[k] = 0 }
                    } label: {
                        Label(String(localized: "rebalance.target.reset"),
                              systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .onAppear { prefill() }
        }
    }

    @ViewBuilder
    private func kindRow(_ kind: HoldingKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(hex: kind.defaultHex))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(kind.localizedTitle)
                    .font(.subheadline)
                Spacer()
                Text(percentString(weights[kind] ?? 0))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { weights[kind] ?? 0 },
                    set: { weights[kind] = ($0 * 100).rounded() / 100 }
                ),
                in: 0...1,
                step: 0.05
            )
        }
        .padding(.vertical, 2)
    }

    private func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func prefill() {
        if let stored = viewModel.targetAllocation {
            for (kind, w) in stored {
                weights[kind] = NSDecimalNumber(decimal: w).doubleValue
            }
        } else {
            for k in HoldingKind.allCases { weights[k] = 0 }
        }
    }
}
