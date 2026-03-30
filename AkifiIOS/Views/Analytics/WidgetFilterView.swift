import SwiftUI

enum WidgetPeriod: String, CaseIterable, Sendable {
    case day, week, month, threeMonths, year

    var label: String {
        switch self {
        case .day: String(localized: "period.today")
        case .week: String(localized: "period.week")
        case .month: String(localized: "period.month")
        case .threeMonths: String(localized: "period.threeMonths")
        case .year: String(localized: "period.year")
        }
    }

    var dateOffset: DateComponents {
        switch self {
        case .day: return DateComponents(day: -1)
        case .week: return DateComponents(day: -7)
        case .month: return DateComponents(month: -1)
        case .threeMonths: return DateComponents(month: -3)
        case .year: return DateComponents(year: -1)
        }
    }

    func startDate(from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: dateOffset, to: now)!
    }
}

struct WidgetFilterView: View {
    @Binding var selectedPeriod: WidgetPeriod

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WidgetPeriod.allCases, id: \.self) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        Text(period.label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectedPeriod == period
                                    ? Color.accent.opacity(0.15)
                                    : Color(.systemGray6)
                            )
                            .foregroundStyle(selectedPeriod == period ? Color.accent : .primary.opacity(0.6))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(
                                        selectedPeriod == period ? Color.accent.opacity(0.3) : Color(.systemGray4),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
