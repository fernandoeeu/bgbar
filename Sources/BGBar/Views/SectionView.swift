import SwiftUI

/// Conteúdo de uma aba de `Kind`: cartão com as linhas, sem cabeçalho nem colapso.
struct SectionView: View {
    let kind: Kind
    let onSelect: (Item) -> Void
    private let monitor = Monitor.shared
    @AppStorage(DockerFilter.showStoppedKey) private var showStopped = false

    var body: some View {
        let items = DockerFilter.visible(kind, showStopped: showStopped)
        VStack(alignment: .leading, spacing: 6) {
            Card {
                content(items)
            }
            let stopped = monitor.items(kind).count - items.count
            if stopped > 0 {
                Text("\(stopped) parado\(stopped == 1 ? "" : "s") · mostre em ⋯ › Mostrar containers parados")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            let hidden = monitor.hiddenCount(kind)
            if hidden > 0, !monitor.showHidden {
                Text("\(hidden) oculto\(hidden == 1 ? "" : "s") · mostre em ⋯ › Mostrar ocultos")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func content(_ items: [Item]) -> some View {
        if kind == .docker && !monitor.dockerAvailable {
            EmptyState(symbol: "shippingbox.and.arrow.backward",
                       title: "Docker não está respondendo",
                       subtitle: "Abra o OrbStack ou o Docker Desktop; tento de novo sozinho.")
        } else if items.isEmpty {
            EmptyState(symbol: emptySymbol, title: emptyTitle, subtitle: emptySubtitle)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Divider().padding(.leading, 28).opacity(0.5)
                    }
                    ItemRow(item: item) { onSelect(item) }
                }
            }
            .padding(3)
        }
    }

    private var emptySymbol: String {
        switch kind {
        case .agent: "moon.zzz"
        case .docker: "shippingbox"
        case .dev: "cup.and.saucer"
        }
    }
    private var emptyTitle: String {
        switch kind {
        case .agent: "Nenhum LaunchAgent seu"
        case .docker: "Nenhum container"
        case .dev: "Nada de dev rodando"
        }
    }
    private var emptySubtitle: String {
        switch kind {
        case .agent: "Agentes em ~/Library/LaunchAgents aparecem aqui."
        case .docker: "Containers do OrbStack/Docker aparecem aqui."
        case .dev: "bun, node, python e afins aparecem quando subirem."
        }
    }
}

/// Containers parados ficam escondidos por padrão (⋯ › Mostrar containers parados).
@MainActor
enum DockerFilter {
    static let showStoppedKey = "showStoppedContainers"

    /// Itens visíveis da aba. Container parado (exited/created/dead) sai da lista, exceto
    /// fixados: esses contam como problema quando caem, então continuam à vista.
    static func visible(_ kind: Kind, showStopped: Bool) -> [Item] {
        let monitor = Monitor.shared
        let items = monitor.items(kind)
        guard kind == .docker, !showStopped else { return items }
        return items.filter { i in
            i.status.isUp || i.status == .unhealthy || i.status == .restarting || monitor.isPinned(i)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}
