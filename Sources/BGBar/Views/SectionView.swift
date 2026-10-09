import SwiftUI

/// Seção de um `Kind`: cabeçalho colapsável + cartão com as linhas.
struct SectionView: View {
    let kind: Kind
    let onSelect: (Item) -> Void
    private let monitor = Monitor.shared
    @AppStorage private var collapsed: Bool

    init(kind: Kind, onSelect: @escaping (Item) -> Void) {
        self.kind = kind
        self.onSelect = onSelect
        _collapsed = AppStorage(wrappedValue: false, "collapsed.\(kind.rawValue)")
    }

    var body: some View {
        let items = monitor.items(kind)
        VStack(alignment: .leading, spacing: 6) {
            header(items)
            if !collapsed {
                Card {
                    content(items)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private func header(_ items: [Item]) -> some View {
        let up = items.filter { $0.status.isUp || $0.status == .unhealthy }.count
        let bad = items.filter { $0.status == .failed || $0.status == .unhealthy }.count
        return Button {
            withAnimation(UI.spring) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(items.isEmpty ? "0" : "\(up)/\(items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .contentTransition(.numericText())
                if bad > 0 {
                    Circle().fill(Status.failed.color).frame(width: 5, height: 5)
                }
                Spacer()
                let hidden = monitor.hiddenCount(kind)
                if hidden > 0, !monitor.showHidden {
                    Text("\(hidden) oculto\(hidden == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
