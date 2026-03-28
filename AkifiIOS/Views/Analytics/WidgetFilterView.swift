import SwiftUI

enum WidgetPeriod: String, CaseIterable, Sendable {
    case day = "День"
    case week = "Неделя"
    case month = "Месяц"
    case threeMonths = "3 мес."
    case year = "Год"

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
                        Text(period.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectedPeriod == period
                                    ? AnyShapeStyle(Color.accent.opacity(0.2))
                                    : AnyShapeStyle(Color(.tertiarySystemBackground))
                            )
                            .foregroundStyle(selectedPeriod == period ? Color.accent : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
