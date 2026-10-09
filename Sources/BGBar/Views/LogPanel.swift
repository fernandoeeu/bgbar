import SwiftUI

/// Últimas linhas do log, atualizando a cada ~2 s enquanto visível.
struct LogPanel: View {
    let item: Item
    @State private var text = ""
    @State private var loaded = false
    @State private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Log")
                    .font(.system(size: 11.5, weight: .semibold))
                if loaded {
                    Circle().fill(Status.running.color).frame(width: 5, height: 5)
                        .help("Atualizando a cada 2 s")
                }
                Spacer()
                Button { follow.toggle() } label: {
                    Image(systemName: follow ? "arrow.down.to.line" : "pause")
                }
                .buttonStyle(PillButtonStyle(tint: follow ? .accentColor : .secondary))
                .help(follow ? "Seguindo o fim do log" : "Rolagem livre")
                Button("Console") { Task { await Actions.openLog(item, in: .console) } }
                    .buttonStyle(PillButtonStyle())
                Button("Editor") { Task { await Actions.openLog(item, in: .editor) } }
                    .buttonStyle(PillButtonStyle())
                if item.kind != .docker {
                    Button("Finder") { Task { await Actions.openLog(item, in: .finder) } }
                        .buttonStyle(PillButtonStyle())
                }
            }

            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !loaded {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Lendo log…").foregroundStyle(.secondary)
                            }
                        } else if text.isEmpty {
                            Text("Log vazio.").foregroundStyle(.secondary)
                        } else {
                            Text(text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onChange(of: text) {
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: follow) { _, on in
                    if on { withAnimation(UI.quick) { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
        }
        .task(id: item.id) {
            loaded = false
            while !Task.isCancelled {
                let snapshot = Monitor.shared.item(id: item.id) ?? item
                let new = await Actions.logTail(snapshot, lines: 200)
                if Task.isCancelled { break }
                if new != text { text = new }
                loaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
