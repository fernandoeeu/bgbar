import Foundation
import Observation

/// Estado central: faz polling, guarda itens, fixados/ocultos e detecta quedas.
@MainActor
@Observable
final class Monitor {
    static let shared = Monitor()

    private(set) var agents: [Item] = []
    private(set) var docker: [Item] = []
    private(set) var dev: [Item] = []
    private(set) var dockerAvailable = true
    private(set) var lastUpdate: Date?
    private(set) var isRefreshing = false
    /// Mensagem transitória para a UI (erro/sucesso de ação).
    var toast: String?
    /// IDs com ação em andamento (para spinner na linha). Dono: `Actions` (a UI só lê).
    var busy: Set<String> = []

    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    private(set) var pinned: Set<String> {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinned") }
    }
    private(set) var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }
    /// Metadados de itens fixados, para mostrar linha "fantasma" quando somem.
    private var pinnedMeta: [String: [String]] {
        didSet { UserDefaults.standard.set(pinnedMeta, forKey: "pinnedMeta") }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var previous: [String: Item] = [:]
    @ObservationIgnored private var suppressedUntil: [String: Date] = [:]
    @ObservationIgnored private var dockerStats: [String: Docker.Stat] = [:]
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var dockerBackoff = 0
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var statsInFlight = false

    private init() {
        let d = UserDefaults.standard
        showHidden = d.bool(forKey: "showHidden")
        pinned = Set(d.stringArray(forKey: "pinned") ?? [])
        hidden = Set(d.stringArray(forKey: "hidden") ?? [])
        pinnedMeta = (d.dictionary(forKey: "pinnedMeta") as? [String: [String]]) ?? [:]
    }

    // MARK: Ciclo

    func start(interval: TimeInterval = 2.5) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Pede uma rodada já. Se uma estiver em andamento (com dados possivelmente
    /// anteriores a uma ação), agenda outra logo em seguida em vez de descartar.
    func refreshNow() {
        if isRefreshing { refreshAgain = true; return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        tick += 1

        let wantDocker = dockerBackoff == 0
        if dockerBackoff > 0 { dockerBackoff -= 1 }
        let snap = await Self.collect(includeDocker: wantDocker)

        agents = snap.agents
        dev = snap.dev
        if wantDocker {
            if let d = snap.docker {
                dockerAvailable = true
                docker = d
            } else {
                dockerAvailable = false
                docker = []
                dockerBackoff = 6 // ~15 s até tentar de novo
            }
        }
        applyDockerStats()
        if dockerAvailable, !statsInFlight, tick % 4 == 1 {
            statsInFlight = true
            Task { [weak self] in
                let stats = await Docker.stats() // nonisolated: roda fora da main
                guard let self else { return }
                self.statsInFlight = false
                self.dockerStats = stats
                self.applyDockerStats()
            }
        }

        detectDrops()
        lastUpdate = Date()
    }

    private struct Snapshot: Sendable {
        var agents: [Item]
        var docker: [Item]?
        var dev: [Item]
    }

    /// Roda fora da main thread (nonisolated + async).
    nonisolated private static func collect(includeDocker: Bool) async -> Snapshot {
        async let procsT = ProcTable.load()
        async let portsT = Ports.load()
        async let dockerT: [Item]? = includeDocker ? Docker.collect() : nil
        let procs = await procsT
        let ports = await portsT
        let agents = await LaunchAgents.collect(procs: procs, ports: ports)
        let owned = LaunchAgents.ownedPIDs(agents, procs: procs)
        let dev = await DevProcs.collect(procs: procs, ports: ports, excluded: owned)
        return Snapshot(agents: agents, docker: await dockerT, dev: dev)
    }

    private func applyDockerStats() {
        guard !dockerStats.isEmpty else { return }
        docker = docker.map { item in
            var i = item
            if i.status.isUp || i.status == .unhealthy, let s = dockerStats[i.name] {
                i.cpu = s.cpu
                i.memBytes = s.mem
            }
            return i
        }
    }

    // MARK: Quedas e notificações

    /// Evita notificar quedas causadas pelo próprio app (stop/restart/kill).
    func suppressNotifications(for id: String, seconds: TimeInterval = 20) {
        let until = Date().addingTimeInterval(seconds)
        suppressedUntil[id] = max(until, suppressedUntil[id] ?? until)
    }

    private func detectDrops() {
        let current = agents + docker + dev
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer { previous = byID }
        guard !previous.isEmpty else { return }
        let now = Date()

        for (id, old) in previous where old.status.isUp {
            if hidden.contains(old.key) { continue }
            if let until = suppressedUntil[id], until > now { continue }
            let new = byID[id]
            switch old.kind {
            case .agent:
                guard let new, !new.status.isUp else { continue }
                Notifier.shared.notifyDown(new, previous: old)
            case .docker:
                // Container removido (ex.: recriado pelo compose) não conta como queda.
                guard let new, !new.status.isUp else { continue }
                Notifier.shared.notifyDown(new, previous: old)
            case .dev:
                // Processos de dev só notificam se fixados.
                guard pinned.contains(old.key), !(new?.status.isUp ?? false) else { continue }
                var gone = old
                gone.status = .stopped
                gone.pid = nil
                Notifier.shared.notifyDown(gone, previous: old)
            }
        }
        suppressedUntil = suppressedUntil.filter { $0.value > now }
    }

    // MARK: Fixar / ocultar

    func isPinned(_ item: Item) -> Bool { pinned.contains(item.key) }
    func isHidden(_ item: Item) -> Bool { hidden.contains(item.key) }

    func togglePin(_ item: Item) {
        if pinned.contains(item.key) {
            pinned.remove(item.key)
            pinnedMeta[item.key] = nil
        } else {
            pinned.insert(item.key)
            hidden.remove(item.key)
            pinnedMeta[item.key] = [item.kind.rawValue, item.name, item.detail, item.workingDir ?? ""]
        }
    }

    func toggleHidden(_ item: Item) {
        if hidden.contains(item.key) {
            hidden.remove(item.key)
        } else {
            hidden.insert(item.key)
            pinned.remove(item.key)
            pinnedMeta[item.key] = nil
        }
    }

    // MARK: Consultas para a UI

    func all(_ kind: Kind) -> [Item] {
        switch kind {
        case .agent: agents
        case .docker: docker
        case .dev: dev
        }
    }

    /// Itens visíveis da seção, ordenados: fixados, problemas, rodando, resto.
    /// Inclui linhas fantasma de fixados que não estão presentes.
    func items(_ kind: Kind) -> [Item] {
        var list = all(kind).filter { showHidden || !hidden.contains($0.key) }
        let presentKeys = Set(all(kind).map(\.key))
        for key in pinned where !presentKeys.contains(key) {
            guard let meta = pinnedMeta[key], meta.count >= 4, meta[0] == kind.rawValue else { continue }
            var ghost = Item(id: key, key: key, kind: kind, name: meta[1], detail: meta[2], status: .stopped)
            ghost.workingDir = meta[3].isEmpty ? nil : meta[3]
            ghost.statusNote = "não encontrado"
            ghost.isGhost = true
            list.append(ghost)
        }
        func rank(_ i: Item) -> Int {
            var r = 0
            if !pinned.contains(i.key) { r += 100 }
            switch i.status {
            case .failed, .unhealthy: r += 0
            case .restarting, .starting: r += 10
            case .running: r += 20
            case .stopped, .notLoaded: r += 30
            }
            return r
        }
        return list.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func hiddenCount(_ kind: Kind? = nil) -> Int {
        let kinds = kind.map { [$0] } ?? Kind.allCases
        return kinds.reduce(0) { $0 + all($1).filter { hidden.contains($0.key) }.count }
    }

    /// Busca também entre ocultos (o detalhe não pode "sumir" ao ocultar o item) e fantasmas.
    func item(id: String) -> Item? {
        for k in Kind.allCases { if let i = all(k).first(where: { $0.id == id }) { return i } }
        for k in Kind.allCases { if let i = items(k).first(where: { $0.id == id && $0.isGhost }) { return i } }
        return nil
    }

    /// Itens que contam como problema para o indicador da barra.
    var problems: [Item] {
        Kind.allCases.flatMap { items($0) }.filter { i in
            if hidden.contains(i.key) { return false }
            let isPinned = pinned.contains(i.key)
            switch i.status {
            case .unhealthy, .restarting, .starting: return true
            case .failed:
                // Containers parados com erro antigo só contam se fixados.
                return i.kind != .docker || isPinned
            case .stopped, .notLoaded: return isPinned
            case .running: return false
            }
        }
    }

    var health: Health {
        let p = problems
        if p.contains(where: { $0.status == .failed || $0.status == .unhealthy || ($0.isGhost) || ($0.status == .stopped || $0.status == .notLoaded) }) {
            return .critical
        }
        if !p.isEmpty { return .warning }
        return .ok
    }

    var runningCount: Int {
        Kind.allCases.flatMap { items($0) }.filter { $0.status.isUp || $0.status == .unhealthy }.count
    }
}
