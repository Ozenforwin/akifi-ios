import SwiftUI
import Charts

/// Standalone compound-interest calculator. Independent of the user's
/// own data — pure "what-if" tool that takes principal, monthly
/// contribution, annual return and a horizon and draws the future-
/// value curve via `CompoundProjector`.
///
/// Defaults match the FIRE-textbook example so a first-time user sees
/// a useful curve out of the box: 100k principal, 10k/mo, 7% nominal,
/// 20 years (≈ $5.6M end value).
struct CompoundCalculatorView: View {
    @Environment(AppViewModel.self) private var appViewModel
    private var cm: CurrencyManager { appViewModel.currencyManager }

    @State private var principalText: String = "100000"
    @State private var monthlyText: String = "10000"
    @State private var annualRatePercentText: String = "7"
    @State private var years: Double = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputsCard
                summaryCard
                chartCard
                contributionsCard
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .navigationTitle(String(localized: "compound.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Inputs

    @ViewBuilder
    private var inputsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputRow(
                title: String(localized: "compound.input.principal"),
                placeholder: "100000",
                text: $principalText,
                trailing: cm.dataCurrency.symbol
            )
            inputRow(
                title: String(localized: "compound.input.monthly"),
                placeholder: "10000",
                text: $monthlyText,
                trailing: cm.dataCurrency.symbol
            )
            inputRow(
                title: String(localized: "compound.input.annualRate"),
                placeholder: "7",
                text: $annualRatePercentText,
                trailing: "%"
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "compound.input.years"))
                    Spacer()
                    Text(String(format: String(localized: "compound.years.format"), Int(years)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.accent)
                }
                Slider(value: $years, in: 1...40, step: 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func inputRow(title: String, placeholder: String,
                          text: Binding<String>, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text(trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
        }
    }

    // MARK: - Summary

    private var result: CompoundProjector.Result {
        CompoundProjector.project(
            principal: parseKopecks(principalText),
            monthlyContribution: parseKopecks(monthlyText),
            annualReturn: parseDecimal(annualRatePercentText) / 100,
            years: Int(years)
        )
    }

    @ViewBuilder
    private var summaryCard: some View {
        let r = result
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "compound.summary.title"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(cm.formatAmount(r.finalValue.displayAmount))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
            Text(String(format: String(localized: "compound.summary.afterFormat"),
                        Int(years)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accent.opacity(0.08), Color.accent.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartCard: some View {
        let r = result
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "compound.chart.title"))
                .font(.headline)
            Chart(r.points) { point in
                AreaMark(
                    x: .value("year", point.year),
                    y: .value("value", Double(point.value) / 100.0)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accent.opacity(0.30), Color.accent.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("year", point.year),
                    y: .value("value", Double(point.value) / 100.0)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accent)
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel().font(.caption2)
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Contributions vs growth

    @ViewBuilder
    private var contributionsCard: some View {
        let r = result
        VStack(alignment: .leading, spacing: 6) {
            row(label: String(localized: "compound.contributions"),
                value: r.totalContributions)
            Divider()
            row(label: String(localized: "compound.interest"),
                value: r.totalInterest, accent: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func row(label: String, value: Int64, accent: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(cm.formatAmount(value.displayAmount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent ? Color(hex: "#16A34A") : .primary)
        }
    }

    // MARK: - Parsing

    private func parseKopecks(_ text: String) -> Int64 {
        let value = parseDecimal(text)
        var product = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    private func parseDecimal(_ text: String) -> Decimal {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }
}
