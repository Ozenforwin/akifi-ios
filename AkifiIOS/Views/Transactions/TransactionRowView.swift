import SwiftUI

struct TransactionRowView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transaction: Transaction
    let category: Category?
    var account: Account?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isTransfer: Bool { transaction.type == .transfer || transaction.transferGroupId != nil }
    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        HStack(spacing: 12) {
            // Category icon with creator badge
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(iconEmoji)
                            .font(.title3)
                    }

                // Creator avatar badge (for shared accounts)
                if let creator = appViewModel.dataStore.profilesMap[transaction.userId],
                   creator.id != appViewModel.dataStore.profile?.id {
                    creatorBadge(creator)
                        .offset(x: 4, y: 4)
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: Category name + amount
                HStack(alignment: .firstTextBaseline) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    Text(formattedAmount)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(amountColor)
                        .monospacedDigit()
                }

                // Row 2: Date + account badge
                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let acc = resolvedAccount {
                        accountBadge(acc)
                    }
                }

                // Row 3: Description or transfer label
                if isTransfer {
                    Text(transaction.description?.isEmpty == false ? transaction.description! : "Перевод между счетами")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let desc = transaction.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: - Computed

    private var iconEmoji: String {
        isTransfer ? "↔️" : (category?.icon ?? "📦")
    }

    private var iconBackground: Color {
        if isTransfer {
            return Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.08)
        }
        return Color(hex: category?.color ?? "#888888").opacity(0.08)
    }

    private var titleText: String {
        isTransfer ? "Перевод" : (category?.name ?? "Без категории")
    }

    private var resolvedAccount: Account? {
        if let account { return account }
        guard let accId = transaction.accountId else { return nil }
        return dataStore.accounts.first { $0.id == accId }
    }

    private var amountColor: Color {
        if isTransfer {
            return Color(red: 0.23, green: 0.51, blue: 0.96)
        }
        switch transaction.type {
        case .income: return Color.income
        case .expense: return Color.expense
        case .transfer: return Color(red: 0.23, green: 0.51, blue: 0.96)
        }
    }

    private var formattedAmount: String {
        if isTransfer {
            let sign = transaction.type == .expense ? "-" : "+"
            return "\(sign)\(appViewModel.currencyManager.formatAmount(transaction.amount.displayAmount))"
        }
        let sign: String
        switch transaction.type {
        case .income: sign = "+"
        case .expense: sign = "-"
        case .transfer: sign = ""
        }
        return "\(sign)\(appViewModel.currencyManager.formatAmount(transaction.amount.displayAmount))"
    }

    private var formattedDate: String {
        // "26 мар. 2026, 15:43" style
        let dateStr = transaction.date // "2026-03-26"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "ru_RU")
        guard let date = df.date(from: dateStr) else { return dateStr }
        let outDf = DateFormatter()
        outDf.locale = Locale(identifier: "ru_RU")
        outDf.dateFormat = "d MMM yyyy"
        return outDf.string(from: date)
    }

    // MARK: - Subviews

    private func creatorBadge(_ creator: Profile) -> some View {
        ZStack {
            if let avatarUrl = creator.avatarUrl, let url = URL(string: avatarUrl) {
                CachedAsyncImage(url: url) {
                    initialsCircle(creator)
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            } else {
                initialsCircle(creator)
            }
        }
    }

    private func initialsCircle(_ creator: Profile) -> some View {
        Circle()
            .fill(Color(.systemGray4))
            .frame(width: 18, height: 18)
            .overlay {
                Text(String((creator.fullName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
    }

    private func accountBadge(_ acc: Account) -> some View {
        HStack(spacing: 3) {
            Text(acc.icon)
                .font(.system(size: 10))
            Text(acc.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
