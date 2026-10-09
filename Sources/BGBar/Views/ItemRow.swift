import SwiftUI

/// Linha compacta de um item na lista.
struct ItemRow: View {
    let item: Item
    let onOpen: () -> Void
    private let monitor = Monitor.shared
    @State private var hover = false

    var body: some View {
        let busy = monitor.busy.contains(item.id)
        let pinned = monitor.isPinned(item)
        let hidden = monitor.isHidden(item)

        HStack(alignment: .top, spacing: 9) {
            StatusDot(status: item.status)
                .padding(.top, 5)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .italic(item.isGhost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange.opacity(0.85))
                            .rotationEffect(.degrees(35))
                    }
                    if hidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                chips
            }
            .opacity(hidden ? 0.5 : (item.isGhost ? 0.6 : 1))

            Spacer(minLength: 4)

            trailing(busy: busy)
                .padding(.top, 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(UI.quick) { hover = h } }
        .onTapGesture(perform: onOpen)
        .contextMenu { ItemMenu(item: item, onOpen: onOpen) }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            if item.status != .running || item.statusNote != nil {
                Chip(text: item.chipStatusText, tint: item.status == .stopped || item.status == .notLoaded ? nil : item.status.color)
            }
            if let up = item.uptime {
                Chip(text: Fmt.uptime(up), symbol: "clock")
            }
            if let cpu = item.cpu, item.status.isUp || item.status == .unhealthy {
                Chip(text: Fmt.cpu(cpu), symbol: "cpu", tint: cpu >= 80 ? Status.restarting.color : nil)
            }
            if let mem = item.memBytes, item.status.isUp || item.status == .unhealthy {
                Chip(text: Fmt.memory(mem), symbol: "memorychip")
            }
            ForEach(item.ports.prefix(3), id: \.self) { PortChip(port: $0) }
            if item.ports.count > 3 {
                Chip(text: "+\(item.ports.count - 3)")
            }
            if let pid = item.pid, item.ports.count < 2 {
                Chip(text: "\(pid)", symbol: "number", mono: true)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func trailing(busy: Bool) -> some View {
        if busy {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 22, height: 22)
        } else if hover {
            HStack(spacing: 0) {
                if Actions.canStart(item) {
                    IconButton(symbol: "play.fill", help: "Iniciar", tint: Status.running.color) { Run.perform(.start, on: item) }
                }
                if Actions.canRestart(item), item.status.isUp || item.status == .unhealthy {
                    IconButton(symbol: "arrow.clockwise", help: "Reiniciar") { Run.perform(.restart, on: item) }
                }
                if Actions.canStop(item) {
                    IconButton(symbol: "stop.fill", help: "Parar") { Run.perform(.stop, on: item) }
                }
                if Actions.hasLog(item) {
                    IconButton(symbol: "doc.text", help: "Abrir log") { Task { await Actions.openLog(item, in: .console) } }
                }
                IconButton(symbol: "chevron.right", help: "Detalhes", size: 20, action: onOpen)
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

/// Menu de contexto com todas as ações (reaproveitado no detalhe se preciso).
struct ItemMenu: View {
    let item: Item
    var onOpen: (() -> Void)? = nil
    private let monitor = Monitor.shared

    var body: some View {
        if let onOpen {
            Button("Ver detalhes", systemImage: "info.circle", action: onOpen)
            Divider()
        }
        if Actions.canStart(item) {
            Button("Iniciar", systemImage: "play.fill") { Run.perform(.start, on: item) }
        }
        if Actions.canStop(item) {
            Button("Parar", systemImage: "stop.fill") { Run.perform(.stop, on: item) }
        }
        if Actions.canRestart(item) {
            Button("Reiniciar", systemImage: "arrow.clockwise") { Run.perform(.restart, on: item) }
        }
        if Actions.canKill(item) {
            Menu("Encerrar processo") {
                Button("SIGTERM") { Run.perform(.kill(force: false), on: item) }
                Button("SIGKILL (forçar)") { Run.perform(.kill(force: true), on: item) }
            }
        }
        Divider()
        if !item.ports.isEmpty {
            Menu("Abrir porta") {
                ForEach(item.ports, id: \.self) { p in
                    Button("localhost:\(String(p))") { Actions.openPort(p) }
                }
            }
        }
        if Actions.hasLog(item) {
            Menu("Abrir log") {
                Button("No Console") { Task { await Actions.openLog(item, in: .console) } }
                Button("No editor") { Task { await Actions.openLog(item, in: .editor) } }
                Button("No Finder") { Task { await Actions.openLog(item, in: .finder) } }
            }
        }
        if item.pid != nil {
            Button("Copiar PID", systemImage: "doc.on.doc") { Actions.copyPID(item) }
        }
        Divider()
        Button(monitor.isPinned(item) ? "Desafixar" : "Fixar",
               systemImage: monitor.isPinned(item) ? "pin.slash" : "pin") { monitor.togglePin(item) }
        Button(monitor.isHidden(item) ? "Mostrar" : "Ocultar",
               systemImage: monitor.isHidden(item) ? "eye" : "eye.slash") { monitor.toggleHidden(item) }
    }
}
