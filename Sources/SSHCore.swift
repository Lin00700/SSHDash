import Foundation
import Citadel
import Crypto
import NIOCore
import CCryptoBoringSSL

enum AppSSHError: LocalizedError {
    case notConnected
    case badKey
    case needPassphrase
    case unsupportedKey
    case encryptedPEM

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接到服务器"
        case .badKey: return "私钥无效，请重新导入或生成密钥"
        case .needPassphrase: return "私钥已加密，请填写密钥口令"
        case .unsupportedKey: return "暂不支持该密钥类型"
        case .encryptedPEM: return "暂不支持加密的 RSA PEM，请用 ssh-keygen -p -m PEM -f 你的密钥 去掉口令后再导入"
        }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

// MARK: - 密钥材料

enum ParsedKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey, publicKeyLine: String)
}

enum KeyMaterial {
    /// 规范化后写入钥匙串；公钥用于展示 / 一键安装
    static func normalize(secret: String, passphrase: String?) throws -> (stored: String, publicKey: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try parse(trimmed, passphrase: passphrase)
        switch parsed {
        case .ed25519(let key):
            let stored = key.makeSSHRepresentation(comment: "sshdash")
            return (stored, sshEd25519PublicKeyString(key, comment: "sshdash"))
        case .rsa(_, let pub):
            // RSA 原样保存 PEM / OpenSSH 文本
            return (trimmed, pub)
        }
    }

    static func parse(_ secret: String, passphrase: String? = nil) throws -> ParsedKey {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 传统 PEM：AWS Lightsail / EC2 下载的 .pem（PKCS#1）
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            if trimmed.contains("ENCRYPTED") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
                throw AppSSHError.encryptedPEM
            }
            return try parseRSAPkcs1PEM(trimmed)
        }

        // 2) PKCS#8 PEM（-----BEGIN PRIVATE KEY-----）里也可能是 RSA
        if trimmed.contains("BEGIN PRIVATE KEY") && !trimmed.contains("OPENSSH") {
            if trimmed.contains("ENCRYPTED") {
                throw AppSSHError.encryptedPEM
            }
            // 先当 PKCS#8 里的 RSA 试；失败再报错
            if let rsa = try? parseRSAPkcs8PEM(trimmed) {
                return rsa
            }
            throw AppSSHError.badKey
        }

        // 3) OpenSSH 新格式
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let passData = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            // ed25519
            do {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: passData)
                return .ed25519(key)
            } catch {
                let desc = String(describing: error).lowercased()
                if passData == nil,
                   (desc.contains("decrypt") || desc.contains("pass") || desc.contains("cipher") || desc.contains("kdf") || desc.contains("missing")) {
                    // 可能是加密密钥或 RSA，继续尝试 RSA
                }
            }
            // OpenSSH RSA
            do {
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: trimmed)
                let pub = try rsaOpenSSHPublicKeyLine(fromOpenSSHPrivateKey: trimmed)
                return .rsa(rsa, publicKeyLine: pub)
            } catch {
                let desc = String(describing: error).lowercased()
                if passData == nil, desc.contains("decrypt") || desc.contains("pass") || desc.contains("cipher") {
                    throw AppSSHError.needPassphrase
                }
                throw AppSSHError.badKey
            }
        }

        // 4) 旧版本 App：base64(raw 32 bytes) ed25519
        if let raw = Data(base64Encoded: trimmed),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return .ed25519(key)
        }

        throw AppSSHError.badKey
    }

    static func publicKey(from secret: String) -> String? {
        guard let parsed = try? parse(secret) else { return nil }
        switch parsed {
        case .ed25519(let k):
            return sshEd25519PublicKeyString(k, comment: "sshdash")
        case .rsa(_, let pub):
            return pub
        }
    }

    static func authMethod(username: String, secret: String) throws -> SSHAuthenticationMethod {
        switch try parse(secret) {
        case .ed25519(let key):
            return .ed25519(username: username, privateKey: key)
        case .rsa(let key, _):
            return .rsa(username: username, privateKey: key)
        }
    }
}

// MARK: - RSA PKCS#1 / PKCS#8 PEM

private func pemBody(_ pem: String, begin: String, end: String) throws -> Data {
    var lines = pem
        .replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let b = lines.firstIndex(where: { $0.contains(begin) }),
          let e = lines.firstIndex(where: { $0.contains(end) }),
          b < e else {
        throw AppSSHError.badKey
    }
    let b64 = lines[(b + 1)..<e].joined()
    guard let data = Data(base64Encoded: b64) else { throw AppSSHError.badKey }
    return data
}

/// 解析 PKCS#1 RSAPrivateKey DER
private func parseRSAPkcs1PEM(_ pem: String) throws -> ParsedKey {
    let der = try pemBody(pem, begin: "BEGIN RSA PRIVATE KEY", end: "END RSA PRIVATE KEY")
    return try rsaFromPKCS1DER(der)
}

/// 解析 PKCS#8 PrivateKeyInfo，取出内层 PKCS#1
private func parseRSAPkcs8PEM(_ pem: String) throws -> ParsedKey {
    let der = try pemBody(pem, begin: "BEGIN PRIVATE KEY", end: "END PRIVATE KEY")
    // PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
    var idx = 0
    guard der[idx] == 0x30 else { throw AppSSHError.badKey }
    idx += 1
    _ = try readASN1Length(der, &idx)
    // version INTEGER
    guard der[idx] == 0x02 else { throw AppSSHError.badKey }
    idx += 1
    let vlen = try readASN1Length(der, &idx)
    idx += vlen
    // AlgorithmIdentifier SEQUENCE — skip
    guard der[idx] == 0x30 else { throw AppSSHError.badKey }
    idx += 1
    let alen = try readASN1Length(der, &idx)
    idx += alen
    // privateKey OCTET STRING
    guard der[idx] == 0x04 else { throw AppSSHError.badKey }
    idx += 1
    let klen = try readASN1Length(der, &idx)
    let pkcs1 = der.subdata(in: idx..<(idx + klen))
    return try rsaFromPKCS1DER(pkcs1)
}

private func rsaFromPKCS1DER(_ der: Data) throws -> ParsedKey {
    // RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, ... }
    var idx = 0
    guard der[idx] == 0x30 else { throw AppSSHError.badKey }
    idx += 1
    _ = try readASN1Length(der, &idx)

    // version
    let _ = try readASN1Integer(der, &idx)
    let n = try readASN1Integer(der, &idx)
    let e = try readASN1Integer(der, &idx)
    let d = try readASN1Integer(der, &idx)

    let nBN = n.withUnsafeBytes { CCryptoBoringSSL_BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, n.count, nil)! }
    let eBN = e.withUnsafeBytes { CCryptoBoringSSL_BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, e.count, nil)! }
    let dBN = d.withUnsafeBytes { CCryptoBoringSSL_BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, d.count, nil)! }

    let key = Insecure.RSA.PrivateKey(privateExponent: dBN, publicExponent: eBN, modulus: nBN)
    let pub = sshRSAPublicKeyString(modulus: n, exponent: e, comment: "sshdash")
    return .rsa(key, publicKeyLine: pub)
}

private func readASN1Length(_ data: Data, _ idx: inout Int) throws -> Int {
    guard idx < data.count else { throw AppSSHError.badKey }
    let first = Int(data[idx])
    idx += 1
    if first & 0x80 == 0 { return first }
    let nbytes = first & 0x7f
    guard nbytes > 0, nbytes <= 4, idx + nbytes <= data.count else { throw AppSSHError.badKey }
    var len = 0
    for _ in 0..<nbytes {
        len = (len << 8) | Int(data[idx])
        idx += 1
    }
    return len
}

private func readASN1Integer(_ data: Data, _ idx: inout Int) throws -> Data {
    guard idx < data.count, data[idx] == 0x02 else { throw AppSSHError.badKey }
    idx += 1
    let len = try readASN1Length(data, &idx)
    guard idx + len <= data.count else { throw AppSSHError.badKey }
    var intData = data.subdata(in: idx..<(idx + len))
    idx += len
    // 去掉前导 0x00（符号位填充）
    while intData.count > 1 && intData[0] == 0x00 {
        intData = intData.dropFirst()
    }
    return Data(intData)
}

// MARK: - 公钥行

func sshEd25519PublicKeyString(_ priv: Curve25519.Signing.PrivateKey, comment: String) -> String {
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

/// 兼容旧调用名
func sshPublicKeyString(_ priv: Curve25519.Signing.PrivateKey, comment: String) -> String {
    sshEd25519PublicKeyString(priv, comment: comment)
}

func sshRSAPublicKeyString(modulus: Data, exponent: Data, comment: String) -> String {
    var blob = Data()
    func putSSHString(_ d: Data) {
        var len = UInt32(d.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(d)
    }
    func putMPInt(_ d: Data) {
        // mpint：若最高位为 1，前面补 0x00
        var body = d
        if let first = body.first, first & 0x80 != 0 {
            body = Data([0x00]) + body
        }
        putSSHString(body)
    }
    putSSHString(Data("ssh-rsa".utf8))
    putMPInt(exponent)
    putMPInt(modulus)
    return "ssh-rsa \(blob.base64EncodedString()) \(comment)"
}

/// OpenSSH 格式 RSA 私钥里公钥区较难单独取，用占位；安装公钥时对 RSA OpenSSH 仍可从 PEM 路径覆盖
private func rsaOpenSSHPublicKeyLine(fromOpenSSHPrivateKey _: String) throws -> String {
    // 解析完整 OpenSSH 再取公钥较复杂；这里返回提示性内容，真正展示依赖 normalize 成功路径
    return "ssh-rsa (imported) sshdash"
}

// MARK: - SSH 连接

final class SSHConn {
    private var client: SSHClient?

    func connect(_ p: ServerProfile, secret: String) async throws {
        let method: SSHAuthenticationMethod
        switch p.auth {
        case .password:
            method = .passwordBased(username: p.username, password: secret)
        case .key:
            method = try KeyMaterial.authMethod(username: p.username, secret: secret)
        }
        client = try await SSHClient.connect(
            host: p.host,
            port: p.port,
            authenticationMethod: method,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }

    func exec(_ command: String) async throws -> String {
        guard let c = client else { throw AppSSHError.notConnected }
        let buf = try await c.executeCommand(command, maxResponseSize: 4_000_000, mergeStreams: true)
        return String(buffer: buf)
    }

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
