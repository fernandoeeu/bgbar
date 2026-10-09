import XCTest
@testable import BGBar

/// Execução contra a máquina real (somente leitura). Só roda com BGBAR_LIVE=1.
final class LiveDumpTests: XCTestCase {
    func testDumpLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BGBAR_LIVE"] == "1", "defina BGBAR_LIVE=1")
        let t0 = Date()
        async let procsT = ProcTable.load()
        async let portsT = Ports.load()
        async let dockerT = Docker.collect()
        let procs = await procsT, ports = await portsT
        let agents = await LaunchAgents.collect(procs: procs, ports: ports)
        let owned = LaunchAgents.ownedPIDs(agents, procs: procs)
        let dev = await DevProcs.collect(procs: procs, ports: ports, excluded: owned)
        let docker = await dockerT
        print("ciclo: \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms, procs=\(procs.byPID.count)")
        for i in agents { print("AGENT \(i.status) \(i.name) | \(i.detail) | group=\(i.group ?? "-") pid=\(i.pid.map(String.init) ?? "-") ports=\(i.ports) note=\(i.statusNote ?? "")") }
        for i in docker ?? [] where i.status != .stopped { print("DOCKER \(i.status) \(i.name) | ports=\(i.ports) started=\(i.startedAt.map { "\($0)" } ?? "-")") }
        print("DOCKER total=\(docker?.count ?? -1)")
        for i in dev { print("DEV \(i.name) | \(i.detail) | pid=\(i.pid!) ports=\(i.ports) cpu=\(i.cpu!) mem=\(i.memBytes! / 1_048_576)MB logs=\(i.logPaths.count) up=\(Int(i.uptime ?? 0))s") }
    }
}
