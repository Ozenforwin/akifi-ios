import SwiftUI

struct SplashView: View {
    @State private var scale = 0.7
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.accent.gradient)

                Text("Akifi")
                    .font(.largeTitle.bold())

                ProgressView()
                    .padding(.top, 20)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}
