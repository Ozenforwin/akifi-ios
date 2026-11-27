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
    @ScaledMetric(relativeTo: .title2) private var nodeSize: CGFloat = 52

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                ForEach(SkillNode.Track.allCases, id: \.self) { track in
                    trackSection(track: track)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "skills.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedNode) { node in
            SkillNodeDetailSheet(node: node, isUnlocked: unlockedIds.contains(node.id))
                .presentationDetents([.medium])
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
            ProgressView(value: progress)
                .tint(Color.accent)
            Text(String(localized: "skills.header.subtitle"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .akifiCard()
    }

    private func trackSection(track: SkillNode.Track) -> some View {
        let nodes = SkillNode.all.filter { $0.track == track }
        return VStack(alignment: .leading, spacing: 8) {
            Text(track.title)
                .font(.headline)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
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
                    .fill(unlocked ? Color.accent.opacity(0.15) : Color(.tertiarySystemFill))
                if unlocked {
                    Text(node.icon)
                        .font(.title2)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: nodeSize, height: nodeSize)
            Text(node.localizedTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(unlocked ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .akifiCard(.compact, padding: 10)
        .opacity(unlocked ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail sheet

private struct SkillNodeDetailSheet: View {
    let node: SkillNode
    let isUnlocked: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? Color.accent.opacity(0.15) : Color(.tertiarySystemFill))
                if isUnlocked {
                    Text(node.icon).font(.largeTitle)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)
            .padding(.top, 28)
            .accessibilityHidden(true)

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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
            }

            Spacer()
        }
    }
}
