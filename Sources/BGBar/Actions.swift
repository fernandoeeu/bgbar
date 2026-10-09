import AppKit
import Darwin
import UniformTypeIdentifiers

/// Ações sobre itens (LaunchAgents, containers, processos). Todo trabalho
/// bloqueante roda fora da main thread (via `Shell.run` ou `Task.detached`).
@MainActor
enum Actions {
    enum LogApp { case console, editor, finder }

    static func canStart(_ item: Item) -> Bool { item.kind != .dev && !item.status.isUp && !item.isGhost }
    static func canStop(_ item: Item) -> Bool { item.kind != .dev && (item.status.isUp || item.status == .unhealthy || item.status == .restarting) }
    static func canRestart(_ item: Item) -> Bool { item.kind != .dev && !item.isGhost && item.status != .notLoaded }
    static func canKill(_ item: Item) -> Bool { item.pid != nil }
    static func hasLog(_ item: Item) -> Bool { item.kind == .docker || !item.logPaths.isEmpty }

    // MARK: Start / stop / restart

    static func start(_ item: Item) async {
        switch item.kind {
        case .agent:
            guard let target = agentTarget(item) else { return }
            if item.status == .notLoaded {
                guard let plist = item.plistPath else {
                    toast("Sem plist para \(item.name)")
                    return
                }
                await perform(item, verb: "iniciar", done: "\(item.name) iniciado", suppress: false) {
                    await bootstrap(plist)
                }
            } else {
                await perform(item, verb: "iniciar", done: "\(item.name) iniciado", suppress: false) {
                    await launchctl(["kickstart", target])
                }
            }
        case .docker:
            await docker(item, "start", verb: "iniciar", done: "\(item.name) iniciado", suppress: false)
        case .dev:
            break
        }
    }

    static func stop(_ item: Item) async {
        switch item.kind {
        case .agent:
            guard let target = agentTarget(item) else { return }
            await perform(item, verb: "parar", done: "\(item.name) parado") {
                await launchctl(["bootout", target])
            }
        case .docker:
            await docker(item, "stop", verb: "parar", done: "\(item.name) parado")
        case .dev:
            break
        }
    }

    static func restart(_ item: Item) async {
        switch item.kind {
        case .agent:
            guard let target = agentTarget(item) else { return }
            if item.status == .notLoaded, let plist = item.plistPath {
                await perform(item, verb: "reiniciar", done: "\(item.name) iniciado") {
                    await bootstrap(plist)
                }
            } else {
                await perform(item, verb: "reiniciar", done: "\(item.name) reiniciado") {
                    await launchctl(["kickstart", "-k", target])
                }
            }
        case .docker:
            await docker(item, "restart", verb: "reiniciar", done: "\(item.name) reiniciado")
        case .dev:
            break
        }
    }

    /// SIGTERM (ou SIGKILL se force). A UI já pediu confirmação antes de chamar.
    static func kill(_ item: Item, force: Bool = false) async {
        guard let pid = item.pid, pid > 1 else {
            toast("\(item.name) não tem PID")
            return
        }
        let monitor = Monitor.shared
        monitor.suppressNotifications(for: item.id)
        let signal = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, signal) == 0 {
            toast("\(force ? "SIGKILL" : "SIGTERM") enviado para \(item.name) (PID \(pid))")
        } else {
            let msg = String(cString: strerror(errno))
            toast("Falha ao encerrar \(item.name): \(msg)")
        }
        try? await Task.sleep(for: .milliseconds(400))
        monitor.refreshNow()
    }

    // MARK: Utilidades simples

    static func openPort(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyPID(_ item: Item) {
        guard let pid = item.pid else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(pid), forType: .string)
        toast("PID \(pid) copiado")
    }

    // MARK: Logs

    static func openLog(_ item: Item, in app: LogApp) async {
        var urls: [URL]
        if item.kind == .docker {
            guard let url = await dumpDockerLog(item) else { return }
            urls = [url]
        } else {
            let paths = item.logPaths
            let existing = await Task.detached { paths.filter { FileManager.default.fileExists(atPath: $0) } }.value
            guard !existing.isEmpty else {
                toast(paths.isEmpty ? "\(item.name) não tem log" : "Log de \(item.name) não existe")
                return
            }
            urls = existing.map { URL(fileURLWithPath: $0) }
        }

        let ws = NSWorkspace.shared
        switch app {
        case .finder:
            ws.activateFileViewerSelecting(urls)
        case .console:
            let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
            await open(Array(urls.prefix(1)), with: console, name: item.name)
        case .editor:
            let editor = ws.urlForApplication(toOpen: UTType.plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            await open(urls, with: editor, name: item.name)
        }
    }

    /// Últimas linhas do log (arquivo ou `docker logs`). Fora da main thread.
    static func logTail(_ item: Item, lines: Int = 200) async -> String {
        let n = max(1, lines)
        if item.kind == .docker {
            guard let id = item.containerID else { return "Container sem ID." }
            let r = await Shell.run("docker", ["logs", "--tail", String(n), id], timeout: 15)
            if !r.ok && r.out.isEmpty {
                let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Falha ao ler logs de \(item.name): \(err.isEmpty ? "exit \(r.status)" : err)"
            }
            let text = combine(out: r.out, err: r.err)
            return text.isEmpty ? "(log vazio)" : lastLines(text, n)
        }

        var seen = Set<String>()
        let paths = item.logPaths.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else {
            return "Este item não tem arquivo de log configurado (StandardOutPath/StandardErrorPath)."
        }
        return await Task.detached(priority: .utility) {
            let labeled = paths.count > 1
            var parts: [String] = []
            for path in paths {
                let short = Fmt.abbreviateHome(path)
                let header = labeled ? "==> \(short) <==\n" : ""
                guard FileManager.default.fileExists(atPath: path) else {
                    parts.append(header + "(arquivo não existe: \(short))")
                    continue
                }
                guard let tail = readTail(path: path, maxBytes: 64 * 1024) else {
                    parts.append(header + "(não foi possível ler \(short))")
                    continue
                }
                let body = lastLines(tail, n)
                parts.append(header + (body.isEmpty ? "(log vazio)" : body))
            }
            return parts.joined(separator: "\n\n")
        }.value
    }

    // MARK: - Privado

    private static var domain: String { "gui/\(getuid())" }

    private static func agentTarget(_ item: Item) -> String? {
        guard let label = item.label, !label.isEmpty else {
            toast("Sem label para \(item.name)")
            return nil
        }
        return "\(domain)/\(label)"
    }

    private static func launchctl(_ args: [String]) async -> Shell.Result {
        await Shell.run("/bin/launchctl", args, timeout: 15)
    }

    private static func bootstrap(_ plist: String) async -> Shell.Result {
        await launchctl(["bootstrap", domain, plist])
    }

    private static func docker(_ item: Item, _ cmd: String, verb: String, done: String, suppress: Bool = true) async {
        guard let id = item.containerID else {
            toast("Container sem ID: \(item.name)")
            return
        }
        await perform(item, verb: verb, done: done, suppress: suppress) {
            await Shell.run("docker", [cmd, id], timeout: 35)
        }
    }

    /// Marca o item como ocupado, roda o comando, mostra toast e atualiza.
    private static func perform(
        _ item: Item, verb: String, done: String, suppress: Bool = true,
        _ op: () async -> Shell.Result
    ) async {
        let monitor = Monitor.shared
        if suppress { monitor.suppressNotifications(for: item.id, seconds: 30) }
        monitor.busy.insert(item.id)
        let r = await op()
        monitor.busy.remove(item.id)
        if r.ok {
            toast(done)
        } else {
            toast("Falha ao \(verb) \(item.name): \(errorText(r))")
        }
        monitor.refreshNow()
    }

    private static func errorText(_ r: Shell.Result) -> String {
        let raw = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        guard !text.isEmpty else { return "exit \(r.status)" }
        let line = text.split(separator: "\n").last.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private static func toast(_ msg: String) {
        Monitor.shared.toast = msg
    }

    private static func open(_ urls: [URL], with app: URL, name: String) async {
        guard !urls.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
        } catch {
            toast("Falha ao abrir log de \(name): \(error.localizedDescription)")
        }
    }

    /// Grava `docker logs --tail 2000` num arquivo temporário e devolve a URL.
    private static func dumpDockerLog(_ item: Item) async -> URL? {
        guard let id = item.containerID else {
            toast("Container sem ID: \(item.name)")
            return nil
        }
        let r = await Shell.run("docker", ["logs", "--tail", "2000", id], timeout: 20)
        if !r.ok && r.out.isEmpty {
            toast("Falha ao ler logs de \(item.name): \(errorText(r))")
            return nil
        }
        let text = combine(out: r.out, err: r.err)
        let safe = String(item.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-\(safe).log")
        let ok = await Task.detached { () -> Bool in
            (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }.value
        guard ok else {
            toast("Falha ao gravar log temporário de \(item.name)")
            return nil
        }
        return url
    }

    /// Junta stdout e stderr do `docker logs` (a intercalação exata se perde).
    nonisolated private static func combine(out: String, err: String) -> String {
        let o = out.trimmingCharacters(in: .newlines)
        let e = err.trimmingCharacters(in: .newlines)
        if o.isEmpty { return e }
        if e.isEmpty { return o }
        return o + "\n" + e
    }

    nonisolated private static func lastLines(_ text: String, _ n: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let all = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(n).joined(separator: "\n")
    }

    /// Lê só os últimos `maxBytes` do arquivo, descartando a primeira linha parcial.
    nonisolated private static func readTail(path: String, maxBytes: UInt64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        do {
            let size = try fh.seekToEnd()
            let start = size > maxBytes ? size - maxBytes : 0
            try fh.seek(toOffset: start)
            let data = try fh.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            return text
        } catch {
            return nil
        }
    }
}
