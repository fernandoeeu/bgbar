import Foundation

/// Resumo acumulado de um transcript JSONL de agente, construído linha a linha.
struct ClaudeTranscriptSummary: Equatable {
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    /// Tokens de contexto do último turno do assistant (input + cache + output), como o Claude Code reporta.
    var contextTokens: Int = 0
    var lastTool: String?
    /// stop_reason da última linha do assistant (nil em blocos intermediários do streaming).
    var lastAssistantStopReason: String?
    /// A última mensagem do assistant é erro de API / sintética de falha.
    var lastAssistantIsError = false
    /// Houve tool_use SubagentHandback sem tool_result de erro.
    var handedBack = false
    /// tool_use ainda sem tool_result.
    var pendingToolIds: Set<String> = []
    /// Tipo da última linha relevante (user/assistant), ignorando attachments e metadados.
    var lastEventType: String?
    var cwd: String?
    var lines = 0

    private var handbackIds: Set<String> = []

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoNoFrac.date(from: s) }

    /// Incorpora uma linha JSON completa.
    mutating func ingest(line: Data) {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        lines += 1
        if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
        if let ts = obj["timestamp"] as? String, let d = Self.parseDate(ts) {
            if firstTimestamp == nil || d < firstTimestamp! { firstTimestamp = d }
            if lastTimestamp == nil || d > lastTimestamp! { lastTimestamp = d }
        }
        let type = obj["type"] as? String
        guard type == "assistant" || type == "user", let msg = obj["message"] as? [String: Any] else { return }
        lastEventType = type
        let content = msg["content"] as? [[String: Any]] ?? []

        if type == "assistant" {
            if let u = msg["usage"] as? [String: Any] {
                let sum = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
                if sum > 0 { contextTokens = sum }
            }
            lastAssistantStopReason = msg["stop_reason"] as? String
            let model = msg["model"] as? String
            let stop = lastAssistantStopReason
            lastAssistantIsError = (obj["isApiErrorMessage"] as? Bool == true)
                || (model == "<synthetic>" && stop != "end_turn" && stop != nil)
                || stop == "refusal"
            for c in content where c["type"] as? String == "tool_use" {
                let name = c["name"] as? String
                if let name { lastTool = name }
                if let id = c["id"] as? String {
                    pendingToolIds.insert(id)
                    if name == "SubagentHandback" { handbackIds.insert(id) }
                }
                if name == "SubagentHandback" { handedBack = true }
            }
        } else {
            for c in content where c["type"] as? String == "tool_result" {
                guard let id = c["tool_use_id"] as? String else { continue }
                pendingToolIds.remove(id)
                if handbackIds.contains(id), c["is_error"] as? Bool == true { handedBack = false }
            }
        }
    }
}

/// Leitor incremental: guarda offset e linha parcial, lê só o que foi acrescentado.
final class ClaudeTranscriptReader {
    let url: URL
    private(set) var offset: UInt64 = 0
    private var partial = Data()
    private(set) var summary = ClaudeTranscriptSummary()
    private var fileID: UInt64?

    init(url: URL) { self.url = url }

    /// Lê os bytes novos. Recomeça do zero se o arquivo encolheu ou foi substituído.
    func update(maxBytes: Int = 64 << 20) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if size < offset || (fileID != nil && inode != fileID) { reset() }
        fileID = inode
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            while offset < size {
                let want = Int(min(UInt64(maxBytes), size - offset, 4 << 20))
                guard let chunk = try h.read(upToCount: want), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                consume(chunk)
            }
        } catch { return }
    }

    /// Exposto para testes: alimenta bytes como se tivessem sido acrescentados ao arquivo.
    func consume(_ chunk: Data) {
        partial.append(chunk)
        var start = partial.startIndex
        while let nl = partial[start...].firstIndex(of: 0x0A) {
            summary.ingest(line: partial[start..<nl])
            start = partial.index(after: nl)
        }
        partial = Data(partial[start...])
    }

    private func reset() {
        offset = 0
        partial = Data()
        summary = ClaudeTranscriptSummary()
    }
}
