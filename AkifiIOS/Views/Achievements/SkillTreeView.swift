import SwiftUI

/// Flat MVP view of the financial skill tree. Groups nodes by `Track` and
/// shows lock/unlock status.
///
/// TODO (Phase 5 — "Skill Tree v2"):
/// - Canvas-based graph visualization with edges drawn between prerequisites
/// - Zoom/pan gesture
/// - Unlock animation when a new node is reached
/// - Progress ring on each node (e.g. streak30 at 22/30 days)
/// - Tap to deep-link into the relevant feature (budget, goal, streak)
///
/// For now this file is deliberately simple — a sectioned grid with lock
/// chrome. The engine is the source of truth.
struct SkillTreeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var selectedNode: SkillNode?

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                ForEach(SkillNode.Track.allCases, id: \.self) { track in
                    trackSection(track: track)
                }
                Color.clear.frame(height: 80)
            }
            .padding(.horizontal)
        }
        .navigationTitle(String(localized: "skills.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedNode) { node in
            SkillNodeDetailSheet(node: node, isUnlocked: unlockedIds.contains(node.id))
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var unlockedIds: Set<SkillNodeID> {
        // Engine call is cheap — <50 nodes, pure work — so no caching needed.
        // When this grows we can @State-cache + invalidate on data changes.
        let goalsProxy: [SavingsGoal] = []  // goals live outside DataStore today;
        // can be wired in once SavingsGoalRepository caches them — TODO.
        return SkillTreeEngine.unlockedNodes(
            SkillTreeEngine.Input(
                transactions: dataStore.transactions,
                accounts: dataStore.accounts,
                categories: dataStore.categories,
                budgets: dataStore.budgets,
                subscriptions: dataStore.subscriptions,
                goals: goalsProxy,
                currentStreak: StreakTracker.currentStreak(from: dataStore.transactions),
                hasExportedReport: SkillTreeFlags.hasExportedPDF
            )
        )
    }

    private var header: some View {
        let unlocked = unlockedIds.count
        let total = SkillNode.all.count
        let progress = total > 0 ? Double(unlocked) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "skills.header.title"))
                    .font(.headline)
                Spacer()
                Text("\(unlocked) / \(total)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color.accent, Color.aiGradientStart],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 10)
            Text(String(localized: "skills.header.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func trackSection(track: SkillNode.Track) -> some View {
        let nodes = SkillNode.all.filter { $0.track == track }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach(nodes) { node in
                    Button {
                        selectedNode = node
                        HapticManager.light()
                    } label: {
                        nodeCard(node)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func nodeCard(_ node: SkillNode) -> some View {
        let unlocked = unlockedIds.contains(node.id)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(unlocked
                          ? LinearGradient(colors: [Color.accent, Color.aiGradientStart],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(.systemGray5), Color(.systemGray5)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                if unlocked {
                    Text(node.icon)
                        .font(.system(size: 22))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(node.localizedTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(unlocked ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(unlocked ? Color.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .opacity(unlocked ? 1 : 0.7)
    }
}

// MARK: - Detail sheet

private struct SkillNodeDetailSheet: View {
    let node: SkillNode
    let isUnlocked: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(.systemGray3))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            ZStack {
                Circle()
                    .fill(isUnlocked
                          ? LinearGradient(colors: [Color.accent, Color.aiGradientStart],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                if isUnlocked {
                    Text(node.icon).font(.system(size: 40))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            Text(node.localizedTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(node.localizedDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if !isUnlocked && !node.prerequisites.isEmpty {
                let byId = SkillNode.byId
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "skills.prerequisites"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(node.prerequisites, id: \.self) { prereq in
                        if let p = byId[prereq] {
                            HStack(spacing: 6) {
                                Text(p.icon).font(.caption)
                                Text(p.localizedTitle).font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
            }

            Spacer()
        }
    }
}
