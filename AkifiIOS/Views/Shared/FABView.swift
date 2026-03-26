import SwiftUI

enum FABAction {
    case income, expense, transfer, receipt
}

struct FABView: View {
    @State private var isExpanded = false
    var onAction: (FABAction) -> Void

    private let arcRadius: CGFloat = 140
    private let subButtonSize: CGFloat = 48
    private let mainButtonSize: CGFloat = 56

    private var actions: [(action: FABAction, label: String, icon: String, startColor: Color, endColor: Color, angle: Double)] {
        [
            (.receipt, "Чек", "doc.text.viewfinder", Color(hex: "#818CF8"), Color(hex: "#0EA5E9"), -15),
            (.transfer, "Перевод", "arrow.left.arrow.right", Color(hex: "#60A5FA"), Color(hex: "#3B82F6"), -45),
            (.expense, "Расход", "arrow.down.left", Color(hex: "#FB7185"), Color(hex: "#EF4444"), -75),
            (.income, "Доход", "arrow.up.right", Color(hex: "#34D399"), Color(hex: "#22C55E"), -105),
        ]
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { isExpanded = false } }
            }

            ZStack(alignment: .bottomTrailing) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                    if isExpanded {
                        subButton(item: item, index: index)
                    }
                }

                // Main FAB
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.fabStart.opacity(0.9), Color.fabEnd.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: mainButtonSize, height: mainButtonSize)
                            .shadow(color: Color.fabEnd.opacity(0.3), radius: 8, x: 0, y: 4)

                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(isExpanded ? 45 : 0))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func subButton(item: (action: FABAction, label: String, icon: String, startColor: Color, endColor: Color, angle: Double), index: Int) -> some View {
        let angle = Angle(degrees: item.angle)
        let x = cos(angle.radians) * arcRadius
        let y = sin(angle.radians) * arcRadius

        Button {
            withAnimation(.spring(duration: 0.3)) { isExpanded = false }
            onAction(item.action)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [item.startColor.opacity(0.85), item.endColor.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: subButtonSize, height: subButtonSize)
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text(item.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(duration: 0.35, bounce: 0.2).delay(Double(index) * 0.04), value: isExpanded)
    }
}
