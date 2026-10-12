import SwiftUI
import Crypto
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = ServerStore()

    var body: some View {
        TabView {
            ServersView()
                .tabItem { Label("服务器", systemImage: "server.rack") }
            NavigationView {
                AIChatView()
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .tint(Theme.cyan)
    }
}

// MARK: - 服务器列表

struct ServersView: View {
    @EnvironmentObject var store: ServerStore
    @State private var editing: ServerProfile?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.servers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("还没有服务器", systemImage: "server.rack")
                                .font(.headline)
                                .foregroundStyle(Theme.gradient)
                            Text("点右上角 + 添加。支持密码、本机生成 ed25519，或导入 AWS Lightsail / EC2 的 .pem（RSA）和 OpenSSH 私钥。")
                                .font(.footnote)
                                .foregroundColor(Theme.textDim)
                        }
                        .neonCard()
                    }
                    ForEach(store.servers) { s in
                        NavigationLink(destination: ServerDetailView(profile: s)) {
                            ServerCard(profile: s)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editing = s
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(s)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
            .neonBackground()
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editing = ServerProfile(name: "", host: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { p in
                NavigationView {
                    ServerEditorView(profile: p)
                }
                .preferredColorScheme(.dark)
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ServerCard: View {
    let profile: ServerProfile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(Theme.gradient)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
            Spacer()
            Text(profile.auth == .password ? "密码" : "密钥")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().stroke(Theme.cyan.opacity(0.6)))
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
        .neonCard()
    }
}

// MARK: - 添加 / 编辑服务器

struct ServerEditorView: View {
    @EnvironmentObject var store: ServerStore
    @Environment(\.presentationMode) private var mode
    @State private var p: ServerProfile
    @State private var portText: String
    @State private var password: String
    @State private var keySecret: String
    @State private var keyPassphrase: String = ""
    @State private var copied = false
    @State private var importError: String?
    @State private var showImporter = false
    @State private var keySourceHint = ""

    init(profile: ServerProfile) {
        _p = State(initialValue: profile)
        _portText = State(initialValue: String(profile.port))
        let secret = ServerStore.secret(for: profile)
        _password = State(initialValue: profile.auth == .password ? secret : "")
        _keySecret = State(initialValue: profile.auth == .key ? secret : "")
        if profile.auth == .key, !secret.isEmpty {
            let hint: String
            if secret.contains("BEGIN RSA PRIVATE KEY") {
                hint = "已导入 RSA PEM 私钥"
            } else if secret.hasPrefix("-----") {
                hint = "已导入私钥文件"
            } else {
                hint = "本机生成的密钥"
            }
            _keySourceHint = State(initialValue: hint)
        }
    }

    private var isNew: Bool {
        !store.servers.contains(where: { $0.id == p.id })
    }

    private var publicKeyText: String? {
        KeyMaterial.publicKey(from: keySecret)
    }

    private var valid: Bool {
        let hostOK = !p.host.trimmingCharacters(in: .whitespaces).isEmpty
        let userOK = !p.username.trimmingCharacters(in: .whitespaces).isEmpty
        let authOK: Bool
        if p.auth == .password {
            authOK = true
        } else {
            authOK = publicKeyText != nil || keySecret.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----")
        }
        return hostOK && userOK && authOK
    }

    var body: some View {
        Form {
            Section(header: Text("服务器")) {
                TextField("名称（例如 亚马逊1号机）", text: $p.name)
                TextField("地址（IP 或域名）", text: $p.host)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                TextField("用户名", text: $p.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            Section(header: Text("登录方式")) {
                Picker("方式", selection: $p.auth) {
                    ForEach(AuthKind.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)

                if p.auth == .password {
                    SecureField("密码", text: $password)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } else {
                    keySection
                }
            }
            Section {
                Button("保存") { save() }
                    .disabled(!valid)
            }
        }
        .neonBackground()
        .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { mode.wrappedValue.dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .plainText, .text, UTType(filenameExtension: "pem") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    @ViewBuilder
    private var keySection: some View {
        if !keySourceHint.isEmpty {
            Text(keySourceHint)
                .font(.caption)
                .foregroundColor(Theme.cyan)
        }

        if let pub = publicKeyText {
            Text(pub)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = pub
                copied = true
            } label: {
                Label(copied ? "已复制" : "复制公钥", systemImage: "doc.on.doc")
            }
            Text("AWS 机器一般已自动装好对应公钥。若要装到别的服务器，可复制公钥或用详情页「钥匙」菜单写入。")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if keySecret.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----") {
            Text("已读入私钥内容，点保存时会校验。加密密钥请填写口令。")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("还没有密钥").foregroundColor(.secondary)
        }

        if let e = importError {
            Text(e).font(.caption).foregroundColor(.red)
        }

        SecureField("密钥口令（仅加密私钥需要）", text: $keyPassphrase)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)

        Button {
            showImporter = true
        } label: {
            Label("从文件导入私钥（.pem / OpenSSH）", systemImage: "doc.badge.plus")
        }

        Button {
            if let clip = UIPasteboard.general.string, clip.contains("BEGIN") {
                applyImportedKey(clip, source: "从剪贴板导入")
            } else {
                importError = "剪贴板里没有私钥（需要包含 BEGIN … PRIVATE KEY）"
            }
        } label: {
            Label("从剪贴板粘贴私钥", systemImage: "doc.on.clipboard")
        }

        Button(publicKeyText == nil && keySecret.isEmpty ? "生成 ed25519 密钥对" : "重新生成 ed25519（旧公钥将失效）") {
            let key = Curve25519.Signing.PrivateKey()
            keySecret = key.makeSSHRepresentation(comment: "sshdash")
            keyPassphrase = ""
            keySourceHint = "本机新生成的 ed25519 密钥"
            importError = nil
            copied = false
        }

        if let pub = publicKeyText, pub.hasPrefix("ssh-ed25519"),
           let parsed = try? KeyMaterial.parse(keySecret),
           case .ed25519(let key) = parsed {
            Button {
                UIPasteboard.general.string = key.makeSSHRepresentation(comment: "sshdash")
            } label: {
                Label("复制完整私钥（OpenSSH 格式）", systemImage: "key")
            }
            Text("仅在可信环境使用。私钥离开本机钥匙串后请自行妥善保管。")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            importError = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    importError = "无法读取文件内容"
                    return
                }
                applyImportedKey(text, source: "已从文件导入：\(url.lastPathComponent)")
            } catch {
                importError = "读取文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func applyImportedKey(_ text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN") && trimmed.contains("PRIVATE KEY") else {
            importError = "不是私钥文件（需要 BEGIN RSA PRIVATE KEY 或 BEGIN OPENSSH PRIVATE KEY）"
            return
        }
        do {
            let normalized = try KeyMaterial.normalize(
                secret: trimmed,
                passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
            keySecret = normalized.stored
            let kind: String
            if normalized.publicKey.hasPrefix("ssh-rsa") {
                kind = "RSA"
            } else if normalized.publicKey.hasPrefix("ssh-ed25519") {
                kind = "ed25519"
            } else {
                kind = "密钥"
            }
            keySourceHint = source + "（\(kind)）"
            importError = nil
            copied = false
        } catch {
            // 先收下原文，保存时再报详细错误（例如需要口令）
            keySecret = trimmed
            keySourceHint = source + "（待校验）"
            importError = friendlyError(error)
            copied = false
        }
    }

    private func save() {
        var np = p
        np.host = np.host.trimmingCharacters(in: .whitespaces)
        np.username = np.username.trimmingCharacters(in: .whitespaces)
        np.port = Int(portText) ?? 22
        np.name = np.name.trimmingCharacters(in: .whitespaces)
        if np.name.isEmpty { np.name = np.host }

        if np.auth == .password {
            ServerStore.setSecret(password, for: np)
        } else {
            do {
                let normalized = try KeyMaterial.normalize(
                    secret: keySecret,
                    passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
                )
                ServerStore.setSecret(normalized.stored, for: np)
                keySecret = normalized.stored
                importError = nil
            } catch {
                importError = friendlyError(error)
                return
            }
        }

        if let i = store.servers.firstIndex(where: { $0.id == np.id }) {
            store.servers[i] = np
        } else {
            store.servers.append(np)
        }
        mode.wrappedValue.dismiss()
    }
}

// MARK: - 服务器详情

struct ServerDetailView: View {
    let profile: ServerProfile
    @EnvironmentObject var store: ServerStore
    @StateObject private var monitor: ServerMonitor
    @State private var tab = 0
    @State private var installMsg: String?
    @State private var installing = false

    init(profile: ServerProfile) {
        self.profile = profile
        _monitor = StateObject(wrappedValue: ServerMonitor(profile: profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("概览").tag(0)
                Text("命令").tag(1)
                Text("部署").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case 0: OverviewTab(monitor: monitor)
                case 1: ConsoleTab(monitor: monitor)
                default: DeployTab(monitor: monitor)
                }
            }
        }
        .neonBackground()
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            Task { await installPublicKey() }
                        } label: {
                            Label(
                                profile.auth == .key ? "把当前公钥写入服务器" : "生成密钥并写入服务器",
                                systemImage: "key.fill"
                            )
                        }
                        .disabled(installing || monitor.state != .connected)
                    } label: {
                        if installing {
                            ProgressView()
                        } else {
                            Image(systemName: "key")
                        }
                    }
                    NavigationLink(
                        destination: AIChatView(
                            contextTitle: profile.name,
                            contextText: monitor.aiContext,
                            quickPrompts: ["分析这台服务器的状态", "流量和负载有没有异常？", "节点连不上怎么排查？"]
                        )
                    ) {
                        Image(systemName: "sparkles")
                    }
                }
            }
        }
        .onAppear { monitor.start() }
        .alert("公钥安装", isPresented: Binding(
            get: { installMsg != nil },
            set: { if !$0 { installMsg = nil } }
        )) {
            Button("好") { installMsg = nil }
        } message: {
            Text(installMsg ?? "")
        }
    }

    private func installPublicKey() async {
        installing = true
        defer { installing = false }

        let secret = ServerStore.secret(for: profile)
        if let pub = KeyMaterial.publicKey(from: secret) {
            do {
                let out = try await monitor.runStreamCollect(RemoteShell.wrap(PubkeyInstall.script(publicKey: pub)))
                installMsg = out
            } catch {
                installMsg = friendlyError(error)
            }
            return
        }

        let key = Curve25519.Signing.PrivateKey()
        let openssh = key.makeSSHRepresentation(comment: "sshdash")
        let pub = sshPublicKeyString(key, comment: "sshdash")
        do {
            let out = try await monitor.runStreamCollect(RemoteShell.wrap(PubkeyInstall.script(publicKey: pub)))
            var updated = profile
            updated.auth = .key
            ServerStore.setSecret(openssh, for: updated)
            if let i = store.servers.firstIndex(where: { $0.id == updated.id }) {
                store.servers[i] = updated
            }
            installMsg = out + "\n\n已生成本机密钥并写入服务器，登录方式已切换为「密钥」。\n下次可用密钥登录（无需再输密码）。\n公钥：\n" + pub
        } catch {
            installMsg = friendlyError(error)
        }
    }
}
