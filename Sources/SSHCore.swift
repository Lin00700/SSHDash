import Foundation
import Citadel
import Crypto
import NIOCore

enum AppSSHError: LocalizedError {
    case notConnected
    case badKey

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接到服务器"
        case .badKey: return "私钥无效，请在服务器设置里重新生成密钥"
        }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

/// 对 Citadel 的薄封装
final class SSHConn {
    private var client: SSHClient?

    func connect(_ p: ServerProfile, secret: String) async throws {
        let method: SSHAuthenticationMethod
        switch p.auth {
        case .password:
            method = .passwordBased(username: p.username, password: secret)
        case .key:
            guard let raw = Data(base64Encoded: secret),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                throw AppSSHError.badKey
            }
            method = .ed25519(username: p.username, privateKey: key)
        }
        client = try await SSHClient.connect(
            host: p.host,
            port: p.port,
            authenticationMethod: method,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }

    /// 一次性执行，返回合并后的输出
    func exec(_ command: String) async throws -> String {
        guard let c = client else { throw AppSSHError.notConnected }
        let buf = try await c.executeCommand(command, maxResponseSize: 4_000_000, mergeStreams: true)
        return String(buffer: buf)
    }

    /// 流式执行，边执行边回调输出
    func stream(_ command: String, onChunk: @escaping @Sendable (String) -> Void) async throws {
        guard let c = client else { throw AppSSHError.notConnected }
        let streams = try await c.executeCommandStream(command)
        for try await blob in streams {
            switch blob {
            case .stdout(let b):
                onChunk(String(buffer: b))
            case .stderr(let b):
                onChunk(String(buffer: b))
            default:
                break
            }
        }
    }

    func close() {
        let c = client
        client = nil
        if let c = c {
            Task { try? await c.close() }
        }
    }
}

enum RemoteShell {
    /// 把脚本 base64 后用 sh 执行，避免引号转义问题，也不依赖远端登录 shell 类型
    static func wrap(_ script: String) -> String {
        let b64 = Data(script.utf8).base64EncodedString()
        return "echo '\(b64)' | base64 -d | sh"
    }
}

func friendlyError(_ e: Error) -> String {
    let d = String(describing: e)
    if d.contains("allAuthenticationOptionsFailed") {
        return "认证失败：请检查用户名、密码或密钥（服务器可能禁用了密码登录）"
    }
    if d.lowercased().contains("timeout") || d.lowercased().contains("timedout") {
        return "连接超时，请检查地址、端口和网络"
    }
    if d.lowercased().contains("refused") {
        return "连接被拒绝，请检查端口和 SSH 服务是否在运行"
    }
    if let l = e as? LocalizedError, let m = l.errorDescription { return m }
    return String(d.prefix(200))
}

/// 生成 OpenSSH 格式的 ed25519 公钥（可直接追加到 authorized_keys）
func sshPublicKeyString(_ priv: Curve25519.Signing.PrivateKey, comment: String) -> String {
    let pub = priv.publicKey.rawRepresentation
    var blob = Data()
    func put(_ d: Data) {
        var len = UInt32(d.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(d)
    }
    put(Data("ssh-ed25519".utf8))
    put(pub)
    return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
}
