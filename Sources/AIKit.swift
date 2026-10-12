import SwiftUI
import Security

// MARK: - 主题（与 App 的霓虹主题一致）

enum AITheme {
    static let card = Theme.card
    static let accent = Theme.cyan
    static let accent2 = Theme.purple
    static let bg = Theme.bg
    static let dim = Theme.textDim
    static let gradient = Theme.gradient
}

extension View {
    func aiCard(padding: CGFloat = 14) -> some View {
        self.neonCard(padding: padding)
    }

    func aiField() -> some View {
        self.neonField()
    }
}

func aiErrText(_ e: Error) -> String? {
    if e is CancellationError { return nil }
    if (e as? URLError)?.code == .cancelled { return nil }
    return e.localizedDescription
}

// MARK: - 钥匙串

enum AIKeychain {
    private static let service = "com.lin.githubcn"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func fallbackKey(_ account: String) -> String { "kc_fb_" + account }

    static func save(_ value: String, account: String = "token") {
        SecItemDelete(baseQuery(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        if value.isEmpty { return }
        var q = baseQuery(account)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey(account))
        }
    }

    static func load(account: String = "token") -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data,
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackKey(account))
    }

    static func delete(account: String = "token") {
        SecItemDelete(baseQuery(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(account))
    }
}

// MARK: - 轻量 Markdown

enum AIMDKind: Equatable {
    case heading(Int)
    case paragraph
    case bullet(String)
    case quote
    case code
    case rule
}

struct AIMDBlock {
    var kind: AIMDKind
    var text: String
}

enum AIMD {
    static func parse(_ src: String) -> [AIMDBlock] {
        var blocks: [AIMDBlock] = []
        var para: [String] = []
        var code: [String] = []
        var inCode = false

        func flush() {
            if !para.isEmpty {
                blocks.append(AIMDBlock(kind: .paragraph, text: para.joined(separator: " ")))
                para = []
            }
        }

        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let t0 = line.trimmingCharacters(in: .whitespaces)

            if t0.hasPrefix("```") || t0.hasPrefix("~~~") {
                if inCode {
                    blocks.append(AIMDBlock(kind: .code, text: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flush()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if t0.isEmpty {
                flush()
                continue
            }

            let t = t0
            if t.isEmpty { continue }

            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                let rest = t.dropFirst(level)
                if level <= 6, rest.first == " " {
                    flush()
                    blocks.append(AIMDBlock(kind: .heading(level), text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if t == "---" || t == "***" || t == "___" {
                flush()
                blocks.append(AIMDBlock(kind: .rule, text: ""))
                continue
            }
            if t.hasPrefix("|") {
                flush()
                let probe = t.replacingOccurrences(of: "|", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if probe.isEmpty { continue }
                let cells = t.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                blocks.append(AIMDBlock(kind: .code, text: cells.joined(separator: "  |  ")))
                continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flush()
                blocks.append(AIMDBlock(kind: .bullet("•"), text: String(t.dropFirst(2))))
                continue
            }
            if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                let marker = String(t[r]).trimmingCharacters(in: .whitespaces)
                blocks.append(AIMDBlock(kind: .bullet(marker), text: String(t[r.upperBound...])))
                continue
            }
            if t.hasPrefix(">") {
                flush()
                let q = String(t.drop(while: { $0 == ">" || $0 == " " }))
                blocks.append(AIMDBlock(kind: .quote, text: q))
                continue
            }
            para.append(t)
        }
        if inCode { blocks.append(AIMDBlock(kind: .code, text: code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

struct AIMarkdownView: View {
    let blocks: [AIMDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                blockView(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) {
            return Text(a)
        }
        return Text(s)
    }

    @ViewBuilder
    private func blockView(_ b: AIMDBlock) -> some View {
        switch b.kind {
        case .heading(let level):
            inline(b.text)
                .font(level <= 1 ? Font.title2.bold() : (level == 2 ? Font.title3.bold() : Font.headline))
                .padding(.top, 6)
        case .paragraph:
            inline(b.text)
        case .bullet(let marker):
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                inline(b.text)
            }
        case .quote:
            HStack(spacing: 8) {
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 3)
                inline(b.text).foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(b.text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
            }
            .background(AITheme.card)
            .cornerRadius(8)
        case .rule:
            Divider()
        }
    }
}
