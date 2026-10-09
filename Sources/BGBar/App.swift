import SwiftUI

@main
struct BGBarApp: App {
    init() {
        Monitor.shared.start()
        ClaudeAgentsStore.shared.start()
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
    @ObservedObject private var claude = ClaudeAgentsStore.shared

    var body: some View {
        let agents = claude.runningCount
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: monitor.health))
            if agents > 0 {
                // Indicador separado: agentes Claude rodando agora.
                Text("\(agents)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(agents > 0 ? "BGBar, \(agents) agentes Claude rodando" : "BGBar")
    }
}
