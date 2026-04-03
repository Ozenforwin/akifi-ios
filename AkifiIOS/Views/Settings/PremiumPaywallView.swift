import SwiftUI

struct PremiumPaywallView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    private var isPremium: Bool { appViewModel.paymentManager.isPremium }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.yellow.gradient)

                    Text("Akifi Pro")
                        .font(.title.bold())

                    if isPremium {
                        Label("Активно", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.accent.opacity(0.15))
                            .clipShape(Capsule())
                    } else {
                        Text("Разблокируйте все возможности")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 20)

                // Features
                VStack(spacing: 0) {
                    PremiumFeatureRow(icon: "sparkles", title: "AI-ассистент", subtitle: "Персональные финансовые советы", isPro: true)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "chart.line.uptrend.xyaxis", title: "Расширенная аналитика", subtitle: "Детальные отчёты и прогнозы", isPro: true)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "doc.text", title: "Экспорт в CSV", subtitle: "Выгрузка всех операций", isPro: true)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "bell.badge", title: "Умные уведомления", subtitle: "Аномалии, тренды, напоминания", isPro: true)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "camera.viewfinder", title: "Сканер чеков", subtitle: "Автоматический ввод расходов", isPro: true)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "person.2", title: "Совместные счета", subtitle: "Управляйте финансами вместе", isPro: false)
                    Divider().padding(.leading, 52)
                    PremiumFeatureRow(icon: "target", title: "Цели накоплений", subtitle: "Копите с процентами", isPro: false)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                if !isPremium {
                    // Purchase buttons
                    VStack(spacing: 12) {
                        Button {
                            // StoreKit 2 purchase will be here in v2
                        } label: {
                            VStack(spacing: 4) {
                                Text("Pro — Ежемесячно")
                                    .font(.headline)
                                Text("Скоро")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accent.gradient)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(true)
                        .opacity(0.6)

                        Button {
                            // Restore
                        } label: {
                            Text("Восстановить покупки")
                                .font(.subheadline)
                                .foregroundStyle(Color.accent)
                        }
                    }

                    Text("Покупки в приложении появятся в следующем обновлении")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Premium")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PremiumFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isPro: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isPro ? .yellow : Color.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    if isPro {
                        Text("PRO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.yellow.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
