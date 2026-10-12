import Foundation
import SwiftUI

// MARK: - 采集脚本（POSIX sh，兼容 Ubuntu / Debian / Alpine / LXC）

enum StatsScript {
    static let body = #"""
export LC_ALL=C
echo "HOST=$(hostname 2>/dev/null)"
echo "OS=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
echo "KERNEL=$(uname -r)"
echo "UPTIME=$(cut -d. -f1 /proc/uptime)"
echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "CPUS=$(grep -c '^processor' /proc/cpuinfo)"
echo "PROCS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"
echo "T1=$(cut -d' ' -f1 /proc/uptime)"
echo "STAT1=$(head -n 1 /proc/stat)"
echo "NET1_BEGIN"
cat /proc/net/dev
echo "NET1_END"
sleep 1
echo "T2=$(cut -d' ' -f1 /proc/uptime)"
echo "STAT2=$(head -n 1 /proc/stat)"
echo "NET2_BEGIN"
cat /proc/net/dev
echo "NET2_END"
grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo | sed 's/^/MEM /'
echo "DISK=$(df -Pk / | tail -n 1)"
echo "TCP=$( (ss -Htn state established 2>/dev/null || netstat -tn 2>/dev/null | grep ESTABLISHED) | wc -l)"
for s in sing-box xray hysteria x-ui nginx caddy dockerd; do
  pidof "$s" >/dev/null 2>&1 && echo "SVC=$s"
done
if command -v vnstat >/dev/null 2>&1; then
  echo "VNSTAT=$(vnstat --oneline b 2>/dev/null)"
fi
exit 0
"""#

    static let command: String = RemoteShell.wrap(body)
}

// MARK: - 解析

enum StatsParser {
    static func parse(_ text: String) -> ServerStats {
        var s = ServerStats()
        var net1: [String: (UInt64, UInt64)] = [:]
        var net2: [String: (UInt64, UInt64)] = [:]
        var section = 0
        var t1 = 0.0
        var t2 = 0.0
        var stat1: [UInt64] = []
        var stat2: [UInt64] = []
        var mem: [String: UInt64] = [:]

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line == "NET1_BEGIN" { section = 1; continue }
            if line == "NET2_BEGIN" { section = 2; continue }
            if line == "NET1_END" || line == "NET2_END" { section = 0; continue }

            if section != 0 {
                if let n = parseNetLine(line) {
                    if section == 1 { net1[n.0] = (n.1, n.2) } else { net2[n.0] = (n.1, n.2) }
                }
                continue
            }

            if line.hasPrefix("MEM ") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3, let v = UInt64(parts[2]) {
                    mem[String(parts[1]).replacingOccurrences(of: ":", with: "")] = v
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let val = String(line[line.index(after: eq)...])

            switch key {
            case "HOST": s.hostname = val
            case "OS": s.os = val
            case "KERNEL": s.kernel = val
            case "UPTIME": s.uptime = Int(val) ?? 0
            case "LOAD": s.load = val
            case "CPUS": s.cpus = max(Int(val) ?? 1, 1)
            case "PROCS": s.processes = Int(val.trimmingCharacters(in: .whitespaces)) ?? 0
            case "T1": t1 = Double(val) ?? 0
            case "T2": t2 = Double(val) ?? 0
            case "STAT1": stat1 = val.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            case "STAT2": stat2 = val.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            case "TCP": s.tcpEstablished = Int(val.trimmingCharacters(in: .whitespaces)) ?? 0
            case "SVC": s.services.append(val)
            case "DISK":
                let parts = val.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3, let t = UInt64(parts[1]), let u = UInt64(parts[2]) {
                    s.diskTotal = t * 1024
                    s.diskUsed = u * 1024
                }
            case "VNSTAT":
                let f = val.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
                if f.count >= 11, f[0] == "1" {
                    s.vnstatMonthRx = UInt64(f[8])
                    s.vnstatMonthTx = UInt64(f[9])
                }
            default:
                break
            }
        }

        s.cpuPercent = cpuPercent(stat1, stat2)
        let dt = (t2 > t1) ? (t2 - t1) : 1.0

        let physical = net2.filter { isPhysical($0.key) }
        let used = physical.isEmpty ? net2.filter { $0.key != "lo" } : physical
        var rxT: UInt64 = 0
        var txT: UInt64 = 0
        var rxD = 0.0
        var txD = 0.0
        var bestName = ""
        var bestTotal: UInt64 = 0
        for (name, v) in used {
            rxT += v.0
            txT += v.1
            if let o = net1[name] {
                if v.0 >= o.0 { rxD += Double(v.0 - o.0) }
                if v.1 >= o.1 { txD += Double(v.1 - o.1) }
            }
            if v.0 + v.1 >= bestTotal {
                bestTotal = v.0 + v.1
                bestName = name
            }
        }
        s.rxTotal = rxT
        s.txTotal = txT
        s.rxSpeed = rxD / dt
        s.txSpeed = txD / dt
        s.iface = bestName

        let total = (mem["MemTotal"] ?? 0) * 1024
        let avail = (mem["MemAvailable"] ?? mem["MemFree"] ?? 0) * 1024
        s.memTotal = total
        s.memUsed = total > avail ? total - avail : 0
        let swapTotal = (mem["SwapTotal"] ?? 0) * 1024
        let swapFree = (mem["SwapFree"] ?? 0) * 1024
        s.swapTotal = swapTotal
        s.swapUsed = swapTotal > swapFree ? swapTotal - swapFree : 0
        return s
    }

    private static func parseNetLine(_ line: String) -> (String, UInt64, UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard rest.count >= 9, let rx = UInt64(rest[0]), let tx = UInt64(rest[8]) else { return nil }
        return (name, rx, tx)
    }

    private static func isPhysical(_ n: String) -> Bool {
        let bad = ["lo", "docker", "veth", "br-", "virbr", "tun", "tap", "cni", "flannel", "kube", "tailscale", "wg", "zt"]
        for b in bad where n == b || n.hasPrefix(b) { return false }
        return true
    }

    private static func cpuPercent(_ a: [UInt64], _ b: [UInt64]) -> Double {
        guard a.count >= 5, b.count >= 5 else { return 0 }
        let t1 = a.prefix(8).reduce(UInt64(0), +)
        let t2 = b.prefix(8).reduce(UInt64(0), +)
        let i1 = a[3] + a[4]
        let i2 = b[3] + b[4]
        guard t2 > t1, i2 >= i1 else { return 0 }
        let dTotal = Double(t2 - t1)
        let dIdle = Double(i2 - i1)
        return min(max((1 - dIdle / dTotal) * 100, 0), 100)
    }
}

// MARK: - 监控（保持一个 SSH 连接，定时采集）

@MainActor
final class ServerMonitor: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let profile: ServerProfile
    @Published var state: State = .idle
    @Published var stats = ServerStats()
    @Published var cpuHistory: [Double] = []
    @Published var rxHistory: [Double] = []
    @Published var txHistory: [Double] = []
    @Published var updatedAt: Date?
    @Published var lastOutput = ""

    private let conn = SSHConn()
    private var loop: Task<Void, Never>?
    private var gen = 0
    private var connected = false
    private let maxPoints = 40

    init(profile: ServerProfile) {
        self.profile = profile
    }

    deinit {
        conn.close()
    }

    func start() {
        if loop != nil { return }
        gen += 1
        let g = gen
        let box = WeakBox(self)
        loop = Task { await ServerMonitor.runLoop(box, g) }
    }

    func stop() {
        gen += 1
        loop?.cancel()
        loop = nil
        connected = false
        conn.close()
        state = .idle
    }

    func reconnect() {
        stop()
        start()
    }

    /// 只在循环里短暂持有 self，页面退出后连接会随 deinit 关闭
    private static func runLoop(_ box: WeakBox<ServerMonitor>, _ g: Int) async {
        while !Task.isCancelled {
            do {
                guard let m = box.value else { return }
                let go = await m.step(g)
                if !go {
                    m.loopEnded(g)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func loopEnded(_ g: Int) {
        if g == gen { loop = nil }
    }

    private func step(_ g: Int) async -> Bool {
        guard g == gen else { return false }
        if !connected {
            state = .connecting
            do {
                try await conn.connect(profile, secret: ServerStore.secret(for: profile))
            } catch {
                guard g == gen else { return false }
                state = .failed(friendlyError(error))
                return false
            }
            guard g == gen else { return false }
            connected = true
            state = .connected
        }
        do {
            let out = try await conn.exec(StatsScript.command)
            guard g == gen else { return false }
            apply(StatsParser.parse(out))
            return true
        } catch {
            guard g == gen else { return false }
            connected = false
            state = .failed(friendlyError(error))
            return false
        }
    }

    private func apply(_ s: ServerStats) {
        stats = s
        updatedAt = Date()
        cpuHistory = trimmed(cpuHistory + [s.cpuPercent])
        rxHistory = trimmed(rxHistory + [s.rxSpeed])
        txHistory = trimmed(txHistory + [s.txSpeed])
    }

    private func trimmed(_ a: [Double]) -> [Double] {
        a.count > maxPoints ? Array(a.suffix(maxPoints)) : a
    }

    /// 流式执行命令（控制台、部署脚本用）
    func runStream(_ command: String, onChunk: @escaping @MainActor (String) -> Void) async throws {
        try await conn.stream(command) { chunk in
            Task { @MainActor in onChunk(chunk) }
        }
    }

    /// 给 AI 的上下文：当前状态 + 最近一次命令输出
    var aiContext: String {
        let s = stats
        var t = "服务器：\(profile.name)（\(profile.host)）\n"
        if updatedAt != nil {
            t += "系统：\(s.os)，内核 \(s.kernel)\n"
            t += "运行时间：\(fmtUptime(s.uptime))，负载 \(s.load)（\(s.cpus) 核）\n"
            t += "CPU：\(Int(s.cpuPercent))%\n"
            t += "内存：\(fmtBytes(s.memUsed)) / \(fmtBytes(s.memTotal))，Swap：\(fmtBytes(s.swapUsed)) / \(fmtBytes(s.swapTotal))\n"
            t += "磁盘：\(fmtBytes(s.diskUsed)) / \(fmtBytes(s.diskTotal))\n"
            t += "实时网速：下载 \(fmtSpeed(s.rxSpeed))，上传 \(fmtSpeed(s.txSpeed))\n"
            t += "开机以来累计流量：下载 \(fmtBytes(s.rxTotal))，上传 \(fmtBytes(s.txTotal))\n"
            if let r = s.vnstatMonthRx, let u = s.vnstatMonthTx {
                t += "本月流量：下载 \(fmtBytes(r))，上传 \(fmtBytes(u))\n"
            }
            t += "进程数：\(s.processes)，已建立 TCP 连接：\(s.tcpEstablished)\n"
            if !s.services.isEmpty { t += "运行中的服务：\(s.services.joined(separator: "、"))\n" }
        }
        if !lastOutput.isEmpty {
            t += "\n最近一次命令输出：\n" + String(lastOutput.suffix(3000))
        }
        return t
    }
}
