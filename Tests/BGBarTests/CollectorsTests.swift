import XCTest
@testable import BGBar

// Fixtures sintéticas, no formato real das ferramentas (sem dados/segredos da máquina).

final class ProcTableTests: XCTestCase {
    func testEtime() {
        XCTAssertEqual(ProcTable.parseEtime("00:05"), 5)
        XCTAssertEqual(ProcTable.parseEtime("07:31"), 451)
        XCTAssertEqual(ProcTable.parseEtime("22:28:44"), 80924)
        let expected: TimeInterval = 8 * 86400 + 21 * 3600 + 49 * 60 + 48
        XCTAssertEqual(ProcTable.parseEtime("08-21:49:48"), expected)
        XCTAssertEqual(ProcTable.parseEtime("  01:00 "), 60)
    }

    func testParseKeepsCommandWithSpaces() {
        let out = """
          353     1    22:28:44   0.0  92256 /Applications/Some App.app/Contents/MacOS/Some App --flag
        45649     1       07:31   1.5  29744 /Users/u/.bun/bin/bun run scripts/llm-bridge.ts
        garbage line
        """
        let t = ProcTable.parse(out)
        XCTAssertEqual(t.byPID.count, 2)
        let p = t.byPID[45649]!
        XCTAssertEqual(p.ppid, 1)
        XCTAssertEqual(p.elapsed, 451)
        XCTAssertEqual(p.cpu, 1.5)
        XCTAssertEqual(p.rssKB, 29744)
        XCTAssertEqual(p.command, "/Users/u/.bun/bin/bun run scripts/llm-bridge.ts")
        XCTAssertEqual(p.execName, "bun")
        XCTAssertEqual(t.byPID[353]!.command, "/Applications/Some App.app/Contents/MacOS/Some App --flag")
        XCTAssertEqual(t.children[1]?.sorted(), [353, 45649])
    }

    func testTreeAndUsage() {
        let t = ProcTable.parse("""
        10 1 01:00 1.0 100 bun run dev
        11 10 01:00 2.0 200 node vite
        12 11 01:00 0.5 50 esbuild --service
        13 1 01:00 9.0 999 other
        """)
        XCTAssertEqual(Set(t.tree(10)), [10, 11, 12])
        let u = t.usage(t.tree(10))
        XCTAssertEqual(u.cpu, 3.5, accuracy: 0.001)
        XCTAssertEqual(u.memBytes, 350 * 1024)
        XCTAssertEqual(t.ancestors(of: 12).map(\.pid), [11, 10])
    }
}

final class PortsTests: XCTestCase {
    func testParseLsof() {
        let out = """
        p826
        f14
        n*:64370
        f15
        n*:64370
        p2870
        f18
        n127.0.0.1:6736
        p900
        f3
        n[::1]:5432
        f4
        n127.0.0.1:5432
        """
        let m = Ports.parse(out)
        XCTAssertEqual(m[826], [64370])
        XCTAssertEqual(m[2870], [6736])
        XCTAssertEqual(m[900], [5432])
        XCTAssertEqual(Ports.collect([826, 900, 1], m), [5432, 64370])
    }
}

final class LaunchAgentsTests: XCTestCase {
    // Estrutura real do `launchctl print` (tabs), com o bloco de environment sintético.
    static let running = """
    gui/501/com.example.bridge = {
    \tactive count = 1
    \tpath = /Users/u/Library/LaunchAgents/com.example.bridge.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /Users/u/.bun/bin/bun
    \targuments = {
    \t\t/Users/u/.bun/bin/bun
    \t\trun
    \t\tscripts/llm-bridge.ts
    \t}

    \tworking directory = /Users/u/code/polybot

    \tenvironment = {
    \t\tFOO = bar
    \t\tstate = fake-nested
    \t}

    \tdomain = gui/501 [100015]
    \truns = 1
    \tpid = 45649
    \timmediate reason = speculative
    \tlast exit code = (never exited)

    \tresource coalition = {
    \t\tID = 95963
    \t\ttype = resource
    \t\tstate = active
    \t\tactive count = 1
    \t}
    \tproperties = keepalive | runatload | inferred program
    }
    """

    func testParseRunningIgnoresNested() {
        let s = LaunchAgents.parsePrint(Self.running)
        XCTAssertTrue(s.loaded)
        XCTAssertEqual(s.state, "running")
        XCTAssertEqual(s.pid, 45649)
        XCTAssertNil(s.lastExit)
        XCTAssertEqual(s.lastExitText, "(never exited)")
    }

    func testParseSpawnScheduledAndExitCodes() {
        let out = """
        gui/501/com.example.x = {
        \tstate = spawn scheduled
        \truns = 7
        \tlast exit code = 78: EX_CONFIG
        \tjetsam coalition = {
        \t\tstate = active
        \t}
        }
        """
        let s = LaunchAgents.parsePrint(out)
        XCTAssertEqual(s.state, "spawn scheduled")
        XCTAssertNil(s.pid)
        XCTAssertEqual(s.lastExit, 78)
        XCTAssertEqual(s.lastExitText, "78: EX_CONFIG")

        let sig = LaunchAgents.parsePrint("x = {\n\tstate = not running\n\tlast terminating signal = Killed: 9\n}")
        XCTAssertEqual(sig.lastSignal, "Killed: 9")
        XCTAssertNil(sig.lastExit)
    }

    func testParseList() {
        let out = "PID\tStatus\tLabel\n2854\t0\tcom.example.keepawake\n-\t78\tcom.example.broken\n-\t-9\tcom.apple.x\n"
        XCTAssertEqual(LaunchAgents.parseList(out), ["com.example.keepawake", "com.example.broken", "com.apple.x"])
        let e = LaunchAgents.parseListEntries(out)
        XCTAssertEqual(e["com.example.keepawake"], .init(pid: 2854, status: 0))
        XCTAssertEqual(e["com.example.broken"], .init(pid: nil, status: 78))
        // `print` falhou mas o serviço está carregado: não pode virar "não carregado".
        let up = LaunchAgents.fallbackState(e["com.example.keepawake"]!)
        XCTAssertTrue(up.loaded); XCTAssertEqual(up.pid, 2854)
        let broken = LaunchAgents.fallbackState(e["com.example.broken"]!)
        XCTAssertEqual(broken.lastExit, 78)
        XCTAssertEqual(LaunchAgents.fallbackState(e["com.apple.x"]!).lastSignal, "sinal 9")
    }

    private let info = LaunchAgents.Info(
        label: "com.example.polybot.bridge", plistPath: "/p.plist",
        program: ["/Users/u/.bun/bin/bun", "run", "scripts/llm-bridge.ts"],
        logPaths: ["/tmp/bridge.log"], workingDir: "/Users/u/code/polybot")

    func testItemStates() {
        let procs = ProcTable.parse("""
        45649 1 07:31 1.0 1000 /Users/u/.bun/bin/bun run scripts/llm-bridge.ts
        45650 45649 07:30 2.0 500 node child.js
        """)
        let ports: [Int32: Set<Int>] = [45650: [8787]]
        let now = Date(timeIntervalSince1970: 1_000_000)

        let running = LaunchAgents.item(info: info, state: LaunchAgents.parsePrint(Self.running), procs: procs, ports: ports, now: now)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.name, "example.polybot.bridge")
        XCTAssertEqual(running.detail, "bun run scripts/llm-bridge.ts")
        XCTAssertEqual(running.group, "polybot")
        XCTAssertEqual(running.ports, [8787])
        XCTAssertEqual(running.cpu!, 3.0, accuracy: 0.001)
        XCTAssertEqual(running.memBytes, 1500 * 1024)
        XCTAssertEqual(running.startedAt, now.addingTimeInterval(-451))
        XCTAssertEqual(LaunchAgents.ownedPIDs([running], procs: procs), [45649, 45650])

        let notLoaded = LaunchAgents.item(info: info, state: .init(), procs: procs, ports: ports)
        XCTAssertEqual(notLoaded.status, .notLoaded)

        var st = LaunchAgents.State(loaded: true, state: "spawn scheduled", lastExit: 1, lastExitText: "1")
        XCTAssertEqual(LaunchAgents.item(info: info, state: st, procs: procs, ports: ports).status, .restarting)
        st.state = "not running"
        XCTAssertEqual(LaunchAgents.item(info: info, state: st, procs: procs, ports: ports).status, .failed)
        st.lastExit = 0; st.lastExitText = "0"
        XCTAssertEqual(LaunchAgents.item(info: info, state: st, procs: procs, ports: ports).status, .stopped)
        let never = LaunchAgents.State(loaded: true, state: "not running", lastExitText: "(never exited)")
        XCTAssertEqual(LaunchAgents.item(info: info, state: never, procs: procs, ports: ports).status, .stopped)
        let killed = LaunchAgents.State(loaded: true, state: "not running", lastSignal: "Killed: 9")
        XCTAssertEqual(LaunchAgents.item(info: info, state: killed, procs: procs, ports: ports).status, .failed)
    }

    func testParsePlist() throws {
        let dict: [String: Any] = [
            "Label": "com.example.a", "ProgramArguments": ["/bin/echo", "hi"],
            "StandardOutPath": "/tmp/a.log", "StandardErrorPath": "/tmp/a.log", "WorkingDirectory": "/tmp",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let i = try XCTUnwrap(LaunchAgents.parsePlist(data, path: "/x.plist"))
        XCTAssertEqual(i.program, ["/bin/echo", "hi"])
        XCTAssertEqual(i.logPaths, ["/tmp/a.log"])
        XCTAssertEqual(i.workingDir, "/tmp")
        XCTAssertNil(LaunchAgents.parsePlist(Data("nope".utf8), path: "/y"))
    }

    func testDisplayName() {
        XCTAssertEqual(LaunchAgents.displayName("com.fernandoeeu.polybot.llm-bridge"), "fernandoeeu.polybot.llm-bridge")
        XCTAssertEqual(LaunchAgents.displayName("com.foo"), "com.foo")
    }
}

final class DockerTests: XCTestCase {
    static let ps = """
    {"Command":"\\"docker-entrypoint.sh bun\\"","CreatedAt":"2026-10-09 13:48:50 -0300 -03","ID":"aaa111","Image":"app-web","Labels":"com.docker.compose.project=app,com.docker.compose.depends_on=db:service_started:false,redis:service_started:false,com.docker.compose.project.working_dir=/Users/u/code/app","LocalVolumes":"0","Mounts":"","Names":"app-web-1","Networks":"app_default","Platform":{"architecture":"arm64","os":"linux"},"Ports":"0.0.0.0:4040->3000/tcp, [::]:4040->3000/tcp","RunningFor":"7 minutes ago","Size":"0B","State":"running","Status":"Up 6 minutes (healthy)"}
    {"ID":"bbb222","Image":"postgres:16","Labels":"","Names":"pg,alias-pg","Ports":"","State":"exited","Status":"Exited (137) 7 weeks ago"}
    {"ID":"ccc333","Image":"caddy","Labels":"","Names":"proxy","Ports":"","State":"exited","Status":"Exited (0) 2 days ago"}
    {"ID":"ddd444","Image":"api","Labels":"","Names":"api","Ports":"127.0.0.1:8000-8002->8000-8002/tcp","State":"running","Status":"Up 5 seconds (health: starting)"}
    {"ID":"eee555","Image":"api","Labels":"","Names":"sick","Ports":"","State":"running","Status":"Up 2 hours (unhealthy)"}
    {"ID":"fff666","Image":"api","Labels":"","Names":"loop","Ports":"","State":"restarting","Status":"Restarting (1) 3 seconds ago"}
    not json
    """

    func testParseRowsAndItems() {
        let rows = Docker.parseRows(Self.ps)
        XCTAssertEqual(rows.count, 6)
        let items = Dictionary(uniqueKeysWithValues: rows.map { r in
            let i = Docker.item(r, startedAt: nil)
            return (i.name, i)
        })
        let web = items["app-web-1"]!
        XCTAssertEqual(web.status, .running)
        XCTAssertEqual(web.ports, [4040])
        XCTAssertEqual(web.group, "app")
        XCTAssertEqual(web.workingDir, "/Users/u/code/app")
        XCTAssertEqual(web.containerID, "aaa111")

        let pg = items["pg"]!
        XCTAssertEqual(pg.id, "docker:pg")
        XCTAssertEqual(pg.status, .failed)
        XCTAssertEqual(pg.exitCode, 137)
        XCTAssertEqual(pg.ports, [])

        XCTAssertEqual(items["proxy"]!.status, .stopped)
        XCTAssertEqual(items["proxy"]!.exitCode, 0)
        XCTAssertEqual(items["api"]!.status, .starting)
        XCTAssertEqual(items["api"]!.ports, [8000, 8001, 8002])
        XCTAssertEqual(items["sick"]!.status, .unhealthy)
        XCTAssertEqual(items["loop"]!.status, .restarting)
    }

    func testStartedAtNanoseconds() throws {
        let m = Docker.parseInspect("""
        aaa111 2026-10-09T16:48:51.30345183Z
        bbb222 0001-01-01T00:00:00Z
        ccc333 2026-10-09T16:48:51Z
        ddd444 2026-10-09T13:48:51.5-03:00
        """)
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-09T16:48:51Z"))
        XCTAssertEqual(m["aaa111"]!.timeIntervalSince(base), 0.30345183, accuracy: 1e-6)
        XCTAssertNil(m["bbb222"])
        XCTAssertEqual(m["ccc333"], base)
        XCTAssertEqual(m["ddd444"]!.timeIntervalSince(base), 0.5, accuracy: 1e-6)
    }

    func testStats() {
        let s = Docker.parseStats("app-web-1\t0.92%\t139.1MiB / 11.73GiB\nx\t--\t0B / 0B\nbad line\n")
        XCTAssertEqual(s["app-web-1"]!.cpu, 0.92, accuracy: 1e-9)
        XCTAssertEqual(s["app-web-1"]!.mem, UInt64(139.1 * 1_048_576))
        XCTAssertEqual(s["x"], Docker.Stat(cpu: 0, mem: 0))
        XCTAssertEqual(s.count, 2)
    }

    func testHelpers() {
        XCTAssertEqual(Docker.exitCode("Exited (137) 7 weeks ago"), 137)
        XCTAssertNil(Docker.exitCode("Up 3 minutes"))
        XCTAssertEqual(Docker.parseSize("1.5GiB"), 1_610_612_736)
        XCTAssertEqual(Docker.parseSize("512kB"), 512_000)
        XCTAssertEqual(Docker.labels("a=1,b=x=y,c=")["b"], "x=y")
        XCTAssertEqual(Docker.labels("a=1,b=x=y,c=")["c"], "")
        XCTAssertEqual(Docker.hostPorts(""), [])
        XCTAssertEqual(Docker.hostPorts("5432/tcp"), [])
    }
}

final class DevProcsTests: XCTestCase {
    // Árvore sintética imitando o que aparece numa máquina de dev.
    static let ps = """
        1     0 10-00:00:00   0.0   1000 /sbin/launchd
      500     1 01:00:00   0.0   1000 /Applications/Ghostty.app/Contents/MacOS/ghostty
      501   500 01:00:00   0.0   1000 -zsh
      510   501 01:00:00   0.1    700 bun run dev
      511   510 01:00:00   2.0  40000 node /Users/u/code/web/node_modules/.bin/vite dev
      512   511 01:00:00   1.0  10000 /Users/u/code/web/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.21.5
      520   501 00:00:10   0.0    700 bun dev
      530     1 07:31   0.0  29744 /Users/u/.bun/bin/bun run scripts/llm-bridge.ts
      540     1 02-00:00:00   0.0   5000 node /Users/u/.local/share/mise/installs/node/24/lib/node_modules/chrome-devtools-axi/dist/bin/bridge.js
      541   540 02-00:00:00   0.0   5000 npm exec chrome-devtools-mcp@latest
      542   541 02-00:00:00   0.0   5000 node /Users/u/.npm/_npx/abc/node_modules/.bin/chrome-devtools-mcp
      543   542 02-00:00:00   0.0   5000 /Users/u/.local/share/mise/installs/node/24/bin/node /Users/u/.npm/_npx/abc/node_modules/chrome-devtools-mcp/build/watchdog/main.js
      550     1 01:00:00   0.0   5000 npm exec grill-board
      551   550 01:00:00   0.0   5000 node /Users/u/.npm/_npx/def/node_modules/.bin/grill-board
      560   501 01:00:00   5.0 400000 claude
      561   560 01:00:00   0.0  12000 /Users/u/.local/share/codex-cu-engine/cua_node/bin/node /x/cua-repl.mjs
      562   560 01:00:00   0.0  12000 bun /Users/u/code/my-mcp/server.ts
      563   560 01:00:00   0.0   1000 /bin/zsh -c source /Users/u/.claude/shell-snapshots/s.sh && bun run dev
      564   563 01:00:00   0.0  20000 bun run dev
      570     1 01:00:00   0.0  40000 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node ./server.mjs
      571   570 01:00:00   0.0  40000 node helper.js
      580   501 01:00:00   0.0  40000 /Applications/Foo.app/Contents/Resources/node/bin/node script.js
      590   501 01:00:00   0.0   5000 python3.12 -m http.server 8000
      600   501 01:00:00   0.0   5000 npm run start
      601   600 01:00:00   0.0   5000 node server.js
    """

    func testRootsFilter() {
        let procs = ProcTable.parse(Self.ps)
        // 530 pertence a um LaunchAgent.
        let roots = DevProcs.roots(procs: procs, excluded: [530])
        XCTAssertEqual(roots.map(\.pid), [510, 564, 590, 600])
    }

    func testItemsAggregateTree() {
        let procs = ProcTable.parse(Self.ps)
        let roots = DevProcs.roots(procs: procs, excluded: [530])
        let fd = DevProcs.parseFD("""
        p510
        fcwd
        tDIR
        n/Users/u/code/web/apps/site
        f1
        tCHR
        n/dev/ttys005
        p564
        fcwd
        tDIR
        n/Users/u/code/web/apps/site
        f1
        tREG
        n/tmp/dev.log
        f2
        tREG
        n/tmp/dev.log
        p590
        fcwd
        tDIR
        n/Users/u/code/py
        f1
        tREG
        n/dev/null
        """)
        let ports: [Int32: Set<Int>] = [511: [5173], 512: [9999], 590: [8000]]
        let items = DevProcs.items(roots: roots, procs: procs, ports: ports, fd: fd,
                                   repoRoot: { $0.hasPrefix("/Users/u/code/web") ? "/Users/u/code/web" : nil })
        XCTAssertEqual(items.count, 4)
        let web = items[0]
        XCTAssertEqual(web.pid, 510)
        XCTAssertEqual(web.name, "web")
        XCTAssertEqual(web.detail, "bun run dev")
        XCTAssertEqual(web.ports, [5173, 9999])
        XCTAssertEqual(web.cpu!, 3.1, accuracy: 0.001)
        XCTAssertEqual(web.memBytes, (700 + 40000 + 10000) * 1024)
        XCTAssertEqual(web.logPaths, [])
        // Mesmo cwd + mesmo comando: chave igual, id desambiguado.
        XCTAssertEqual(items[1].key, web.key)
        XCTAssertEqual(items[1].id, web.key + "#1")
        XCTAssertEqual(items[1].logPaths, ["/tmp/dev.log"])
        XCTAssertEqual(items[2].name, "py")
        XCTAssertEqual(items[2].logPaths, [])
        XCTAssertEqual(items[3].name, "npm")
    }

    func testSummaryAndProjectName() {
        let args = ["/Users/u/.bun/bin/bun", "run", "scripts/llm-bridge.ts"]
        XCTAssertEqual(Summarize.command(args, cwd: "/Users/u/code/polybot"), "bun run scripts/llm-bridge.ts")
        XCTAssertEqual(Summarize.projectName(cwd: "/Users/u/code/polybot", args: args, repoRoot: { _ in nil }), "polybot")
        XCTAssertEqual(Summarize.projectName(cwd: "/r/mono/packages/backend", args: [], repoRoot: { _ in "/r/mono" }), "mono")
        XCTAssertEqual(Summarize.command(["node", "/Users/u/code/web/node_modules/.bin/vite", "dev"], cwd: nil), "node vite dev")
        XCTAssertEqual(Summarize.command(["node", "/r/app/node_modules/.bin/convex", "dev"], cwd: "/r/app"), "node convex dev")
        XCTAssertEqual(Summarize.command(["bun", "/Users/u/code/x/test/fake.ts"], cwd: "/Users/u/code/x"), "bun test/fake.ts")
        XCTAssertEqual(Summarize.shorten("--env-file=/Users/u/code/x/.env", cwd: "/Users/u/code/x"), "--env-file=.env")
    }

    func testRuntimeAndNoise() {
        XCTAssertTrue(DevProcs.isRuntime("python3.12"))
        XCTAssertTrue(DevProcs.isRuntime("node22"))
        XCTAssertFalse(DevProcs.isRuntime("nodemon-helper"))
        XCTAssertFalse(DevProcs.isRuntime("node_repl"))
        XCTAssertTrue(DevProcs.isNoise("node /usr/local/lib/node_modules/some-cli/bin.js"))
        XCTAssertFalse(DevProcs.isNoise("node /usr/local/lib/node_modules/npm/bin/npm-cli.js run dev"))
        XCTAssertFalse(DevProcs.isNoise("node /Users/u/code/web/node_modules/.bin/vite"))
    }
}
