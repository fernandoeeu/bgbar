import SwiftUI

@main
struct BGBarApp: App {
    init() {
        Monitor.shared.start()
        Notifier.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ícone da barra: observa `Monitor.shared.health` e troca a imagem (cacheada).
private struct MenuBarLabel: View {
    private let monitor = Monitor.shared

    var body: some View {
        Image(nsImage: StatusIcon.image(for: monitor.health))
            .accessibilityLabel("BGBar")
    }
}
