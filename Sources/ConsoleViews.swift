import SwiftUI

struct ConsoleTab: View {
    @ObservedObject var monitor: ServerMonitor
    @State private var command = ""
    @State private var output = ""
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "ssh_cmd_history") ?? []

    private let quick: [(String, String)] = [
        ("系统", "cat /etc/os-release | head -n 3; uname -a; uptime"),
        ("磁盘", "df -h"),
        ("内存", "free -m 2>/dev/null || head -n 5 /proc/meminfo"),
        ("进程", "top -bn1 | head -n 15"),
        ("端口", "ss -tulnp 2>/dev/null || netstat -tulnp"),
        ("Docker", "docker ps -a"),
        ("sing-box 日志", "journalctl -u sing-box -n 40 --no-pager"),
        ("公网 IP", "curl -s4 --max-time 5 https://api.ipify.org; echo")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<quick.count, id: \.self) { idx in
                        let item = quick[idx]
                        Button {
                            command = item.1
                            run()
                        } label: {
                            Text(item.0)
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Theme.card))
                                .overlay(Capsule().stroke(Theme.purple.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            if !history.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundColor(Theme.textDim)
                        ForEach(history.prefix(12), id: \.self) { h in
                            Button {
                                command = h
                                run()
                            } label: {
                                Text(h.count > 28 ? String(h.prefix(26)) + "…" : h)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().stroke(Theme.cyan.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            history = []
                            UserDefaults.standard.removeObject(forKey: "ssh_cmd_history")
                        } label: {
                            Text("清空")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if output.isEmpty {
                            Text("在下面输入命令，或点上面的快捷命令。命令在服务器上以登录用户身份执行，不支持交互式程序（如 vim、top 不带参数）。最近执行过的命令会出现在历史栏，点一下即可重跑。")
                                .font(.footnote)
                                .foregroundColor(Theme.textDim)
                        } else {
                            Text(output)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !output.isEmpty && !running {
                            NavigationLink(
                                destination: AIChatView(
                                    contextTitle: "命令输出",
                                    contextText: String(output.suffix(4000)),
                                    quickPrompts: ["解释这段输出", "有什么异常？", "下一步该怎么做？"]
                                )
                            ) {
                                Label("问 AI", systemImage: "sparkles")
                            }
                            .font(.footnote.bold())
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: output) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(Color.black.opacity(0.25))

            HStack(spacing: 8) {
                TextField("输入命令", text: $command)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.send)
                    .onSubmit { run() }
                    .neonField()
                Button {
                    if running { task?.cancel() } else { run() }
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.gradient)
                        .clipShape(Circle())
                }
                .disabled(!running && command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty || running { return }
        pushHistory(cmd)
        output = "$ \(cmd)\n"
        running = true
        task = Task { @MainActor in
            do {
                try await monitor.runStream(cmd) { chunk in
                    append(chunk)
                }
            } catch {
                append("\n[结束/错误] \(friendlyError(error))\n")
            }
            monitor.lastOutput = "$ \(cmd)\n" + String(output.suffix(3500))
            running = false
        }
    }

    private func pushHistory(_ cmd: String) {
        var h = history.filter { $0 != cmd }
        h.insert(cmd, at: 0)
        if h.count > 30 { h = Array(h.prefix(30)) }
        history = h
        UserDefaults.standard.set(h, forKey: "ssh_cmd_history")
    }

    private func append(_ s: String) {
        output += stripANSI(s)
        if output.count > 40000 {
            output = String(output.suffix(30000))
        }
    }
}
