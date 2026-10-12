import SwiftUI

// MARK: - 部署页

struct DeployTab: View {
    @ObservedObject var monitor: ServerMonitor
    @EnvironmentObject var store: ServerStore
    @State private var editing: CustomScript?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("脚本会以当前登录用户在服务器上执行，建议使用 root。运行前可以先查看脚本内容。")
                    .font(.footnote)
                    .foregroundColor(Theme.textDim)

                ForEach(DeployTemplates.all) { t in
                    NavigationLink(destination: ScriptRunnerView(monitor: monitor, template: t)) {
                        TemplateCard(title: t.title, subtitle: t.subtitle, icon: t.icon, tint: t.tint)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("我的脚本")
                        .font(.footnote.bold())
                        .foregroundColor(Theme.cyan)
                    Spacer()
                    Button {
                        editing = CustomScript(name: "", body: "")
                    } label: {
                        Label("新建", systemImage: "plus")
                            .font(.footnote.bold())
                    }
                }
                .padding(.top, 6)

                if store.scripts.isEmpty {
                    Text("还没有自定义脚本。可以把常用的 sh 脚本存在这里，一键在服务器上运行。")
                        .font(.footnote)
                        .foregroundColor(Theme.textDim)
                }
                ForEach(store.scripts) { sc in
                    NavigationLink(destination: ScriptRunnerView(monitor: monitor, template: custom(sc))) {
                        TemplateCard(title: sc.name, subtitle: "自定义脚本", icon: "terminal", tint: Theme.purple)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editing = sc
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.scripts.removeAll { $0.id == sc.id }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
        .sheet(item: $editing) { sc in
            NavigationView {
                CustomScriptEditor(script: sc)
            }
            .preferredColorScheme(.dark)
        }
    }

    private func custom(_ sc: CustomScript) -> DeployTemplate {
        DeployTemplate(
            id: sc.id.uuidString,
            title: sc.name,
            subtitle: "自定义脚本",
            icon: "terminal",
            tint: Theme.purple,
            script: sc.body
        )
    }
}

struct TemplateCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(tint)
                .shadow(color: tint.opacity(0.8), radius: 6)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
        .neonCard()
    }
}

struct CustomScriptEditor: View {
    @EnvironmentObject var store: ServerStore
    @Environment(\.presentationMode) private var mode
    @State private var script: CustomScript

    init(script: CustomScript) {
        _script = State(initialValue: script)
    }

    var body: some View {
        Form {
            Section(header: Text("名称")) {
                TextField("例如 查看 Docker 容器", text: $script.name)
            }
            Section(header: Text("脚本（sh）")) {
                TextEditor(text: $script.body)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            Section {
                Button("保存") {
                    var s = script
                    s.name = s.name.trimmingCharacters(in: .whitespaces)
                    if s.name.isEmpty { s.name = "未命名脚本" }
                    if let i = store.scripts.firstIndex(where: { $0.id == s.id }) {
                        store.scripts[i] = s
                    } else {
                        store.scripts.append(s)
                    }
                    mode.wrappedValue.dismiss()
                }
                .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .neonBackground()
        .navigationTitle("脚本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { mode.wrappedValue.dismiss() }
            }
        }
    }
}

// MARK: - 运行脚本

struct ScriptRunnerView: View {
    @ObservedObject var monitor: ServerMonitor
    let template: DeployTemplate
    @State private var values: [String: String]
    @State private var log = ""
    @State private var running = false
    @State private var confirm = false
    @State private var showScript = false
    @State private var qr: QRItem?
    @State private var task: Task<Void, Never>?

    init(monitor: ServerMonitor, template: DeployTemplate) {
        _monitor = ObservedObject(wrappedValue: monitor)
        self.template = template
        var v: [String: String] = [:]
        for p in template.params { v[p.id] = p.value }
        _values = State(initialValue: v)
    }

    private var finalScript: String {
        var pre = "SERVER_HOST='\(safeParam(monitor.profile.host))'\n"
        for p in template.params {
            pre += "\(p.id)='\(safeParam(values[p.id] ?? p.value))'\n"
        }
        return pre + template.script
    }

    private var links: [String] {
        log.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("NODE_LINK=") }
            .map { String($0.dropFirst("NODE_LINK=".count)) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if !template.params.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(template.params) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.label)
                                        .font(.caption)
                                        .foregroundColor(Theme.textDim)
                                    TextField(p.value, text: binding(for: p))
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                        .neonField()
                                }
                            }
                        }
                        .neonCard()
                    }

                    HStack(spacing: 10) {
                        Button {
                            showScript.toggle()
                        } label: {
                            Text(showScript ? "隐藏脚本" : "查看脚本")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cyan.opacity(0.6)))
                        }
                        Button {
                            if running {
                                task?.cancel()
                            } else {
                                confirm = true
                            }
                        } label: {
                            HStack {
                                if running { ProgressView() }
                                Text(running ? "停止显示" : "运行")
                            }
                        }
                        .buttonStyle(NeonButtonStyle())
                    }

                    if showScript {
                        ScrollView(.horizontal) {
                            Text(finalScript)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(Theme.card)
                        .cornerRadius(10)
                    }

                    ForEach(links, id: \.self) { l in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("节点链接", systemImage: "link")
                                .font(.headline)
                                .foregroundStyle(Theme.gradient)
                            Text(l)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(4)
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    UIPasteboard.general.string = l
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                }
                                Spacer()
                                Button {
                                    qr = QRItem(text: l)
                                } label: {
                                    Label("二维码", systemImage: "qrcode")
                                }
                            }
                            .font(.footnote.bold())
                        }
                        .neonCard()
                    }

                    if !log.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("输出", systemImage: "terminal")
                                .font(.headline)
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !running {
                                NavigationLink(
                                    destination: AIChatView(
                                        contextTitle: template.title,
                                        contextText: String(log.suffix(4000)),
                                        quickPrompts: ["这次部署成功了吗？", "解释这段输出里的报错", "下一步该怎么做？"]
                                    )
                                ) {
                                    Label("问 AI", systemImage: "sparkles")
                                }
                                .font(.footnote.bold())
                            }
                        }
                        .neonCard()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: log) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .neonBackground()
        .navigationTitle(template.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("在 \(monitor.profile.name) 上运行？", isPresented: $confirm) {
            Button("运行", role: .destructive) { run() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("脚本会以 \(monitor.profile.username) 的身份在服务器上执行。请确认已经查看过脚本内容。运行期间请保持 App 在前台。")
        }
        .sheet(item: $qr) { item in
            QRSheet(text: item.text)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: template.icon)
                    .font(.title)
                    .foregroundColor(template.tint)
                    .shadow(color: template.tint.opacity(0.8), radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title).font(.headline)
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundColor(Theme.textDim)
                }
            }
            if let w = template.warning {
                Label(w, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .neonCard()
    }

    private func binding(for p: DeployParam) -> Binding<String> {
        Binding(
            get: { values[p.id] ?? p.value },
            set: { values[p.id] = $0 }
        )
    }

    private func run() {
        if running { return }
        log = ""
        running = true
        let cmd = RemoteShell.wrap(finalScript)
        task = Task { @MainActor in
            do {
                try await monitor.runStream(cmd) { chunk in
                    append(chunk)
                }
                append("\n✅ 执行结束\n")
            } catch {
                append("\n⚠️ 执行中断或失败：\(friendlyError(error))\n")
            }
            monitor.lastOutput = "脚本：\(template.title)\n" + String(log.suffix(3500))
            running = false
        }
    }

    private func append(_ s: String) {
        log += stripANSI(s)
        if log.count > 60000 {
            log = String(log.suffix(40000))
        }
    }
}
