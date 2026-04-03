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
                        .fill(step <= currentStep ? Color.accent : .gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            TabView(selection: $currentStep) {
                WelcomeStepView { currentStep = 1 }
                    .tag(0)

                CurrencyStepView { currentStep = 2 }
                    .tag(1)

                AccountStepView { currentStep = 3 }
                    .tag(2)

                FeaturesStepView { currentStep = 4 }
                    .tag(3)

                NotificationsStepView { currentStep = 5 }
                    .tag(4)

                CompletionStepView {
                    UserDefaults.standard.set(true, forKey: "onboarding_completed")
                    appViewModel.hasCompletedOnboarding = true
                }
                    .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentStep)
        }
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 80))
                .foregroundStyle(Color.accent.gradient)

            Text(String(localized: "onboarding.welcome.title"))
                .font(.title.bold())
                .multilineTextAlignment(.center)

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

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accent.gradient)

            Text(String(localized: "onboarding.currency.title"))
                .font(.title2.bold())

            Text(String(localized: "onboarding.currency.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                ForEach(CurrencyCode.allCases, id: \.self) { currency in
                    Button {
                        appViewModel.currencyManager.selectedCurrency = currency
                        appViewModel.currencyManager.dataCurrency = currency
                    } label: {
                        HStack {
                            Text(currency.symbol)
                                .font(.title2)
                                .frame(width: 36)
                            Text(currency.name)
                                .font(.subheadline)
                            Spacer()
                            if appViewModel.currencyManager.selectedCurrency == currency {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            OnboardingButton(title: String(localized: "common.next"), action: onNext)
        }
    }
}

// MARK: - Step 3: First Account

struct AccountStepView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let onNext: () -> Void

    @State private var accountName = ""
    @State private var selectedIcon = "💳"
    @State private var isCreating = false

    private let icons = ["💳", "🏦", "💰", "👛", "💵", "🪙"]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "creditcard.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accent.gradient)

            Text(String(localized: "onboarding.account.title"))
                .font(.title2.bold())

            VStack(spacing: 16) {
                TextField(String(localized: "onboarding.account.namePlaceholder"), text: $accountName)
                    .padding()
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    ForEach(icons, id: \.self) { icon in
                        Text(icon)
                            .font(.title)
                            .frame(width: 48, height: 48)
                            .background(selectedIcon == icon ? Color.accent.opacity(0.2) : .clear)
                            .clipShape(Circle())
                            .overlay { Circle().stroke(selectedIcon == icon ? Color.accent : .clear, lineWidth: 2) }
                            .onTapGesture { selectedIcon = icon }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                OnboardingButton(title: accountName.isEmpty ? String(localized: "common.skip") : String(localized: "onboarding.account.createAndContinue")) {
                    if !accountName.isEmpty {
                        isCreating = true
                        let repo = AccountRepository()
                        _ = try? await repo.create(name: accountName, icon: selectedIcon, color: "#4ADE80", initialBalance: 0)
                        await appViewModel.dataStore.loadAll()
                    }
                    onNext()
                }

                if !accountName.isEmpty {
                    Button(String(localized: "common.skip")) { onNext() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "arrow.left.arrow.right", color: .blue, title: String(localized: "onboarding.features.transactions"), subtitle: String(localized: "onboarding.features.transactions.subtitle"))
                FeatureRow(icon: "chart.bar.fill", color: .purple, title: String(localized: "onboarding.features.analytics"), subtitle: String(localized: "onboarding.features.analytics.subtitle"))
                FeatureRow(icon: "wallet.bifold.fill", color: .orange, title: String(localized: "onboarding.features.budgets"), subtitle: String(localized: "onboarding.features.budgets.subtitle"))
                FeatureRow(icon: "target", color: Color.accent, title: String(localized: "onboarding.features.savings"), subtitle: String(localized: "onboarding.features.savings.subtitle"))
                FeatureRow(icon: "sparkles", color: .yellow, title: String(localized: "onboarding.features.aiAssistant"), subtitle: String(localized: "onboarding.features.aiAssistant.subtitle"))
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
                .background(color.opacity(0.12))
                .clipShape(Circle())

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

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accent.gradient)

            Text(String(localized: "onboarding.notifications.title"))
                .font(.title2.bold())

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
                    .foregroundStyle(.secondary)
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

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.accent.gradient)

            Text(String(localized: "onboarding.completion.title"))
                .font(.title.bold())

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

    var body: some View {
        Button {
            isLoading = true
            Task {
                await action()
                isLoading = false
            }
        } label: {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .background(Color.accent.gradient)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
        .padding(.bottom, 56)
        .disabled(isLoading)
    }
}
