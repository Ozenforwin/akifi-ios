import SwiftUI

/// Collected entry point for features that haven't graduated to the
/// main app surfaces yet. Grouping them here keeps the primary Settings
/// screen calm and makes the BETA state explicit — user sees the badge
/// as they enter AND on each row.
///
/// Graduation criteria (informal): a feature leaves this screen when
/// (a) it has a dedicated Tab or Home shortcut, (b) its visual polish
/// matches the shipped surfaces, (c) there are zero known data bugs.
struct BetaFeaturesView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "flask.fill")
                            .foregroundStyle(.orange)
                        Text(String(localized: "settings.beta.introTitle"))
                            .font(.headline)
                    }
                    Text(String(localized: "settings.beta.introBody"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            Section(header: Text(String(localized: "settings.beta.section.netWorth"))) {
                NavigationLink {
                    NetWorthDashboardView()
                } label: {
                    SettingsRow(
                        icon: "chart.line.uptrend.xyaxis",
                        color: .green,
                        title: String(localized: "netWorth.title"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    NetWorthAssetsBetaEntry()
                } label: {
                    SettingsRow(
                        icon: "building.2.fill",
                        color: .green,
                        title: String(localized: "netWorth.assets.title"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    NetWorthLiabilitiesBetaEntry()
                } label: {
                    SettingsRow(
                        icon: "creditcard.fill",
                        color: .red,
                        title: String(localized: "netWorth.liabilities.title"),
                        badge: "BETA"
                    )
                }
            }

            Section(header: Text(String(localized: "settings.beta.section.investing"))) {
                NavigationLink {
                    PortfolioDashboardView()
                } label: {
                    SettingsRow(
                        icon: "chart.pie.fill",
                        color: .accent,
                        title: String(localized: "portfolio.title"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    FIREProjectionView()
                } label: {
                    SettingsRow(
                        icon: "flag.checkered",
                        color: .accent,
                        title: String(localized: "fire.title"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    CompoundCalculatorView()
                } label: {
                    SettingsRow(
                        icon: "function",
                        color: .accent,
                        title: String(localized: "compound.title"),
                        badge: "BETA"
                    )
                }
            }

            Section(header: Text(String(localized: "settings.beta.section.planning"))) {
                NavigationLink {
                    SavingsGoalListView()
                } label: {
                    SettingsRow(
                        icon: "target",
                        color: .green,
                        title: String(localized: "home.savings"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    DepositListView()
                } label: {
                    SettingsRow(
                        icon: "percent",
                        color: .purple,
                        title: String(localized: "deposit.title"),
                        badge: "BETA"
                    )
                }

                NavigationLink {
                    ChallengesListView()
                } label: {
                    SettingsRow(
                        icon: "flag.checkered",
                        color: .orange,
                        title: String(localized: "challenges.title"),
                        badge: "BETA"
                    )
                }
            }

            Section(header: Text(String(localized: "settings.beta.section.insights"))) {
                NavigationLink {
                    ReportsView()
                } label: {
                    SettingsRow(
                        icon: "doc.text.fill",
                        color: .purple,
                        title: String(localized: "reports.title"),
                        badge: "BETA"
                    )
                }
            }
        }
        .navigationTitle(String(localized: "settings.beta.title"))
    }
}

/// Same wrappers that Settings used — duplicated here so the beta
/// collection doesn't depend on symbols in `SettingsView.swift`.
private struct NetWorthAssetsBetaEntry: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = NetWorthViewModel()

    var body: some View {
        AssetListView(viewModel: viewModel)
            .task {
                await viewModel.load(
                    dataStore: appViewModel.dataStore,
                    currencyManager: appViewModel.currencyManager
                )
            }
    }
}

private struct NetWorthLiabilitiesBetaEntry: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = NetWorthViewModel()

    var body: some View {
        LiabilityListView(viewModel: viewModel)
            .task {
                await viewModel.load(
                    dataStore: appViewModel.dataStore,
                    currencyManager: appViewModel.currencyManager
                )
            }
    }
}
