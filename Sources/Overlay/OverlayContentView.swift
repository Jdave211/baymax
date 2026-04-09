import SwiftUI

struct OverlayContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            CharacterView(mode: appState.mode)
                .position(appState.characterPosition)
                .animation(
                    .interactiveSpring(response: 0.18, dampingFraction: 0.9, blendDuration: 0.04),
                    value: appState.characterPosition
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
