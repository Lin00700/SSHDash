import Foundation
import Citadel
import Crypto
import NIOCore

enum AppSSHError: LocalizedError {
    case notConnected
    case badKey
    case needPassphrase
    case unsupportedKey

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接到服务器"
        case .badKey: return "私钥无效，请重新导入或生成密钥"
        case .needPassphrase: return "私钥已加密，请填写密钥口令"
        case .unsupportedKey: return "暂不支持该密钥类型，请使用 ed25519（推荐）"
        }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

/// 解析并规范化私钥材料。
/// 支持：
/// 1) 本 App 生成的 base64(raw 32 bytes)
/// 2) OpenSSH 格式 -----BEGIN OPENSSH PRIVATE KEY-----
/// 3) 带口令的 OpenSSH ed25519
enum KeyMaterial {
    /// 返回可存入钥匙串的规范化私钥字符串，以及可展示的公钥
    static func normalize(secret: String, passphrase: String?) throws -> (stored: String, publicKey: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----") {
            let passData = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            do {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: passData)
                // 统一存成无口令的 OpenSSH 格式，后续连接不再需要口令
                let openssh = key.makeSSHRepresentation(comment: "sshdash")
                let pub = sshPublicKeyString(key, comment: "sshdash")
                return (openssh, pub)
            } catch {
                // 常见：缺口令 / 口令错误 / 不是 ed25519
                let desc = String(describing: error).lowercased()
                if passData == nil, desc.contains("decrypt") || desc.contains("pass") || desc.contains("cipher") || desc.contains("kdf") {
                    throw AppSSHError.needPassphrase
                }
                if trimmed.contains("ssh-rsa") || trimmed.lowercased().contains("rsa") {
                    throw AppSSHError.unsupportedKey
                }
                throw AppSSHError.badKey
            }
        }
        // 兼容旧版：base64 raw
        guard let raw = Data(base64Encoded: trimmed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw AppSSHError.badKey
        }
        return (trimmed, sshPublicKeyString(key, comment: "sshdash"))
    }

    static func privateKey(from secret: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----") {
            return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed)
        }
        guard let raw = Data(base64Encoded: trimmed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw AppSSHError.badKey
        }
        return key
    }

    static func publicKey(from secret: String) -> String? {
        guard let key = try? privateKey(from: secret) else { return nil }
        return sshPublicKeyString(key, comment: "sshdash")
    }
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
            let key = try KeyMaterial.privateKey(from: secret)
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
    if let a = e as? AppSSHError, let m = a.errorDescription { return m }
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

/// 把公钥追加到远端 authorized_keys（幂等：已存在则跳过）
enum PubkeyInstall {
    static func script(publicKey: String) -> String {
        let b64 = Data(publicKey.utf8).base64EncodedString()
        return """
        set -e
        PUB=$(echo '\(b64)' | base64 -d)
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        if grep -qxF "$PUB" ~/.ssh/authorized_keys 2>/dev/null; then
          echo "公钥已存在，无需重复添加"
        else
          echo "$PUB" >> ~/.ssh/authorized_keys
          echo "✅ 已写入 authorized_keys"
        fi
        echo "当前 authorized_keys 行数：$(wc -l < ~/.ssh/authorized_keys | tr -d ' ')"
        """
    }
}
