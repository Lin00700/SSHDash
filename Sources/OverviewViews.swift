import SwiftUI

struct OverviewTab: View {
    @ObservedObject var monitor: ServerMonitor

    var body: some View {
        let s = monitor.stats
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                if monitor.updatedAt != nil {
                    infoCard(s)
                    gaugesCard(s)
                    trafficCard(s)
                    extraCard(s)
                    if !s.services.isEmpty { servicesCard(s) }
                }
            }
            .padding()
        }
    }

    // MARK: 状态

    private var statusColor: Color {
        switch monitor.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusTitle: String {
        switch monitor.state {
        case .connected: return "已连接 \(monitor.profile.host)"
        case .connecting: return "正在连接…"
        case .failed: return "连接失败"
        case .idle: return "未连接"
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.subheadline.bold())
                if case .failed(let msg) = monitor.state {
                    Text(msg).font(.caption).foregroundColor(.red)
                }
            }
            Spacer()
            if case .connecting = monitor.state {
                ProgressView()
            }
            if case .failed = monitor.state {
                Button("重新连接") { monitor.reconnect() }
                    .font(.footnote.bold())
            }
            if case .idle = monitor.state {
                Button("连接") { monitor.start() }
                    .font(.footnote.bold())
            }
            if case .connected = monitor.state, let t = monitor.updatedAt {
                Text(t, style: .time)
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
        }
        .neonCard()
    }

    // MARK: 信息

    private func infoCard(_ s: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(s.hostname.isEmpty ? monitor.profile.name : s.hostname, systemImage: "desktopcomputer")
                .font(.headline)
            infoRow("系统", s.os.isEmpty ? "-" : s.os)
            infoRow("内核", s.kernel)
            infoRow("运行时间", fmtUptime(s.uptime))
            infoRow("负载（\(s.cpus) 核）", s.load)
        }
        .neonCard()
    }

    private func gaugesCard(_ s: ServerStats) -> some View {
        HStack(alignment: .top) {
            RingGauge(
                title: "CPU",
                value: s.cpuPercent / 100,
                detail: "\(s.cpus) 核",
                tint: Theme.cyan
            )
            RingGauge(
                title: "内存",
                value: Double(s.memUsed) / Double(max(s.memTotal, 1)),
                detail: "\(fmtBytes(s.memUsed))/\(fmtBytes(s.memTotal))",
                tint: Theme.purple
            )
            RingGauge(
                title: "磁盘",
                value: Double(s.diskUsed) / Double(max(s.diskTotal, 1)),
                detail: "\(fmtBytes(s.diskUsed))/\(fmtBytes(s.diskTotal))",
                tint: Theme.pink
            )
        }
        .neonCard()
    }

    // MARK: 流量

    private func trafficCard(_ s: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("网络流量", systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                Spacer()
                if !s.iface.isEmpty {
                    Text(s.iface).font(.caption).foregroundColor(Theme.textDim)
                }
            }
            HStack {
                speedBlock("↓ 下载", s.rxSpeed, Theme.cyan)
                Spacer()
                speedBlock("↑ 上传", s.txSpeed, Theme.pink)
            }
            ZStack {
                Sparkline(values: monitor.rxHistory, tint: Theme.cyan)
                Sparkline(values: monitor.txHistory, tint: Theme.pink)
            }
            .frame(height: 60)
            Divider()
            infoRow("累计下载（开机以来）", fmtBytes(s.rxTotal))
            infoRow("累计上传（开机以来）", fmtBytes(s.txTotal))
            if let r = s.vnstatMonthRx, let u = s.vnstatMonthTx {
                infoRow("本月下载", fmtBytes(r))
                infoRow("本月上传", fmtBytes(u))
            } else {
                Text("在「部署」里运行「基础环境」安装 vnstat 后，这里会显示本月流量。")
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
        }
        .neonCard()
    }

    private func speedBlock(_ title: String, _ v: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(Theme.textDim)
            Text(fmtSpeed(v))
                .font(.title3.bold().monospacedDigit())
                .foregroundColor(tint)
                .shadow(color: tint.opacity(0.6), radius: 4)
        }
    }

    // MARK: 其他参数

    private func extraCard(_ s: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("其他参数", systemImage: "list.bullet.rectangle")
                .font(.headline)
            infoRow("进程数", "\(s.processes)")
            infoRow("TCP 已建立连接", "\(s.tcpEstablished)")
            infoRow("Swap", s.swapTotal == 0 ? "未启用" : "\(fmtBytes(s.swapUsed)) / \(fmtBytes(s.swapTotal))")
        }
        .neonCard()
    }

    private func servicesCard(_ s: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("运行中的服务", systemImage: "checkmark.seal")
                .font(.headline)
            HStack {
                ForEach(s.services, id: \.self) { name in
                    Text(name)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.cyan.opacity(0.15)))
                        .overlay(Capsule().stroke(Theme.cyan.opacity(0.6)))
                }
                Spacer()
            }
        }
        .neonCard()
    }
}
