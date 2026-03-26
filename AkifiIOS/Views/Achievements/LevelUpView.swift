import SwiftUI

struct LevelUpView: View {
    let achievementName: String
    let points: Int
    let icon: String
    let onDismiss: () -> Void

    @State private var scale = 0.5
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 20) {
                Text(icon)
                    .font(.system(size: 64))

                Text("Достижение разблокировано!")
                    .font(.title3.weight(.bold))

                Text(achievementName)
                    .font(.headline)
                    .foregroundStyle(.green)

                Text("+\(points) очков")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(action: onDismiss) {
                    Text("Отлично!")
                        .font(.headline)
                        .frame(width: 160)
                        .padding(.vertical, 12)
                        .background(.green.gradient)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(32)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(radius: 20)
            .scaleEffect(scale)
            .opacity(opacity)
            .padding(40)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}
