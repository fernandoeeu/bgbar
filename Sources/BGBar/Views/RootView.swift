import SwiftUI
import ServiceManagement

/// Conteúdo do popover: lista ⇄ detalhe, rodapé e toast.
struct RootView: View {
    private let monitor = Monitor.shared
    @State private var selected: Item?
    @State private var listHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let selected {
                    DetailView(initial: selected) { go(nil) }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                        .zIndex(1)
                } else {
                    listPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .clipped()

            ToastBar()
            Divider().opacity(0.6)
            FooterView()
        }
        .frame(width: UI.width)
    }

    private func go(_ item: Item?) {
        withAnimation(UI.spring) { selected = item }
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider().opacity(0.6)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Kind.allCases) { kind in
                        SectionView(kind: kind) { go($0) }
                    }
                }
                .padding(UI.pad)
                .measureHeight { h in listHeight = h }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(listHeight, 80), UI.maxHeight - 110))
        }
    }
}

// MARK: - Cabeçalho

private struct HeaderView: View {
    private let monitor = Monitor.shared
    @State private var spin = 0.0

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

            IconButton(symbol: "arrow.clockwise", help: "Atualizar agora") {
                monitor.refreshNow()
            }
            .rotationEffect(.degrees(spin))
            .onChange(of: monitor.isRefreshing) { _, now in
                if now { withAnimation(.easeInOut(duration: 0.6)) { spin += 360 } }
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
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .animation(UI.spring, value: running)
        .animation(UI.spring, value: problems)
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
                        withAnimation(UI.spring) { monitor.toast = nil }
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(UI.spring, value: monitor.toast)
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
                }
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
