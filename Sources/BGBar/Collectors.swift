import Foundation

// Coletores. Cada `load`/`collect` roda comandos externos via `Shell.run` (fila global,
// com timeout) e delega a interpretação a funções puras (`parse…`), testadas em
// Tests/BGBarTests com fixtures sintéticas.

// MARK: - Tabela de processos (ps)

struct Proc: Sendable {
    let pid: Int32
    let ppid: Int32
    let elapsed: TimeInterval
    let cpu: Double
    let rssKB: UInt64
    let command: String

    var args: [String] { command.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
    var executable: String { args.first ?? "" }
    var execName: String { (executable as NSString).lastPathComponent }
}

struct ProcTable: Sendable {
    var byPID: [Int32: Proc] = [:]
    var children: [Int32: [Int32]] = [:]

    func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var seen: Set<Int32> = [pid]
        var stack = children[pid] ?? []
        while let p = stack.popLast() {
            guard seen.insert(p).inserted else { continue }
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    /// PID + descendentes.
    func tree(_ pid: Int32) -> [Int32] { [pid] + descendants(of: pid) }

    /// Ancestrais (pai, avô, …) até o launchd, sem o próprio PID.
    func ancestors(of pid: Int32) -> [Proc] {
        var out: [Proc] = []
        var cur = byPID[pid]?.ppid ?? 0
        while cur > 1, out.count < 64, let p = byPID[cur] {
            out.append(p)
            cur = p.ppid
        }
        return out
    }

    /// Soma de CPU e RSS (bytes) de um conjunto de PIDs.
    func usage(_ pids: [Int32]) -> (cpu: Double, memBytes: UInt64) {
        var cpu = 0.0, kb: UInt64 = 0
        for pid in pids {
            guard let p = byPID[pid] else { continue }
            cpu += p.cpu
            kb += p.rssKB
        }
        return (cpu, kb * 1024)
    }

    static func load() async -> ProcTable {
        // Só processos do usuário atual (-x sem -a).
        let r = await Shell.run("/bin/ps", ["-x", "-ww", "-o", "pid=,ppid=,etime=,pcpu=,rss=,command="], timeout: 4)
        return parse(r.out)
    }

    /// Saída de `ps -o pid=,ppid=,etime=,pcpu=,rss=,command=`.
    static func parse(_ out: String) -> ProcTable {
        var t = ProcTable()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let command = parts[5].drop { $0 == " " }
            let p = Proc(
                pid: pid, ppid: ppid,
                elapsed: parseEtime(String(parts[2])),
                cpu: Double(parts[3]) ?? 0,
                rssKB: UInt64(parts[4]) ?? 0,
                command: String(command)
            )
            t.byPID[pid] = p
            t.children[ppid, default: []].append(pid)
        }
        return t
    }

    /// Formato do ps: [[dd-]hh:]mm:ss
    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let comps = rest.split(separator: ":").compactMap { Int($0) }
        var secs = 0
        for c in comps { secs = secs * 60 + c }
        return TimeInterval(days * 86400 + secs)
    }
}

// MARK: - Portas em escuta (lsof)

enum Ports {
    static func load() async -> [Int32: Set<Int>] {
        let r = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 4)
        return parse(r.out)
    }

    /// Saída de `lsof -Fpn`: linhas `p<pid>`, `f<fd>`, `n<endereço>` ("*:3000", "127.0.0.1:5432", "[::1]:5432").
    static func parse(_ out: String) -> [Int32: Set<Int>] {
        var map: [Int32: Set<Int>] = [:]
        var current: Int32?
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            if tag == "p" {
                current = Int32(value)
            } else if tag == "n", let pid = current,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) {
                map[pid, default: []].insert(port)
            }
        }
        return map
    }

    static func collect(_ pids: [Int32], _ map: [Int32: Set<Int>]) -> [Int] {
        var s = Set<Int>()
        for p in pids { s.formUnion(map[p] ?? []) }
        return s.sorted()
    }
}

// MARK: - LaunchAgents do usuário

enum LaunchAgents {
    struct Info: Sendable {
        let label: String
        let plistPath: String
        let program: [String]
        let logPaths: [String]
        let workingDir: String?
    }

    static var uid: uid_t { getuid() }
    static var domain: String { "gui/\(uid)" }

    static func plists() -> [Info] {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".plist") }.sorted().compactMap { file in
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return parsePlist(data, path: path)
        }
    }

    static func parsePlist(_ data: Data, path: String) -> Info? {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else { return nil }
        var program = dict["ProgramArguments"] as? [String] ?? []
        if program.isEmpty, let p = dict["Program"] as? String { program = [p] }
        var logs: [String] = []
        for k in ["StandardOutPath", "StandardErrorPath"] {
            if let p = dict[k] as? String, !logs.contains(p) { logs.append(p) }
        }
        return Info(label: label, plistPath: path, program: program,
                    logPaths: logs, workingDir: dict["WorkingDirectory"] as? String)
    }

    struct State: Sendable, Equatable {
        var loaded = false
        var state: String?
        var pid: Int32?
        var lastExit: Int?
        var lastExitText: String?
        /// "last terminating signal = Killed: 9" -> "Killed: 9"
        var lastSignal: String?
    }

    static func state(_ label: String) async -> State {
        let r = await Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 3)
        guard r.ok else { return State() }
        return parsePrint(r.out)
    }

    /// Saída de `launchctl print gui/<uid>/<label>` (serviço carregado).
    /// Só o nível de topo (um tab) interessa: blocos aninhados (coalitions, environment…)
    /// também têm "state =", "pid =" etc.
    static func parsePrint(_ out: String) -> State {
        var s = State()
        s.loaded = true
        for raw in out.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = ") {
                s.state = String(line.dropFirst("state = ".count))
            } else if line.hasPrefix("pid = ") {
                s.pid = Int32(line.dropFirst("pid = ".count))
            } else if line.hasPrefix("last exit code = ") {
                let v = String(line.dropFirst("last exit code = ".count))
                s.lastExitText = v
                let digits = v.prefix { $0.isNumber || $0 == "-" }
                s.lastExit = Int(digits)
            } else if line.hasPrefix("last terminating signal = ") {
                s.lastSignal = String(line.dropFirst("last terminating signal = ".count))
            }
        }
        return s
    }

    /// Labels carregados segundo `launchctl list` ("PID\tStatus\tLabel"). nil se falhou.
    static func loadedLabels() async -> Set<String>? {
        let r = await Shell.run("/bin/launchctl", ["list"], timeout: 3)
        guard r.ok else { return nil }
        return parseList(r.out)
    }

    static func parseList(_ out: String) -> Set<String> {
        var s = Set<String>()
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, cols[0] != "PID" else { continue }
            s.insert(String(cols[2]))
        }
        return s
    }

    static func displayName(_ label: String) -> String {
        var comps = label.split(separator: ".").map(String.init)
        if comps.count > 2, ["com", "org", "io", "dev", "net", "br", "me", "app"].contains(comps[0]) {
            comps.removeFirst()
        }
        return comps.joined(separator: ".")
    }

    static func collect(procs: ProcTable, ports: [Int32: Set<Int>]) async -> [Item] {
        let infos = plists()
        guard !infos.isEmpty else { return [] }
        // Um `launchctl list` evita um `print` por agent não carregado.
        let loaded = await loadedLabels()
        let states: [String: State] = await withTaskGroup(of: (String, State).self) { g in
            for info in infos where loaded?.contains(info.label) ?? true {
                g.addTask { (info.label, await state(info.label)) }
            }
            var out: [String: State] = [:]
            for await (l, s) in g { out[l] = s }
            return out
        }
        return infos.map { item(info: $0, state: states[$0.label] ?? State(), procs: procs, ports: ports) }
    }

    static func item(info: Info, state st: State, procs: ProcTable, ports: [Int32: Set<Int>],
                     now: Date = Date()) -> Item {
        var item = Item(
            id: "agent:\(info.label)", key: "agent:\(info.label)", kind: .agent,
            name: displayName(info.label),
            detail: Summarize.command(info.program, cwd: info.workingDir),
            status: .stopped
        )
        item.label = info.label
        item.plistPath = info.plistPath
        item.logPaths = info.logPaths
        item.workingDir = info.workingDir
        item.group = info.workingDir.map { Summarize.projectName(cwd: $0, args: info.program) }
        item.command = info.program.joined(separator: " ")
        item.exitCode = st.lastExit
        if !st.loaded {
            item.status = .notLoaded
        } else if let pid = st.pid {
            item.status = .running
            item.pid = pid
            let tree = procs.tree(pid)
            if let p = procs.byPID[pid] {
                item.startedAt = now.addingTimeInterval(-p.elapsed)
            }
            let u = procs.usage(tree)
            item.cpu = u.cpu
            item.memBytes = u.memBytes
            item.ports = Ports.collect(tree, ports)
        } else if st.state == "spawn scheduled" {
            item.status = .restarting
            item.statusNote = "último exit \(st.lastSignal ?? st.lastExitText ?? "?")"
        } else if let code = st.lastExit, code != 0 {
            item.status = .failed
            item.statusNote = "exit \(st.lastExitText ?? String(code))"
        } else if let sig = st.lastSignal {
            item.status = .failed
            item.statusNote = "sinal \(sig)"
        } else {
            item.status = .stopped
            if st.lastExit == 0 { item.statusNote = "saiu com 0" }
        }
        return item
    }

    /// PIDs (com descendentes) que pertencem a agents, para não duplicar em "dev".
    static func ownedPIDs(_ items: [Item], procs: ProcTable) -> Set<Int32> {
        var s = Set<Int32>()
        for i in items { if let p = i.pid { s.formUnion(procs.tree(p)) } }
        return s
    }
}

// MARK: - Docker

enum Docker {
    struct Row: Decodable, Sendable {
        let ID: String
        let Names: String
        let Image: String
        let State: String
        let Status: String
        let Ports: String
        let Labels: String?
    }

    struct Stat: Sendable, Equatable {
        let cpu: Double
        let mem: UInt64
    }

    /// nil = docker indisponível.
    static func collect() async -> [Item]? {
        let r = await Shell.run("docker", ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: 4)
        guard r.ok else { return nil }
        let rows = parseRows(r.out)

        // Hora de início real dos que estão rodando.
        var started: [String: Date] = [:]
        let running = rows.filter { $0.State == "running" || $0.State == "restarting" }.map(\.ID)
        if !running.isEmpty {
            let ins = await Shell.run("docker", ["inspect", "--format", "{{.Id}} {{.State.StartedAt}}"] + running, timeout: 4)
            started = parseInspect(ins.out)
        }
        return rows.map { item($0, startedAt: started[$0.ID]) }
    }

    /// Uma linha JSON por container (`docker ps --format '{{json .}}'`); linhas inválidas são ignoradas.
    static func parseRows(_ out: String) -> [Row] {
        let decoder = JSONDecoder()
        return out.split(separator: "\n").compactMap { try? decoder.decode(Row.self, from: Data($0.utf8)) }
    }

    /// Linhas "<id> <StartedAt>".
    static func parseInspect(_ out: String) -> [String: Date] {
        var started: [String: Date] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2, let d = parseDate(String(p[1])) else { continue }
            started[String(p[0])] = d
        }
        return started
    }

    /// RFC 3339 do Docker, com até nanossegundos ("2026-10-09T16:48:51.30345183Z").
    /// "0001-01-01T00:00:00Z" (nunca iniciou) vira nil.
    static func parseDate(_ raw: String) -> Date? {
        var base = raw
        var frac = 0.0
        if let dot = raw.firstIndex(of: ".") {
            let afterDot = raw[raw.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            frac = Double("0." + digits) ?? 0
            base = String(raw[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        guard let d = ISO8601DateFormatter().date(from: base) else { return nil }
        if d.timeIntervalSince1970 < 0 { return nil }
        return d.addingTimeInterval(frac)
    }

    static func item(_ row: Row, startedAt: Date?) -> Item {
        let name = row.Names.split(separator: ",").first.map(String.init) ?? row.ID
        let labels = labels(row.Labels)
        var item = Item(
            id: "docker:\(name)", key: "docker:\(name)", kind: .docker,
            name: name, detail: row.Image, status: .stopped
        )
        item.containerID = row.ID
        item.group = labels["com.docker.compose.project"]
        item.workingDir = labels["com.docker.compose.project.working_dir"]
        item.startedAt = startedAt
        item.ports = hostPorts(row.Ports)
        item.statusNote = row.Status
        switch row.State {
        case "running":
            if row.Status.contains("(unhealthy)") { item.status = .unhealthy }
            else if row.Status.contains("health: starting") { item.status = .starting }
            else { item.status = .running }
        case "restarting":
            item.status = .restarting
        case "exited":
            let code = exitCode(row.Status)
            item.exitCode = code
            item.status = (code ?? 0) == 0 ? .stopped : .failed
        case "dead":
            item.status = .failed
        default: // created, paused, removing
            item.status = .stopped
        }
        return item
    }

    static func stats() async -> [String: Stat] {
        let r = await Shell.run("docker", ["stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"], timeout: 6)
        return parseStats(r.out)
    }

    /// Linhas "nome\t0.92%\t139.1MiB / 11.73GiB".
    static func parseStats(_ out: String) -> [String: Stat] {
        var result: [String: Stat] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\t")
            guard p.count == 3 else { continue }
            let cpu = Double(p[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) ?? 0
            let memStr = p[2].split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            result[String(p[0])] = Stat(cpu: cpu, mem: parseSize(memStr))
        }
        return result
    }

    static func parseSize(_ s: String) -> UInt64 {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
                                         ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, mult) in units where s.hasSuffix(u) {
            let n = Double(s.dropLast(u.count)) ?? 0
            return UInt64(n * mult)
        }
        return 0
    }

    /// "a=1,b=2". Valores com vírgula (ex.: depends_on) ficam truncados, mas as chaves
    /// que usamos (project, working_dir) não têm vírgula na prática.
    static func labels(_ raw: String?) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (raw ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    /// "0.0.0.0:4040->3000/tcp, [::]:4040->3000/tcp" -> [4040]
    static func hostPorts(_ s: String) -> [Int] {
        var ports = Set<Int>()
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let arrow = p.range(of: "->") else { continue }
            let host = p[..<arrow.lowerBound]
            guard let colon = host.lastIndex(of: ":") else { continue }
            let spec = host[host.index(after: colon)...]
            // Faixa "8000-8002": publica todas.
            let bounds = spec.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 64 {
                ports.formUnion(bounds[0]...bounds[1])
            } else if let n = Int(spec) {
                ports.insert(n)
            }
        }
        return ports.sorted()
    }

    /// "Exited (137) 7 weeks ago" -> 137
    static func exitCode(_ status: String) -> Int? {
        guard let open = status.firstIndex(of: "("), let close = status.firstIndex(of: ")"), open < close else { return nil }
        return Int(status[status.index(after: open)..<close])
    }
}

// MARK: - Processos de dev

enum DevProcs {
    static let runtimes: Set<String> = [
        "bun", "node", "deno", "python", "python3", "Python", "ruby", "tsx", "ts-node",
        "npm", "pnpm", "yarn", "uvicorn", "gunicorn", "php", "java", "go", "air", "cargo",
        "beam.smp", "elixir",
    ]
    /// Ruído conhecido: ferramentas internas de agentes/IDEs, MCPs, CLIs globais.
    /// Vale para o próprio processo e para qualquer ancestral (filhos de ruído também são ruído).
    static let noise = [
        "/_npx/", "npm exec ", "/.bun/install/cache/", "codex-cu-engine", "cua_node",
        "/.vscode/", "/.vscode-server/", "/.cursor/", "/.windsurf/", "Code Helper",
        "@modelcontextprotocol/", "mcp-server", "-mcp ", "-mcp/", "chrome-devtools",
    ]
    /// Pais que, quando são o pai DIRETO, indicam servidor stdio (MCP) ou ferramenta do agente.
    /// Dev servers iniciados pelo agente passam por um shell (zsh -c), então não caem aqui.
    static let agentHosts: Set<String> = ["claude", "codex", "cursor-agent", "gemini", "opencode", "aider", "goose"]
    static let minAge: TimeInterval = 30

    static func isRuntime(_ name: String) -> Bool {
        if runtimes.contains(name) { return true }
        // python3.12, node22 etc.
        if name.hasPrefix("python3.") { return true }
        return name.hasPrefix("node") && name.count > 4 && name.dropFirst(4).allSatisfy(\.isNumber)
    }

    static func isNoise(_ command: String) -> Bool {
        if noise.contains(where: { command.contains($0) }) { return true }
        // Pacote instalado globalmente (npm -g / mise / nvm), exceto gerenciadores de pacote.
        if let r = command.range(of: "/lib/node_modules/") {
            let pkg = command[r.upperBound...].prefix { $0 != "/" }
            if !["npm", "pnpm", "yarn", "corepack"].contains(String(pkg)) { return true }
        }
        return false
    }

    static func isCandidate(_ p: Proc) -> Bool {
        guard isRuntime(p.execName) else { return false }
        if p.executable.contains(".app/") { return false }
        return !isNoise(p.command)
    }

    /// Raízes de dev: candidatos sem ancestral candidato, sem ruído na cadeia de ancestrais,
    /// fora dos PIDs excluídos (LaunchAgents) e com idade mínima.
    static func roots(procs: ProcTable, excluded: Set<Int32>) -> [Proc] {
        let candidates = procs.byPID.values.filter { isCandidate($0) && !excluded.contains($0.pid) }
        let candidatePIDs = Set(candidates.map(\.pid))
        return candidates.filter { p in
            guard p.elapsed >= minAge else { return false }
            let chain = procs.ancestors(of: p.pid)
            if let parent = chain.first {
                if agentHosts.contains(parent.execName) || parent.command.contains(".app/Contents/") { return false }
            }
            for a in chain {
                // Um `bun run dev` que gera `node vite` vira um item só (o filho tem ancestral candidato).
                if candidatePIDs.contains(a.pid) || excluded.contains(a.pid) { return false }
                if isNoise(a.command) { return false }
            }
            return true
        }
        .sorted { $0.pid < $1.pid }
    }

    struct FDInfo: Sendable {
        var cwd: [Int32: String] = [:]
        var logs: [Int32: [String]] = [:]
    }

    /// cwd e stdout/stderr redirecionados para arquivo, em uma chamada de lsof.
    static func fdInfo(_ pids: [Int32]) async -> FDInfo {
        guard !pids.isEmpty else { return FDInfo() }
        let list = pids.map(String.init).joined(separator: ",")
        let r = await Shell.run("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd,1,2", "-Fpftn"], timeout: 3)
        return parseFD(r.out)
    }

    static func parseFD(_ out: String) -> FDInfo {
        var info = FDInfo()
        var pid: Int32?
        var fd = ""
        var type = ""
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let v = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(v)
            case "f": fd = v; type = ""
            case "t": type = v
            case "n":
                guard let pid else { continue }
                if fd == "cwd" { info.cwd[pid] = v }
                else if (fd == "1" || fd == "2"), type == "REG", v != "/dev/null" {
                    if !(info.logs[pid]?.contains(v) ?? false) { info.logs[pid, default: []].append(v) }
                }
            default: break
            }
        }
        return info
    }

    static func collect(procs: ProcTable, ports: [Int32: Set<Int>], excluded: Set<Int32>) async -> [Item] {
        let r = roots(procs: procs, excluded: excluded)
        let fd = await fdInfo(r.map(\.pid))
        return items(roots: r, procs: procs, ports: ports, fd: fd)
    }

    static func items(roots: [Proc], procs: ProcTable, ports: [Int32: Set<Int>], fd: FDInfo,
                      now: Date = Date(), repoRoot: (String) -> String? = Summarize.repoRoot) -> [Item] {
        var seen: [String: Int] = [:]
        return roots.map { p in
            let cwd = fd.cwd[p.pid]
            let summary = Summarize.command(p.args, cwd: cwd)
            let key = "dev:\(cwd ?? "?")|\(summary)"
            let n = seen[key, default: 0]
            seen[key] = n + 1
            let tree = procs.tree(p.pid)
            var item = Item(
                id: n == 0 ? key : "\(key)#\(n)", key: key, kind: .dev,
                name: Summarize.projectName(cwd: cwd, args: p.args, repoRoot: repoRoot),
                detail: summary, status: .running
            )
            item.pid = p.pid
            item.startedAt = now.addingTimeInterval(-p.elapsed)
            let u = procs.usage(tree)
            item.cpu = u.cpu
            item.memBytes = u.memBytes
            item.ports = Ports.collect(tree, ports)
            item.workingDir = cwd
            item.command = p.command
            item.logPaths = fd.logs[p.pid] ?? []
            return item
        }
    }
}

// MARK: - Resumo de comandos

enum Summarize {
    static func command(_ args: [String], cwd: String?) -> String {
        guard let first = args.first else { return "" }
        var parts = [(first as NSString).lastPathComponent]
        for a in args.dropFirst().prefix(8) { parts.append(shorten(a, cwd: cwd)) }
        if args.count > 9 { parts.append("…") }
        let s = parts.joined(separator: " ")
        return s.count > 96 ? String(s.prefix(95)) + "…" : s
    }

    static func shorten(_ arg: String, cwd: String?) -> String {
        // --flag=/caminho/longo
        if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "=") {
            return String(arg[...eq]) + shorten(String(arg[arg.index(after: eq)...]), cwd: cwd)
        }
        guard arg.hasPrefix("/") else { return arg }
        // Binário de pacote ("…/node_modules/.bin/vite" -> "vite") vem antes do caminho relativo ao cwd.
        if let r = arg.range(of: "/node_modules/.bin/", options: .backwards) {
            return String(arg[r.upperBound...])
        }
        if let cwd, arg.hasPrefix(cwd + "/") { return String(arg.dropFirst(cwd.count + 1)) }
        if let r = arg.range(of: "/node_modules/", options: .backwards) {
            let rest = arg[r.upperBound...]
            let comps = rest.split(separator: "/")
            if let f = comps.first {
                let pkg = f.hasPrefix("@") && comps.count > 1 ? "\(f)/\(comps[1])" : String(f)
                return comps.count > (pkg.contains("/") ? 2 : 1) ? "\(pkg)/…/\(comps.last!)" : pkg
            }
        }
        let short = Fmt.abbreviateHome(arg)
        let comps = short.split(separator: "/")
        if comps.count > 3 { return "…/" + comps.suffix(2).joined(separator: "/") }
        return short
    }

    /// Diretório mais próximo (o próprio ou ancestral, até 6 níveis) com `.git`.
    static func repoRoot(_ dir: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var cur = dir
        for _ in 0..<6 {
            if cur == "/" || cur == home || cur.isEmpty { return nil }
            if fm.fileExists(atPath: (cur as NSString).appendingPathComponent(".git")) { return cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Nome do projeto: raiz do repositório que contém o cwd (monorepo: "dudata-hub", não "backend");
    /// sem repositório, a última pasta do cwd; sem cwd útil, o script.
    static func projectName(cwd: String?, args: [String], repoRoot: (String) -> String? = Summarize.repoRoot) -> String {
        if let cwd, cwd != "/", cwd != NSHomeDirectory() {
            return ((repoRoot(cwd) ?? cwd) as NSString).lastPathComponent
        }
        // Sem cwd útil: usa o script.
        if let script = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0.contains("/") || $0.hasSuffix(".js") || $0.hasSuffix(".ts") || $0.hasSuffix(".py") }) {
            let comps = script.split(separator: "/")
            if let i = comps.lastIndex(of: "node_modules"), i + 1 < comps.count { return String(comps[i + 1]) }
            return (script as NSString).lastPathComponent
        }
        return args.first.map { ($0 as NSString).lastPathComponent } ?? "?"
    }
}
