import SwiftUI

struct OnboardingView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<6) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accent : Color(.systemFill))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .accessibilityHidden(true)

            TabView(selection: $currentStep) {
                // Each step scrolls when large Dynamic Type makes it taller
                // than the screen.
                WelcomeStepView { currentStep = 1 }
                    .fitsOrScrolls()
                    .tag(0)

                CurrencyStepView { currentStep = 2 }
                    .fitsOrScrolls()
                    .tag(1)

                AccountStepView { currentStep = 3 }
                    .fitsOrScrolls()
                    .tag(2)

                FeaturesStepView { currentStep = 4 }
                    .fitsOrScrolls()
                    .tag(3)

                NotificationsStepView { currentStep = 5 }
                    .fitsOrScrolls()
                    .tag(4)

                CompletionStepView {
                    UserDefaults.standard.set(true, forKey: "onboarding_completed")
                    appViewModel.hasCompletedOnboarding = true
                }
                    .fitsOrScrolls()
                    .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentStep)
        }
        // Rows and fields are content cards on the grouped background (1.6).
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // No tab view above sets the app tint yet.
        .tint(Color.accent)
    }
}

/// The large symbol on top of each onboarding step: one accent colour, no
/// gradient, sized with Dynamic Type.
private struct OnboardingSymbol: View {
    let systemName: String
    @ScaledMetric private var size: CGFloat

    init(_ systemName: String, size: CGFloat = 64) {
        self.systemName = systemName
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(Color.accent)
            .accessibilityHidden(true)
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            OnboardingSymbol("sparkles", size: 80)

            Text(String(localized: "onboarding.welcome.title"))
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "onboarding.welcome.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            OnboardingButton(title: String(localized: "onboarding.welcome.start"), action: onNext)
        }
    }
}

// MARK: - Step 2: Currency

struct CurrencyStepView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let onNext: () -> Void
    @State private var showCurrencyPicker = false
    /// Mirror of `selectedCurrency` so the picker can write through a
    /// `Binding<Currency>`. Synced via `.onAppear` and `.onChange`.
    @State private var pickerSelection: Currency = .rub

    /// Top-of-list shortcut buttons: keeps the high-friendly tactile UX
    /// from the original 9-button onboarding while letting users pick
    /// any of the 150+ ISO codes via the "More" sheet.
    private let onboardingHotList: [Currency] = [
        .usd, .eur, .rub
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            OnboardingSymbol("dollarsign.circle.fill")

            Text(String(localized: "onboarding.currency.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "onboarding.currency.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                ForEach(onboardingHotList) { currency in
                    Button {
                        select(currency)
                    } label: {
                        HStack {
                            Text(currency.symbol)
                                .font(.title2)
                                .frame(width: 36)
                            Text(currency.localizedName)
                                .font(.subheadline)
                            Spacer()
                            if appViewModel.currencyManager.selectedCurrency == currency {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .akifiCard(.compact, padding: 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(appViewModel.currencyManager.selectedCurrency == currency ? .isSelected : [])
                }

                Button {
                    pickerSelection = appViewModel.currencyManager.selectedCurrency
                    showCurrencyPicker = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        Text(String(localized: "currencyPicker.title"))
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .akifiCard(.compact, padding: 0)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer()

            OnboardingButton(title: String(localized: "common.next"), action: onNext)
        }
        .sheet(isPresented: $showCurrencyPicker, onDismiss: {
            select(pickerSelection)
        }) {
            CurrencyPickerView(selection: $pickerSelection)
        }
    }

    private func select(_ currency: Currency) {
        appViewModel.currencyManager.selectedCurrency = currency
        appViewModel.currencyManager.dataCurrency = currency
    }
}

// MARK: - Step 3: First Account

struct AccountStepView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let onNext: () -> Void

    @State private var accountName = ""
    @State private var selectedIcon = "💳"
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let icons = ["💳", "🏦", "💰", "👛", "💵", "🪙"]

    /// `accounts.currency` for the first account: the currency picked on the
    /// currency step (stored as the data currency), lowercase like every
    /// other account write.
    static func firstAccountCurrency(_ chosen: Currency) -> String {
        chosen.code.lowercased()
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            OnboardingSymbol("creditcard.fill")

            Text(String(localized: "onboarding.account.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 16) {
                TextField(String(localized: "onboarding.account.namePlaceholder"), text: $accountName)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 12) {
                    ForEach(icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                        } label: {
                            Text(icon)
                                .font(.title)
                                .frame(width: 48, height: 48)
                                .background(selectedIcon == icon ? Color.accent.opacity(0.2) : .clear, in: Circle())
                                .overlay { Circle().strokeBorder(selectedIcon == icon ? Color.accent : .clear, lineWidth: 2) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: icon))
                        .accessibilityAddTraits(selectedIcon == icon ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                OnboardingButton(title: accountName.isEmpty ? String(localized: "common.skip") : String(localized: "onboarding.account.createAndContinue")) {
                    if !accountName.isEmpty {
                        isCreating = true
                        errorMessage = nil
                        defer { isCreating = false }
                        do {
                            // M3: in the currency chosen on the previous
                            // step — it used to default to roubles, so «50»
                            // on a USD user's first account was 50 ₽.
                            _ = try await AccountRepository().create(
                                name: accountName,
                                icon: selectedIcon,
                                color: "#4ADE80",
                                initialBalance: 0,
                                currency: Self.firstAccountCurrency(appViewModel.currencyManager.dataCurrency)
                            )
                        } catch {
                            // Stay on this step: a silent `try?` left the
                            // user with no account and no idea why.
                            errorMessage = FormErrorMessage.text(for: error)
                            return
                        }
                        await appViewModel.dataStore.loadAll()
                    }
                    onNext()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if !accountName.isEmpty {
                    Button(String(localized: "common.skip")) { onNext() }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
        }
    }
}

// MARK: - Step 4: Features Overview

struct FeaturesStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(String(localized: "onboarding.features.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            // One accent colour for the feature symbols (1.6: colour is for
            // meaning, not decoration).
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "arrow.left.arrow.right", color: Color.accent, title: String(localized: "onboarding.features.transactions"), subtitle: String(localized: "onboarding.features.transactions.subtitle"))
                FeatureRow(icon: "chart.bar.fill", color: Color.accent, title: String(localized: "onboarding.features.analytics"), subtitle: String(localized: "onboarding.features.analytics.subtitle"))
                FeatureRow(icon: "wallet.bifold.fill", color: Color.accent, title: String(localized: "onboarding.features.budgets"), subtitle: String(localized: "onboarding.features.budgets.subtitle"))
                FeatureRow(icon: "target", color: Color.accent, title: String(localized: "onboarding.features.savings"), subtitle: String(localized: "onboarding.features.savings.subtitle"))
                FeatureRow(icon: "sparkles", color: Color.accent, title: String(localized: "onboarding.features.aiAssistant"), subtitle: String(localized: "onboarding.features.aiAssistant.subtitle"))
            }
            .padding(.horizontal, 24)

            Spacer()

            OnboardingButton(title: String(localized: "common.next"), action: onNext)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 5: Notifications

struct NotificationsStepView: View {
    let onNext: () -> Void

    @State private var notificationManager = NotificationManager()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            OnboardingSymbol("bell.badge.fill")

            Text(String(localized: "onboarding.notifications.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "onboarding.notifications.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                NotificationFeatureRow(icon: "wallet.bifold", text: String(localized: "onboarding.notifications.budgetWarnings"))
                NotificationFeatureRow(icon: "exclamationmark.triangle", text: String(localized: "onboarding.notifications.largeExpenses"))
                NotificationFeatureRow(icon: "target", text: String(localized: "onboarding.notifications.goalReached"))
                NotificationFeatureRow(icon: "flame", text: String(localized: "onboarding.notifications.streakSupport"))
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                OnboardingButton(title: String(localized: "onboarding.notifications.enable")) {
                    await notificationManager.requestAuthorization()
                    onNext()
                }

                Button(String(localized: "common.skip")) { onNext() }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        }
    }
}

struct NotificationFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Step 6: Completion

struct CompletionStepView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            OnboardingSymbol("checkmark.circle.fill", size: 80)

            Text(String(localized: "onboarding.completion.title"))
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "onboarding.completion.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            OnboardingButton(title: String(localized: "onboarding.completion.goToApp"), action: onFinish)
        }
    }
}

// MARK: - Shared Button

struct OnboardingButton: View {
    let title: String
    let action: () async -> Void

    @State private var isLoading = false

    init(title: String, action: @escaping () async -> Void) {
        self.title = title
        self.action = action
    }

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = { action() }
    }

    /// The step's primary call to action: system `.akifiPrimary`, full width.
    var body: some View {
        Button {
            isLoading = true
            Task {
                await action()
                isLoading = false
            }
        } label: {
            ZStack {
                Text(title)
                    .font(.headline)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.akifiPrimary)
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .disabled(isLoading)
    }
}
