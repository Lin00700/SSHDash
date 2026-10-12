import Foundation

final class ServerStore: ObservableObject {
    @Published var servers: [ServerProfile] {
        didSet { persistServers() }
    }
    @Published var scripts: [CustomScript] {
        didSet { persistScripts() }
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: "ssh_servers"),
           let list = try? JSONDecoder().decode([ServerProfile].self, from: d) {
            servers = list
        } else {
            servers = []
        }
        if let d = UserDefaults.standard.data(forKey: "ssh_scripts"),
           let list = try? JSONDecoder().decode([CustomScript].self, from: d) {
            scripts = list
        } else {
            scripts = []
        }
    }

    private func persistServers() {
        if let d = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(d, forKey: "ssh_servers")
        }
    }

    private func persistScripts() {
        if let d = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(d, forKey: "ssh_scripts")
        }
    }

    // 密码 / 私钥保存在钥匙串
    static func secret(for p: ServerProfile) -> String {
        AIKeychain.load(account: "srv-" + p.id.uuidString) ?? ""
    }

    static func setSecret(_ s: String, for p: ServerProfile) {
        AIKeychain.save(s, account: "srv-" + p.id.uuidString)
    }

    func delete(_ p: ServerProfile) {
        AIKeychain.delete(account: "srv-" + p.id.uuidString)
        servers.removeAll { $0.id == p.id }
    }
}
