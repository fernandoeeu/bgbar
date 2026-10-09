import SwiftUI
import ServiceManagement

/// Abas do popover: uma por `Kind` + Agentes Claude.
enum Tab: String, CaseIterable, Identifiable {
    case agent, docker, dev, claude
    var id: String { rawValue }

    var kind: Kind? {
        switch self {
        case .agent: .agent
        case .docker: .docker
        case .dev: .dev
        case .claude: nil
        }
    }

    var title: String {
        switch self {
        case .dev: "Dev"
        case .claude: "Agentes Claude"
        default: kind?.title ?? ""
        }
    }

    var symbol: String { kind?.symbol ?? "sparkles" }
}

/// Conteúdo do popover: abas ⇄ detalhe, rodapé e toast.
/// Tamanho fixo (UI.width × UI.bodyHeight + rodapé): trocar de aba ou abrir o detalhe não redimensiona a janela.
struct RootView: View {
    @State private var selected: Item?
    @AppStorage("selectedTab") private var tab: Tab = .agent

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let selected {
                    DetailView(initial: selected) { self.selected = nil }
                } else {
                    listPage
                }
            }
            .frame(width: UI.width, height: UI.bodyHeight, alignment: .top)
            .overlay(alignment: .bottom) { ToastBar() }
            .clipped()

            Divider().opacity(0.6)
            FooterView()
        }
        .frame(width: UI.width)
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            HeaderView()
            TabBar(tab: $tab)
            Divider().opacity(0.6)
            ScrollView {
                Group {
                    if let kind = tab.kind {
                        SectionView(kind: kind) { selected = $0 }
                    } else {
                        Card { ClaudeAgentsTab() }
                    }
                }
                .padding(UI.pad)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(tab) // cada aba começa no topo
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Abas

private struct TabBar: View {
    @Binding var tab: Tab
    private let monitor = Monitor.shared
    @ObservedObject private var claude = ClaudeAgentsStore.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.element) { idx, t in
                let s = stats(t)
                TabButton(tab: t, count: s.count, problem: s.problem, selected: tab == t) { tab = t }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: .command)
            }
        }
        .padding(.horizontal, UI.pad)
        .padding(.bottom, 8)
    }

    private func stats(_ t: Tab) -> (count: String, problem: Bool) {
        if let kind = t.kind {
            let items = monitor.items(kind)
            let up = items.filter { $0.status.isUp || $0.status == .unhealthy }.count
            let bad = items.contains { $0.status == .failed || $0.status == .unhealthy }
            if kind == .docker && !monitor.dockerAvailable { return ("off", false) }
            return (items.isEmpty ? "0" : "\(up)/\(items.count)", bad)
        }
        func walk(_ nodes: [ClaudeAgentNode]) -> (total: Int, failed: Bool) {
            nodes.reduce((0, false)) { acc, n in
                let c = walk(n.children)
                return (acc.0 + 1 + c.total, acc.1 || n.state == .failed || c.failed)
            }
        }
        let all = claude.sessions.map { walk($0.agents) }
        let total = all.reduce(0) { $0 + $1.total }
        let failed = all.contains { $0.failed }
        let running = claude.runningCount
        return (total == 0 ? "0" : "\(running)/\(total)", failed)
    }
}

private struct TabButton: View {
    let tab: Tab
    let count: String
    let problem: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(count)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: 26)
                    // Espaço sempre reservado: o ponto não empurra nada quando aparece.
                    Circle()
                        .fill(Status.failed.color)
                        .frame(width: 5, height: 5)
                        .opacity(problem ? 1 : 0)
                }
                Text(tab.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : (hover ? 0.05 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0.1 : 0), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(problem ? "\(tab.title): há itens com problema" : tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Cabeçalho

private struct HeaderView: View {
    private let monitor = Monitor.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(monitor.health.color.gradient.opacity(0.18))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(monitor.health.color)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Segundo plano")
                    .font(.system(size: 14, weight: .semibold))
                summary
            }
            Spacer(minLength: 8)

            IconButton(symbol: "arrow.clockwise",
                       help: "Atualizar agora",
                       tint: monitor.isRefreshing ? .accentColor : .secondary) {
                monitor.refreshNow()
            }

            MoreMenu()
        }
        .padding(.horizontal, UI.pad + 2)
        .padding(.vertical, 10)
    }

    private var summary: some View {
        let running = monitor.runningCount
        let problems = monitor.problems.count
        return HStack(spacing: 4) {
            Text("\(running) rodando")
            if problems > 0 {
                Text("·")
                Text(problems == 1 ? "1 com problema" : "\(problems) com problemas")
                    .foregroundStyle(monitor.health.color)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}

private struct MoreMenu: View {
    @Bindable private var monitor = Monitor.shared
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Menu {
            Toggle(isOn: $monitor.showHidden) {
                Text("Mostrar ocultos (\(monitor.hiddenCount()))")
            }
            Toggle(isOn: Binding(get: { loginEnabled }, set: setLogin)) {
                Text("Abrir ao iniciar sessão")
            }
            if SMAppService.mainApp.status == .requiresApproval {
                Button("Aprovar em Ajustes do Sistema…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            Button("Sair do BGBar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mais opções")
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                monitor.toast = "Aprove o BGBar em Ajustes › Itens de início"
            }
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            monitor.toast = "Não deu para \(on ? "ativar" : "desativar") o início automático: \(error.localizedDescription)"
        }
    }
}

// MARK: - Toast

/// Sobreposto ao fundo da área de conteúdo: aparece sem empurrar a lista nem mudar a altura do popover.
private struct ToastBar: View {
    private let monitor = Monitor.shared

    var body: some View {
        ZStack {
            if let msg = monitor.toast {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(msg)
                        .font(.system(size: 11.5))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(symbol: "xmark", help: "Fechar", size: 18) {
                        monitor.toast = nil
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.horizontal, UI.pad)
                .padding(.bottom, 8)
            }
        }
        .task(id: monitor.toast) {
            guard let msg = monitor.toast else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, monitor.toast == msg { monitor.toast = nil }
        }
    }
}

// MARK: - Rodapé

private struct FooterView: View {
    private let monitor = Monitor.shared

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 5) {
                    Circle()
                        .fill(monitor.isRefreshing ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(updatedText(now: ctx.date))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(minWidth: 130, alignment: .leading)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            if !monitor.dockerAvailable {
                Text("· Docker off")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Sair", systemImage: "power")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(PillButtonStyle(tint: .secondary))
            .controlSize(.small)
        }
        .padding(.horizontal, UI.pad + 2)
        .padding(.vertical, 7)
    }

    private func updatedText(now: Date) -> String {
        guard let last = monitor.lastUpdate else { return "Carregando…" }
        let s = max(0, Int(now.timeIntervalSince(last)))
        if s < 2 { return "Atualizado agora" }
        if s < 60 { return "Atualizado há \(s) s" }
        return "Atualizado há \(s / 60) min"
    }
}
