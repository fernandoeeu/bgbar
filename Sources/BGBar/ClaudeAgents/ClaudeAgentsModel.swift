import Foundation
import CoreServices

// Contrato público da seção "Agentes Claude" (usado pela UI). Não mude nomes/tipos.

enum ClaudeAgentState: String { case running, done, failed }

struct ClaudeAgentNode: Identifiable, Hashable {
    let id: String            // agentId
    let parentId: String?     // nil = filho da sessão
    let description: String
    let agentType: String
    let depth: Int
    let state: ClaudeAgentState
    let startedAt: Date
    let lastActivityAt: Date
    /// Tokens de contexto do último turno (input + cache creation + cache read + output), como o Claude Code mostra.
    let totalTokens: Int
    let lastTool: String?
    let transcriptURL: URL
    var children: [ClaudeAgentNode]
}

struct ClaudeSession: Identifiable, Hashable {
    let id: String            // sessionId
    let projectName: String   // último componente do cwd
    let lastActivityAt: Date
    let agents: [ClaudeAgentNode] // raízes, com children preenchidos
}

@MainActor
final class ClaudeAgentsStore: ObservableObject {
    static let shared = ClaudeAgentsStore()

    @Published private(set) var sessions: [ClaudeSession] = []

    var runningCount: Int {
        func count(_ nodes: [ClaudeAgentNode]) -> Int {
            nodes.reduce(0) { $0 + ($1.state == .running ? 1 : 0) + count($1.children) }
        }
        return sessions.reduce(0) { $0 + count($1.agents) }
    }

    private let engine: ClaudeAgentsEngine

    init(root: URL = ClaudeAgentsScanner.defaultRoot) {
        engine = ClaudeAgentsEngine(root: root)
    }

    /// Idempotente.
    func start() {
        engine.start { [weak self] sessions in
            Task { @MainActor in
                guard let self, self.sessions != sessions else { return }
                self.sessions = sessions
            }
        }
    }

    func stop() { engine.stop() }
}

/// Parte fora da main thread: fila serial, FSEvents em ~/.claude/projects e polling de 2 s.
final class ClaudeAgentsEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bgbar.claude-agents", qos: .utility)
    private let scanner: ClaudeAgentsScanner
    private let root: URL
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var publish: (([ClaudeSession]) -> Void)?
    private var scanScheduled = false
    private var running = false

    init(root: URL) {
        self.root = root
        scanner = ClaudeAgentsScanner(root: root)
    }

    func start(publish: @escaping ([ClaudeSession]) -> Void) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.publish = publish
            startTimer()
            startFSEvents()
            scanNow()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            timer?.cancel(); timer = nil
            if let s = stream {
                FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
                stream = nil
            }
            publish = nil
        }
    }

    // Executa na fila.
    private func scanNow() {
        scanScheduled = false
        guard running else { return }
        let sessions = scanner.scan()
        publish?(sessions)
    }

    /// Agrupa rajadas de eventos (o jsonl recebe várias escritas por segundo).
    private func scheduleScan(after delay: TimeInterval = 0.25) {
        guard running, !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scanNow() }
    }

    private func startTimer() {
        // Polling de 2 s: fallback do FSEvents e avanço dos estados por tempo (limiar de 90 s).
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.scheduleScan(after: 0) }
        t.resume()
        timer = t
    }

    private func startFSEvents() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ClaudeAgentsEngine>.fromOpaque(info).takeUnretainedValue().scheduleScan()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
