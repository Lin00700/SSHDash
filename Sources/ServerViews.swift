import SwiftUI
import Crypto

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
                            Text("点右上角 + 添加。支持密码登录，或在 App 里生成 ed25519 密钥后把公钥加到服务器。")
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
    @State private var keyB64: String
    @State private var copied = false

    init(profile: ServerProfile) {
        _p = State(initialValue: profile)
        _portText = State(initialValue: String(profile.port))
        let secret = ServerStore.secret(for: profile)
        _password = State(initialValue: profile.auth == .password ? secret : "")
        _keyB64 = State(initialValue: profile.auth == .key ? secret : "")
    }

    private var isNew: Bool {
        !store.servers.contains(where: { $0.id == p.id })
    }

    private var publicKeyText: String? {
        guard let raw = Data(base64Encoded: keyB64),
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return sshPublicKeyString(k, comment: "sshdash")
    }

    private var valid: Bool {
        let hostOK = !p.host.trimmingCharacters(in: .whitespaces).isEmpty
        let userOK = !p.username.trimmingCharacters(in: .whitespaces).isEmpty
        let authOK = p.auth == .password || publicKeyText != nil
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
    }

    @ViewBuilder
    private var keySection: some View {
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
            Text("把这一行公钥追加到服务器的 ~/.ssh/authorized_keys，再点保存。")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("还没有密钥").foregroundColor(.secondary)
        }
        Button(publicKeyText == nil ? "生成密钥对" : "重新生成（旧公钥将失效）") {
            keyB64 = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
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
        ServerStore.setSecret(np.auth == .password ? password : keyB64, for: np)
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
    @StateObject private var monitor: ServerMonitor
    @State private var tab = 0

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
        .onAppear { monitor.start() }
    }
}
