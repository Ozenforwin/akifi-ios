import SwiftUI

struct EvidenceCardView: View {
    let evidence: AnomalyEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with type emoji and label
            HStack(spacing: 6) {
                Text(evidence.type.emoji)
                    .font(.subheadline)
                Text(evidence.label)
                    .font(.caption.weight(.semibold))
                Spacer()
                deltaPercentBadge
            }

            // Values comparison
            HStack(spacing: 16) {
                valueColumn(label: String(localized: "evidence.current"), value: evidence.currentValue)
                valueColumn(label: String(localized: "evidence.usual"), value: evidence.baselineValue)
            }

            // Delta bar
            deltaBar

            // Heatmap for frequency spike
            if evidence.type == .frequencySpike, let heatmap = evidence.heatmap, !heatmap.isEmpty {
                heatmapView(heatmap)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var deltaPercentBadge: some View {
        let isPositive = evidence.deltaPercent > 0
        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text("\(abs(Int(evidence.deltaPercent)))%")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(isPositive ? .red : .green)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((isPositive ? Color.red : Color.green).opacity(0.12))
        .clipShape(Capsule())
    }

    private func valueColumn(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(formatAmount(value))
                .font(.caption.weight(.medium).monospacedDigit())
        }
    }

    private var deltaBar: some View {
        let ratio = min(evidence.currentValue / max(evidence.baselineValue, 1), 3.0)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background (baseline)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray4))
                    .frame(height: 6)

                // Current value
                RoundedRectangle(cornerRadius: 3)
                    .fill(ratio > 1.5 ? Color.red : ratio > 1.0 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * min(ratio / 3.0, 1.0), height: 6)

                // Baseline marker
                let baselineX = geometry.size.width / 3.0
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 1.5, height: 10)
                    .offset(x: baselineX)
            }
        }
        .frame(height: 10)
    }

    private func heatmapView(_ heatmap: [HeatmapEntry]) -> some View {
        let days = [String(localized: "day.mon"), String(localized: "day.tue"), String(localized: "day.wed"), String(localized: "day.thu"), String(localized: "day.fri"), String(localized: "day.sat"), String(localized: "day.sun")]
        let maxCount = heatmap.map(\.count).max() ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "evidence.frequencyByDay"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { dayIndex in
                    let count = heatmap.first(where: { $0.day == dayIndex })?.count ?? 0
                    let intensity = maxCount > 0 ? Double(count) / Double(maxCount) : 0

                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.opacity(0.1 + intensity * 0.7))
                            .frame(height: 20)
                        Text(days[dayIndex])
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formatAmount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = " "
        return (formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))") + " ₽"
    }
}

// MARK: - Evidence List

struct EvidenceListView: View {
    let evidence: [AnomalyEvidence]
    let confidence: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Confidence badge
            if let confidence {
                confidenceBadge(confidence)
            }

            ForEach(evidence) { item in
                EvidenceCardView(evidence: item)
            }
        }
    }

    private func confidenceBadge(_ value: Double) -> some View {
        let label: String
        let color: Color
        if value >= 0.8 {
            label = String(localized: "evidence.highConfidence")
            color = .green
        } else if value >= 0.5 {
            label = String(localized: "evidence.mediumConfidence")
            color = .orange
        } else {
            label = String(localized: "evidence.lowConfidence")
            color = .red
        }

        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
    }
}
