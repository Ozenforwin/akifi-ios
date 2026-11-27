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

/// Period of the cashflow chart and the category breakdown — the system
/// segmented control (Liquid Glass on iOS 26), replacing the hand-made
/// capsule chips.
struct WidgetFilterView: View {
    @Binding var selectedPeriod: WidgetPeriod

    var body: some View {
        Picker(String(localized: "common.period"), selection: $selectedPeriod) {
            ForEach(WidgetPeriod.allCases, id: \.self) { period in
                Text(period.label).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
