import Foundation
import Citadel
import Crypto
import NIOCore

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
        case .encryptedPEM: return "暂不支持加密的 RSA PEM，请先去掉口令后再导入"
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
    static func isRawPEM(_ secret: String) -> Bool {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("BEGIN RSA PRIVATE KEY") { return true }
        if s.contains("BEGIN PRIVATE KEY"), !s.contains("OPENSSH") { return true }
        return false
    }

    /// 保存时调用：RSA PEM 只做结构校验，绝不创建 BoringSSL 对象（避免闪退）
    static func normalize(secret: String, passphrase: String?) throws -> (stored: String, publicKey: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppSSHError.badKey }

        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            if trimmed.contains("ENCRYPTED") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
                throw AppSSHError.encryptedPEM
            }
            let comps = try RSAComponents.fromPKCS1PEM(trimmed)
            let pub = sshRSAPublicKeyString(modulus: comps.n, exponent: comps.e, comment: "sshdash")
            return (trimmed, pub)
        }

        if trimmed.contains("BEGIN PRIVATE KEY"), !trimmed.contains("OPENSSH") {
            if trimmed.contains("ENCRYPTED") { throw AppSSHError.encryptedPEM }
            let comps = try RSAComponents.fromPKCS8PEM(trimmed)
            let pub = sshRSAPublicKeyString(modulus: comps.n, exponent: comps.e, comment: "sshdash")
            return (trimmed, pub)
        }

        let parsed = try parse(trimmed, passphrase: passphrase)
        switch parsed {
        case .ed25519(let key):
            let stored = key.makeSSHRepresentation(comment: "sshdash")
            return (stored, sshEd25519PublicKeyString(key, comment: "sshdash"))
        case .rsa(_, let pub):
            return (trimmed, pub)
        }
    }

    static func parse(_ secret: String, passphrase: String? = nil) throws -> ParsedKey {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppSSHError.badKey }

        // RSA PEM → 转成 OpenSSH 再交给 Citadel 官方解析器
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            if trimmed.contains("ENCRYPTED") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
                throw AppSSHError.encryptedPEM
            }
            let openssh = try RSAComponents.fromPKCS1PEM(trimmed).toOpenSSHPrivateKey(comment: "sshdash")
            let rsa = try Insecure.RSA.PrivateKey(sshRsa: openssh)
            let comps = try RSAComponents.fromPKCS1PEM(trimmed)
            let pub = sshRSAPublicKeyString(modulus: comps.n, exponent: comps.e, comment: "sshdash")
            return .rsa(rsa, publicKeyLine: pub)
        }

        if trimmed.contains("BEGIN PRIVATE KEY"), !trimmed.contains("OPENSSH") {
            if trimmed.contains("ENCRYPTED") { throw AppSSHError.encryptedPEM }
            let comps = try RSAComponents.fromPKCS8PEM(trimmed)
            let openssh = comps.toOpenSSHPrivateKey(comment: "sshdash")
            let rsa = try Insecure.RSA.PrivateKey(sshRsa: openssh)
            let pub = sshRSAPublicKeyString(modulus: comps.n, exponent: comps.e, comment: "sshdash")
            return .rsa(rsa, publicKeyLine: pub)
        }

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            let passData = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
            do {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: passData)
                return .ed25519(key)
            } catch { /* try RSA */ }
            do {
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: trimmed)
                return .rsa(rsa, publicKeyLine: "ssh-rsa (openssh) sshdash")
            } catch {
                let desc = String(describing: error).lowercased()
                if passData == nil,
                   desc.contains("decrypt") || desc.contains("pass") || desc.contains("cipher") || desc.contains("kdf") {
                    throw AppSSHError.needPassphrase
                }
                throw AppSSHError.badKey
            }
        }

        if let raw = Data(base64Encoded: trimmed),
           raw.count == 32,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return .ed25519(key)
        }

        throw AppSSHError.badKey
    }

    static func publicKey(from secret: String) -> String? {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRawPEM(s) {
            // 纯 Swift 抽 n/e，不碰 BoringSSL
            if let comps = try? RSAComponents.fromPKCS1PEM(s)
                ?? (try? RSAComponents.fromPKCS8PEM(s)) {
                return sshRSAPublicKeyString(modulus: comps.n, exponent: comps.e, comment: "sshdash")
            }
            return nil
        }
        guard let parsed = try? parse(s) else { return nil }
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

// MARK: - RSA 组件（纯 Swift，无 BoringSSL）

private struct RSAComponents {
    var n: Data
    var e: Data
    var d: Data
    var p: Data
    var q: Data
    var iqmp: Data

    static func fromPKCS1PEM(_ pem: String) throws -> RSAComponents {
        let der = try pemBody(pem, begin: "BEGIN RSA PRIVATE KEY", end: "END RSA PRIVATE KEY")
        return try fromPKCS1DER(der)
    }

    static func fromPKCS8PEM(_ pem: String) throws -> RSAComponents {
        let der = try pemBody(pem, begin: "BEGIN PRIVATE KEY", end: "END PRIVATE KEY")
        var idx = 0
        guard der.byte(at: idx) == 0x30 else { throw AppSSHError.badKey }
        idx += 1
        _ = try readASN1Length(der, &idx)
        guard der.byte(at: idx) == 0x02 else { throw AppSSHError.badKey }
        idx += 1
        let vlen = try readASN1Length(der, &idx)
        guard idx + vlen <= der.count else { throw AppSSHError.badKey }
        idx += vlen
        guard der.byte(at: idx) == 0x30 else { throw AppSSHError.badKey }
        idx += 1
        let alen = try readASN1Length(der, &idx)
        guard idx + alen <= der.count else { throw AppSSHError.badKey }
        idx += alen
        guard der.byte(at: idx) == 0x04 else { throw AppSSHError.badKey }
        idx += 1
        let klen = try readASN1Length(der, &idx)
        guard klen > 0, idx + klen <= der.count else { throw AppSSHError.badKey }
        return try fromPKCS1DER(der.subdata(in: idx..<(idx + klen)))
    }

    static func fromPKCS1DER(_ der: Data) throws -> RSAComponents {
        guard der.count > 32 else { throw AppSSHError.badKey }
        var idx = 0
        guard der.byte(at: idx) == 0x30 else { throw AppSSHError.badKey }
        idx += 1
        _ = try readASN1Length(der, &idx)

        _ = try readASN1Integer(der, &idx) // version
        let n = try readASN1Integer(der, &idx)
        let e = try readASN1Integer(der, &idx)
        let d = try readASN1Integer(der, &idx)
        let p = try readASN1Integer(der, &idx)
        let q = try readASN1Integer(der, &idx)
        _ = try readASN1Integer(der, &idx) // exp1
        _ = try readASN1Integer(der, &idx) // exp2
        let iqmp = try readASN1Integer(der, &idx)

        guard n.count >= 64, !e.isEmpty, d.count >= 64, !p.isEmpty, !q.isEmpty, !iqmp.isEmpty else {
            throw AppSSHError.badKey
        }
        return RSAComponents(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp)
    }

    /// 转成 OpenSSH 私钥文本，供 Citadel `sshRsa:` 使用
    func toOpenSSHPrivateKey(comment: String) -> String {
        var root = Data()

        // magic
        root.append(contentsOf: Array("openssh-key-v1".utf8))
        root.append(0x00)

        putSSHString(&root, Data("none".utf8)) // cipher
        putSSHString(&root, Data("none".utf8)) // kdf
        putSSHString(&root, Data())             // kdf options

        // # keys = 1
        putU32(&root, 1)

        // public key blob
        var pub = Data()
        putSSHString(&pub, Data("ssh-rsa".utf8))
        putMPInt(&pub, e)
        putMPInt(&pub, n)
        putSSHString(&root, pub)

        // private key blob
        var priv = Data()
        let check = UInt32.random(in: 0...UInt32.max)
        putU32(&priv, check)
        putU32(&priv, check)
        putSSHString(&priv, Data("ssh-rsa".utf8))
        putMPInt(&priv, n)
        putMPInt(&priv, e)
        putMPInt(&priv, d)
        putMPInt(&priv, iqmp)
        putMPInt(&priv, p)
        putMPInt(&priv, q)
        putSSHString(&priv, Data(comment.utf8))

        // pad to multiple of 8
        let pad = (8 - (priv.count % 8)) % 8
        if pad == 0 {
            // OpenSSH still pads a full block when already aligned? cipher none blockSize=8
            // 若已对齐，补 8 字节 1..8
            for i in 1...8 { priv.append(UInt8(i)) }
        } else {
            for i in 1...pad { priv.append(UInt8(i)) }
        }
        putSSHString(&root, priv)

        let b64 = root.base64EncodedString()
        // 每 70 字符换行，兼容部分解析器
        var wrapped = ""
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            wrapped += b64[i..<j]
            wrapped += "\n"
            i = j
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)-----END OPENSSH PRIVATE KEY-----\n"
    }
}

// MARK: - SSH / ASN.1 helpers（纯 Swift）

private extension Data {
    func byte(at i: Int) -> UInt8? {
        guard i >= 0, i < count else { return nil }
        return self[i]
    }
}

private func putU32(_ data: inout Data, _ v: UInt32) {
    var be = v.bigEndian
    data.append(Data(bytes: &be, count: 4))
}

private func putSSHString(_ data: inout Data, _ s: Data) {
    putU32(&data, UInt32(s.count))
    data.append(s)
}

private func putMPInt(_ data: inout Data, _ magnitude: Data) {
    var body = magnitude
    while body.count > 1, body[0] == 0x00 { body = body.dropFirst() }
    if body.isEmpty { body = Data([0x00]) }
    if body[0] & 0x80 != 0 { body = Data([0x00]) + body }
    putSSHString(&data, body)
}

private func pemBody(_ pem: String, begin: String, end: String) throws -> Data {
    let lines = pem
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard let b = lines.firstIndex(where: { $0.contains(begin) }),
          let e = lines.firstIndex(where: { $0.contains(end) }),
          b < e else {
        throw AppSSHError.badKey
    }

    var payload: [String] = []
    for line in lines[(b + 1)..<e] {
        if line.hasPrefix("Proc-Type") || line.hasPrefix("DEK-Info") { continue }
        payload.append(line)
    }
    let b64 = payload.joined()
        .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
    guard !b64.isEmpty, let data = Data(base64Encoded: b64), data.count > 16 else {
        throw AppSSHError.badKey
    }
    return data
}

private func readASN1Length(_ data: Data, _ idx: inout Int) throws -> Int {
    guard let firstByte = data.byte(at: idx) else { throw AppSSHError.badKey }
    idx += 1
    let first = Int(firstByte)
    if first & 0x80 == 0 { return first }
    let nbytes = first & 0x7f
    guard nbytes > 0, nbytes <= 4, idx + nbytes <= data.count else { throw AppSSHError.badKey }
    var len = 0
    for _ in 0..<nbytes {
        guard let b = data.byte(at: idx) else { throw AppSSHError.badKey }
        len = (len << 8) | Int(b)
        idx += 1
    }
    return len
}

private func readASN1Integer(_ data: Data, _ idx: inout Int) throws -> Data {
    guard data.byte(at: idx) == 0x02 else { throw AppSSHError.badKey }
    idx += 1
    let len = try readASN1Length(data, &idx)
    guard len > 0, idx + len <= data.count else { throw AppSSHError.badKey }
    var intData = data.subdata(in: idx..<(idx + len))
    idx += len
    // 保留数值：去掉多余前导 0，但至少留 1 字节
    while intData.count > 1, intData.byte(at: 0) == 0x00 {
        intData = intData.dropFirst()
    }
    return Data(intData)
}

// MARK: - 公钥行

func sshEd25519PublicKeyString(_ priv: Curve25519.Signing.PrivateKey, comment: String) -> String {
    let pub = priv.publicKey.rawRepresentation
    var blob = Data()
    putSSHString(&blob, Data("ssh-ed25519".utf8))
    putSSHString(&blob, pub)
    return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
}

func sshPublicKeyString(_ priv: Curve25519.Signing.PrivateKey, comment: String) -> String {
    sshEd25519PublicKeyString(priv, comment: comment)
}

func sshRSAPublicKeyString(modulus: Data, exponent: Data, comment: String) -> String {
    var blob = Data()
    putSSHString(&blob, Data("ssh-rsa".utf8))
    putMPInt(&blob, exponent)
    putMPInt(&blob, modulus)
    return "ssh-rsa \(blob.base64EncodedString()) \(comment)"
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
