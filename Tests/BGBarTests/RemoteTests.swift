import XCTest
@testable import BGBar

// Fixtures sintéticas, no formato real das ferramentas do Linux (sem dados/segredos de máquina).

final class RemoteTests: XCTestCase {
    func testHostValidation() {
        for ok in ["devbox", "user@devbox.example.com", "10.0.0.5", "user@[fe80::1%eth0]", "my_host-2"] {
            XCTAssertTrue(Remote.isValidHost(ok), ok)
        }
        for bad in ["", "-oProxyCommand=evil", "host name", "host;rm", "host$(x)", "a'b"] {
            XCTAssertFalse(Remote.isValidHost(bad), bad)
        }
    }

    func testParseHostname() {
        XCTAssertEqual(Remote.parseHostname("user dev\nhostname devbox.example.com\nport 22\n"), "devbox.example.com")
        XCTAssertNil(Remote.parseHostname(""))
    }

    func testParsePorts() {
        let out = """
        LISTEN 0      4096        127.0.0.54:53    0.0.0.0:*
        LISTEN 0      511          127.0.0.1:3000  0.0.0.0:* users:(("node",pid=120,fd=22))
        LISTEN 0      511                  *:8080        *:* users:(("bun",pid=200,fd=10),("bun",pid=201,fd=10))
        LISTEN 0      128               [::]:5173     [::]:* users:(("node",pid=120,fd=30))
        """
        let map = Remote.parsePorts(out)
        XCTAssertEqual(map[120], [3000, 5173])
        XCTAssertEqual(map[200], [8080])
        XCTAssertEqual(map[201], [8080])
        XCTAssertEqual(map.count, 3)
    }

    func testParseProcLinks() {
        let out = "/proc/1/cwd\t\n"
            + "/proc/120/cwd\t/home/u/app\n"
            + "/proc/120/fd/1\t/home/u/app/out.log\n"
            + "/proc/120/fd/2\t/home/u/app/out.log\n"
            + "/proc/200/cwd\t/srv/api\n"
            + "/proc/200/fd/1\t/dev/pts/0\n"
            + "/proc/200/fd/2\tpipe:[1234]\n"
            + "/proc/201/fd/1\t/tmp/old.log (deleted)\n"
        let info = Remote.parseProcLinks(out)
        XCTAssertEqual(info.cwd, [120: "/home/u/app", 200: "/srv/api"])
        XCTAssertEqual(info.logs, [120: ["/home/u/app/out.log"]])
    }

    func testExecArgs() {
        let raw = "{ path=/usr/bin/bun ; argv[]=/usr/bin/bun src/main.ts --port 3000 ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; status=0/0 }"
        XCTAssertEqual(Remote.execArgs(raw), ["/usr/bin/bun", "src/main.ts", "--port", "3000"])
        XCTAssertEqual(Remote.execArgs(nil), [])
        XCTAssertEqual(Remote.execArgs(""), [])
    }

    private static let output = """
    @@bgbar:ps
        100       1    01:00:00  1.0  1000 /usr/lib/systemd/systemd --user
        120     100       10:00  2.5 20480 /usr/bin/bun src/main.ts
        121     120       09:00  0.5 10240 /usr/bin/node worker.js
        200       1       05:00  3.0 30720 node /home/u/site/node_modules/.bin/vite
        300       1       00:10  0.0  1024 node too-young.js
    @@bgbar:ports
    LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("bun",pid=120,fd=22))
    LISTEN 0 511 *:5173 *:* users:(("node",pid=200,fd=22))
    @@bgbar:fd
    /proc/200/cwd\t/home/u/site
    /proc/200/fd/1\t/home/u/site/dev.log
    @@bgbar:units
    Id=api.service
    LoadState=loaded
    ActiveState=active
    SubState=running
    FragmentPath=/home/u/.config/systemd/user/api.service
    MainPID=120
    ExecMainStatus=0
    ExecStart={ path=/usr/bin/bun ; argv[]=/usr/bin/bun src/main.ts ; ignore_errors=no }
    WorkingDirectory=/home/u/api

    Id=job.service
    LoadState=loaded
    ActiveState=failed
    SubState=failed
    MainPID=0
    ExecMainStatus=2
    ExecStart={ path=/home/u/job.sh ; argv[]=/home/u/job.sh ; ignore_errors=no }
    WorkingDirectory=!/home/u

    Id=idle.service
    LoadState=loaded
    ActiveState=inactive
    SubState=dead
    MainPID=0
    ExecMainStatus=0

    Id=ghost.service
    LoadState=not-found
    ActiveState=inactive
    @@bgbar:docker
    {"ID":"abc123","Names":"web","Image":"nginx:1","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp","Labels":"com.docker.compose.project=stack"}
    {"ID":"def456","Names":"old","Image":"busybox","State":"exited","Status":"Exited (1) 3 days ago","Ports":"","Labels":""}
    @@bgbar:inspect
    abc123 2026-01-01T10:00:00.5Z
    @@bgbar:stats
    web\t1.50%\t64MiB / 8GiB
    @@bgbar:end

    """

    func testParseFullOutput() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let items = try XCTUnwrap(Remote.parse(Self.output, host: "devbox", now: now))
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertTrue(items.allSatisfy { $0.host == "devbox" && $0.id.hasPrefix("ssh:devbox|") && $0.key.hasPrefix("ssh:devbox|") })

        let api = try XCTUnwrap(byID["ssh:devbox|agent:api.service"])
        XCTAssertEqual(api.kind, .agent)
        XCTAssertEqual(api.name, "api")
        XCTAssertEqual(api.status, .running)
        XCTAssertEqual(api.pid, 120)
        XCTAssertEqual(api.detail, "bun src/main.ts")
        XCTAssertEqual(api.ports, [3000])
        XCTAssertEqual(api.cpu, 3.0) // serviço + filho
        XCTAssertEqual(api.memBytes, (20480 + 10240) * 1024)
        XCTAssertEqual(api.startedAt, now.addingTimeInterval(-600))
        XCTAssertEqual(api.workingDir, "/home/u/api")
        XCTAssertEqual(api.kindTitle, "systemd")

        let job = try XCTUnwrap(byID["ssh:devbox|agent:job.service"])
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.exitCode, 2)
        XCTAssertEqual(job.workingDir, "/home/u")
        XCTAssertNil(job.pid)
        XCTAssertEqual(byID["ssh:devbox|agent:idle.service"]?.status, .stopped)
        XCTAssertNil(byID["ssh:devbox|agent:ghost.service"])

        let web = try XCTUnwrap(byID["ssh:devbox|docker:web"])
        XCTAssertEqual(web.status, .running)
        XCTAssertEqual(web.ports, [8080])
        XCTAssertEqual(web.cpu, 1.5)
        XCTAssertEqual(web.memBytes, 64 * 1_048_576)
        XCTAssertEqual(web.group, "stack")
        XCTAssertNotNil(web.startedAt)
        let old = try XCTUnwrap(byID["ssh:devbox|docker:old"])
        XCTAssertEqual(old.status, .failed)
        XCTAssertNil(old.cpu)

        // Dev: só o vite (os do serviço e o processo novo demais ficam de fora).
        let dev = items.filter { $0.kind == .dev }
        XCTAssertEqual(dev.count, 1)
        XCTAssertEqual(dev[0].pid, 200)
        XCTAssertEqual(dev[0].name, "site")
        XCTAssertEqual(dev[0].detail, "node vite")
        XCTAssertEqual(dev[0].ports, [5173])
        XCTAssertEqual(dev[0].logPaths, ["/home/u/site/dev.log"])
    }

    func testTruncatedOutputIsFailure() {
        let cut = Self.output.replacingOccurrences(of: "@@bgbar:end\n", with: "")
        XCTAssertNil(Remote.parse(cut, host: "devbox"))
        XCTAssertNil(Remote.parse("", host: "devbox"))
    }

    func testNoDockerAndNoUnits() throws {
        let out = "@@bgbar:ps\n@@bgbar:ports\n@@bgbar:fd\n@@bgbar:units\n@@bgbar:end\n"
        XCTAssertEqual(try XCTUnwrap(Remote.parse(out, host: "devbox")).count, 0)
    }

    func testContainerProcessesAreNotDev() throws {
        let out = """
        @@bgbar:ps
        51 50 01:00:00 1.0 100 node /app/server.js
        52 51 01:00:00 1.0 100 node /app/worker.js
        60 1 01:00:00 1.0 100 node /home/u/real.js
        @@bgbar:allps
        50 1 01:00:00 0.0 100 containerd-shim
        51 50 01:00:00 1.0 100 node
        52 51 01:00:00 1.0 100 node
        60 1 01:00:00 1.0 100 node
        @@bgbar:end

        """
        XCTAssertEqual(try XCTUnwrap(Remote.parse(out, host: "devbox")).map(\.pid), [60])
    }

    func testActionScripts() {
        var unit = Item(id: "x", key: "x", kind: .agent, name: "api", detail: "", status: .running)
        unit.label = "api.service"
        unit.host = "devbox"
        XCTAssertEqual(Remote.actionScript(.restart, unit), "systemctl --user restart 'api.service'\n")
        XCTAssertEqual(Remote.actionScript(.stop, unit), "systemctl --user stop 'api.service'\n")
        XCTAssertEqual(Remote.logScript(unit, lines: 50), "journalctl --user -u 'api.service' -n 50 --no-pager -o short 2>&1\n")

        var box = Item(id: "y", key: "y", kind: .docker, name: "web", detail: "", status: .stopped)
        box.containerID = "abc123"
        XCTAssertEqual(Remote.actionScript(.start, box), "docker start 'abc123'\n")
        XCTAssertEqual(Remote.logScript(box, lines: 10), "docker logs --tail 10 'abc123' 2>&1\n")

        let now = Date()
        var dev = Item(id: "z", key: "z", kind: .dev, name: "site", detail: "", status: .running)
        XCTAssertNil(Remote.actionScript(.kill(force: false), dev)) // sem PID
        XCTAssertNil(Remote.actionScript(.stop, dev))
        XCTAssertNil(Remote.logScript(dev, lines: 10))
        dev.pid = 200
        dev.startedAt = now.addingTimeInterval(-300)
        dev.logPaths = ["/home/u/it's.log"]
        let kill = Remote.actionScript(.kill(force: true), dev, now: now) ?? ""
        XCTAssertTrue(kill.contains("ps -o etimes= -p 200"))
        XCTAssertTrue(kill.contains("d=$((e - 300))"))
        XCTAssertTrue(kill.hasSuffix("kill -KILL 200\n"))
        XCTAssertEqual(Remote.logScript(dev, lines: 5), "tail -n 5 '/home/u/it'\\''s.log' 2>&1\n")
    }

    /// Coleta real por ssh (somente leitura). Só roda com BGBAR_SSH_HOST=<destino>.
    func testLiveCollect() async throws {
        let host = ProcessInfo.processInfo.environment["BGBAR_SSH_HOST"] ?? ""
        try XCTSkipIf(host.isEmpty, "defina BGBAR_SSH_HOST=<destino ssh>")
        let t0 = Date()
        let r = await Remote.collect(host)
        print("ciclo ssh: \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms erro=\(r.error ?? "-") hostname=\(await Remote.hostname(host) ?? "-")")
        let items = try XCTUnwrap(r.items)
        for i in items where i.kind != .docker || i.status != .stopped {
            print("\(i.kind) \(i.status) \(i.name) | \(i.detail) | pid=\(i.pid.map(String.init) ?? "-") ports=\(i.ports) cpu=\(i.cpu ?? -1) mem=\((i.memBytes ?? 0) / 1_048_576)MB logs=\(i.logPaths.count) up=\(Int(i.uptime ?? 0))s note=\(i.statusNote ?? "")")
        }
    }
}
