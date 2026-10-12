import Foundation
import SwiftUI

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case password
    case key

    var id: String { rawValue }
    var label: String { self == .password ? "密码" : "密钥" }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String = "root"
    var auth: AuthKind = .password
}

struct CustomScript: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var body: String
}

struct ServerStats {
    var hostname = ""
    var os = ""
    var kernel = ""
    var uptime = 0
    var load = ""
    var cpus = 1
    var cpuPercent = 0.0
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskUsed: UInt64 = 0
    var rxTotal: UInt64 = 0
    var txTotal: UInt64 = 0
    var rxSpeed = 0.0
    var txSpeed = 0.0
    var tcpEstablished = 0
    var processes = 0
    var services: [String] = []
    var vnstatMonthRx: UInt64?
    var vnstatMonthTx: UInt64?
    var iface = ""
}

struct DeployParam: Identifiable {
    let id: String
    let label: String
    let value: String
}

struct DeployTemplate: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var params: [DeployParam] = []
    let script: String
    var warning: String? = nil
}
